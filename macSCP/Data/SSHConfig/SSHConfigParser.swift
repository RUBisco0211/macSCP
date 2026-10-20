//
//  SSHConfigParser.swift
//  macSCP
//
//  Minimal ssh_config reader used by the import feature.
//
//  The user picks the file, so the parser only reads that file. `Include` is
//  ignored, unsupported directives are ignored, and nothing is surfaced as a
//  warning: the goal is a list of usable hosts, not a diagnostics report.
//
//  Supported: Host (multiple aliases, `*`/`?` patterns, `!` negation), HostName,
//  User, Port, IdentityFile (first one, resolved to an absolute path),
//  `Keyword=value` syntax, `#` comments, quoted values, and %h/%r/%p/%d/%u/%%
//  token expansion. Resolution uses ssh's first-obtained-value-wins rule across
//  blocks in file order.
//

import Foundation

// MARK: - Reading

/// Abstraction over file access so the parser can be tested without disk I/O.
protocol SSHConfigReading: Sendable {
    func read(contentsOf url: URL) throws -> String
}

struct FileSystemSSHConfigReader: SSHConfigReading {
    func read(contentsOf url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}

enum SSHConfigError: LocalizedError, Sendable {
    case unreadableFile(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .unreadableFile(let path, let reason):
            return String(localized: "Cannot read the ssh_config file at \(path): \(reason)")
        }
    }
}

// MARK: - Parser

struct SSHConfigParser: Sendable {
    private let reader: any SSHConfigReading
    private let homeDirectory: String

    init(
        reader: any SSHConfigReading = FileSystemSSHConfigReader(),
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.reader = reader
        self.homeDirectory = homeDirectory
    }

    /// Parses the file at `configURL` into concrete hosts.
    func parse(configURL: URL) throws -> [SSHConfigEntry] {
        let text: String
        do {
            text = try reader.read(contentsOf: configURL)
        } catch {
            throw SSHConfigError.unreadableFile(
                path: configURL.standardizedFileURL.path,
                reason: error.localizedDescription
            )
        }

        let configDirectory = configURL.deletingLastPathComponent().standardizedFileURL.path
        let sections = sections(from: text)
        return materialize(sections: sections, configDirectory: configDirectory)
    }

    // MARK: Block collection

    private struct Section {
        var patterns: [String]
        var values: [String: [String]]
        /// True for `Match` blocks: collected for structure, never resolved.
        var isMatch: Bool
    }

    private func sections(from text: String) -> [Section] {
        var sections: [Section] = []
        var currentSection: Int?

        for rawLine in text.components(separatedBy: .newlines) {
            var tokens = Self.lex(rawLine)
            guard !tokens.isEmpty else { continue }

            var key = tokens.removeFirst()

            // Support `Keyword=value` in addition to `Keyword value`.
            if let equalsIndex = key.firstIndex(of: "=") {
                let name = String(key[key.startIndex..<equalsIndex])
                let inlineValue = String(key[key.index(after: equalsIndex)...])
                key = name
                if !inlineValue.isEmpty {
                    tokens.insert(inlineValue, at: 0)
                }
            }
            if tokens.first == "=" {
                tokens.removeFirst()
            }

            switch key.lowercased() {
            case "host":
                guard !tokens.isEmpty else { continue }
                sections.append(Section(patterns: tokens, values: [:], isMatch: false))
                currentSection = sections.count - 1

            case "match":
                // Keep following directives out of the previous Host block.
                sections.append(Section(patterns: [], values: [:], isMatch: true))
                currentSection = sections.count - 1

            case "include":
                // Only the selected file is read; included files are not opened.
                continue

            default:
                let value = tokens.joined(separator: " ")
                guard !value.isBlank else { continue }
                // Directives outside a Host/Match block are global defaults.
                if currentSection == nil {
                    sections.append(Section(patterns: ["*"], values: [:], isMatch: false))
                    currentSection = sections.count - 1
                }
                sections[currentSection!].values[key.lowercased(), default: []].append(value)
            }
        }

        return sections
    }

    // MARK: Resolution

    private func materialize(sections: [Section], configDirectory: String) -> [SSHConfigEntry] {
        var aliases: [String] = []
        var seen: Set<String> = []

        for section in sections where !section.isMatch {
            for pattern in section.patterns where !pattern.hasPrefix("!") && Self.isLiteral(pattern)
            {
                if seen.insert(pattern.lowercased()).inserted {
                    aliases.append(pattern)
                }
            }
        }

        return aliases.map { alias in
            makeEntry(
                alias: alias,
                resolved: resolve(alias: alias, sections: sections),
                configDirectory: configDirectory
            )
        }
    }

    /// ssh semantics: the first value obtained for a keyword wins, scanning
    /// blocks in file order. IdentityFile is additive.
    private func resolve(alias: String, sections: [Section]) -> [String: [String]] {
        var resolved: [String: [String]] = [:]

        for section in sections where !section.isMatch {
            guard Self.blockMatches(alias: alias, patterns: section.patterns) else { continue }
            for (key, values) in section.values {
                guard !values.isEmpty else { continue }
                if key == "identityfile" {
                    resolved[key, default: []].append(contentsOf: values)
                } else if resolved[key] == nil {
                    resolved[key] = [values[0]]
                }
            }
        }
        return resolved
    }

    private func makeEntry(
        alias: String,
        resolved: [String: [String]],
        configDirectory: String
    ) -> SSHConfigEntry {
        let portValue = resolved["port"]?.first
        let portString = portValue ?? String(AppConstants.defaultSSHPort)
        let localUser = NSUserName()
        let resolvedUser = resolved["user"]?.first ?? localUser

        // In ssh, %h inside HostName expands to the alias, while %h in other
        // directives expands to the resolved hostname.
        let hostName = expandTokens(
            resolved["hostname"]?.first ?? alias,
            host: alias,
            user: resolvedUser,
            port: portString
        )
        let user = resolved["user"]?.first.map {
            expandTokens($0, host: alias, user: resolvedUser, port: portString)
        }

        var port = AppConstants.defaultSSHPort
        if let rawPort = portValue, let parsed = Int(rawPort.trimmed), (1...65535).contains(parsed)
        {
            port = parsed
        }

        var identityFile: String?
        if let rawPath = resolved["identityfile"]?.first {
            let expanded = expandTokens(
                rawPath, host: hostName, user: user ?? localUser, port: portString)
            identityFile = Self.absolutePath(
                expanded,
                configDirectory: configDirectory,
                homeDirectory: homeDirectory
            )
        }

        return SSHConfigEntry(
            alias: alias,
            hostName: hostName,
            user: user,
            port: port,
            identityFile: identityFile
        )
    }

    // MARK: Tokens

    /// Makes a possibly relative path absolute so it stays valid when the key is
    /// read at connection time.
    static func absolutePath(_ path: String, configDirectory: String, homeDirectory: String)
        -> String
    {
        let expanded: String
        if path == "~" {
            expanded = homeDirectory
        } else if path.hasPrefix("~/") {
            expanded = homeDirectory + String(path.dropFirst())
        } else if path.hasPrefix("/") {
            expanded = path
        } else {
            expanded = configDirectory.appendingPathComponent(path)
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    /// Expands ssh's percent tokens. Unknown tokens are passed through unchanged.
    private func expandTokens(_ value: String, host: String, user: String, port: String) -> String {
        guard value.contains("%") else { return value }

        let characters = Array(value)
        var output = ""
        var index = 0
        while index < characters.count {
            guard characters[index] == "%", index + 1 < characters.count else {
                output.append(characters[index])
                index += 1
                continue
            }
            switch characters[index + 1] {
            case "h": output += host
            case "r": output += user
            case "p": output += port
            case "d": output += homeDirectory
            case "u": output += NSUserName()
            case "%": output += "%"
            default:
                output.append("%")
                output.append(characters[index + 1])
            }
            index += 2
        }
        return output
    }

    /// Splits a line into tokens, honouring quotes and `#` comments.
    private static func lex(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasToken = false
        var quote: Character?
        var index = line.startIndex

        func flush() {
            if hasToken {
                tokens.append(current)
                current = ""
                hasToken = false
            }
        }

        while index < line.endIndex {
            let character = line[index]

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else if character == "\\", activeQuote == "\"" {
                    let next = line.index(after: index)
                    if next < line.endIndex {
                        current.append(line[next])
                        index = next
                    }
                } else {
                    current.append(character)
                }
            } else if character == "#" {
                break
            } else if character == "'" || character == "\"" {
                quote = character
                hasToken = true
            } else if character == "\\" {
                let next = line.index(after: index)
                if next < line.endIndex {
                    current.append(line[next])
                    index = next
                } else {
                    current.append(character)
                }
                hasToken = true
            } else if character == " " || character == "\t" {
                flush()
            } else {
                current.append(character)
                hasToken = true
            }
            index = line.index(after: index)
        }
        flush()
        return tokens
    }

    // MARK: Pattern Matching

    private static func isLiteral(_ pattern: String) -> Bool {
        !pattern.contains("*") && !pattern.contains("?") && !pattern.contains("[")
    }

    private static func blockMatches(alias: String, patterns: [String]) -> Bool {
        var positiveMatch = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if globMatch(String(pattern.dropFirst()), alias) {
                    return false
                }
            } else if globMatch(pattern, alias) {
                positiveMatch = true
            }
        }
        return positiveMatch
    }

    /// Shell-style `*`/`?` matching with backtracking. Host patterns are compared
    /// case-insensitively, matching macOS hostname conventions.
    private static func globMatch(_ pattern: String, _ value: String) -> Bool {
        let patternBytes = Array(pattern.lowercased().utf8)
        let valueBytes = Array(value.lowercased().utf8)
        let asterisk = UInt8(ascii: "*")
        let questionMark = UInt8(ascii: "?")

        var patternIndex = 0
        var valueIndex = 0
        var lastStar = -1
        var starMatch = 0

        while valueIndex < valueBytes.count {
            if patternIndex < patternBytes.count,
                patternBytes[patternIndex] == questionMark
                    || patternBytes[patternIndex] == valueBytes[valueIndex]
            {
                patternIndex += 1
                valueIndex += 1
            } else if patternIndex < patternBytes.count, patternBytes[patternIndex] == asterisk {
                lastStar = patternIndex
                starMatch = valueIndex
                patternIndex += 1
            } else if lastStar != -1 {
                patternIndex = lastStar + 1
                starMatch += 1
                valueIndex = starMatch
            } else {
                return false
            }
        }

        while patternIndex < patternBytes.count, patternBytes[patternIndex] == asterisk {
            patternIndex += 1
        }
        return patternIndex == patternBytes.count
    }
}
