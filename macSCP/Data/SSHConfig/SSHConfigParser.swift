//
//  SSHConfigParser.swift
//  macSCP
//
//  Minimal ssh_config reader for the "Import from ~/.ssh/config" feature.
//
//  Scope: enough of ssh_config(5) to turn Host blocks into concrete connections.
//  Deliberately out of scope: Match criteria, ProxyJump/ProxyCommand execution,
//  port forwarding, canonicalisation, and host key options.
//
//  Supported: Host (multiple aliases, `*`/`?` patterns, `!` negation), HostName,
//  User, Port, IdentityFile (ordered), Include (recursive, glob, cycle-safe),
//  `Keyword=value` syntax, `#` comments, quoted values, and %h/%r/%p/%d/%u/%% token
//  expansion. Resolution uses ssh's first-obtained-value-wins rule across blocks
//  in file order.
//

import Foundation
import Darwin

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
        case let .unreadableFile(path, reason):
            return "Cannot read SSH config at \(path): \(reason)"
        }
    }
}

struct SSHConfigParseOptions: Sendable {
    /// Used for `~` and `%d` expansion. Configurable so tests are hermetic.
    var homeDirectory: String
    var maxIncludeDepth: Int

    init(homeDirectory: String = NSHomeDirectory(), maxIncludeDepth: Int = 8) {
        self.homeDirectory = homeDirectory
        self.maxIncludeDepth = maxIncludeDepth
    }
}

// MARK: - Parser

struct SSHConfigParser: Sendable {
    private let reader: any SSHConfigReading
    private let options: SSHConfigParseOptions
    private let fileExists: @Sendable (String) -> Bool
    private let includeExpander: @Sendable (String) -> [String]

    init(
        reader: any SSHConfigReading = FileSystemSSHConfigReader(),
        options: SSHConfigParseOptions = SSHConfigParseOptions(),
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        includeExpander: @escaping @Sendable (String) -> [String] = SSHConfigParser.expandGlobs
    ) {
        self.reader = reader
        self.options = options
        self.fileExists = fileExists
        self.includeExpander = includeExpander
    }

    // MARK: Entry Point

    func parse(configURL: URL) throws -> SSHConfigParseResult {
        var state = State()
        var currentSection = 0
        try load(
            url: configURL,
            depth: 0,
            stack: [],
            currentSection: &currentSection,
            state: &state
        )
        return SSHConfigParseResult(
            entries: materialize(state: &state),
            warnings: state.warnings,
            sourcePaths: state.sourcePaths
        )
    }

    // MARK: Parsing State

    private struct Section {
        var patterns: [String]
        var values: [String: [String]]
        /// True for `Match` blocks: parsed for structure, never resolved.
        var isMatch: Bool
    }

    private struct State {
        /// Index 0 is the implicit global block covering everything before the
        /// first Host keyword, mirroring ssh's "applies to all hosts" semantics.
        var sections: [Section] = [
            Section(patterns: ["*"], values: [:], isMatch: false)
        ]
        var warnings: [SSHConfigWarning] = []
        var sourcePaths: [String] = []
    }

    // MARK: File Loading

    private func load(
        url: URL,
        depth: Int,
        stack: [String],
        currentSection: inout Int,
        state: inout State
    ) throws {
        let path = url.standardizedFileURL.path

        let text: String
        do {
            text = try reader.read(contentsOf: url)
        } catch {
            if depth == 0 {
                throw SSHConfigError.unreadableFile(path: path, reason: error.localizedDescription)
            }
            state.warnings.append(.includeNotFound(path))
            return
        }
        state.sourcePaths.append(path)

        let lines = text.components(separatedBy: .newlines)
        for (offset, rawLine) in lines.enumerated() {
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
                guard !tokens.isEmpty else {
                    state.warnings.append(.malformedLine(path: path, line: offset + 1, content: rawLine))
                    continue
                }
                state.sections.append(Section(patterns: tokens, values: [:], isMatch: false))
                currentSection = state.sections.count - 1

            case "match":
                // Recognised so that following directives are not attributed to
                // the previous Host block, then ignored entirely.
                state.sections.append(Section(patterns: [], values: [:], isMatch: true))
                currentSection = state.sections.count - 1

            case "include":
                for pattern in tokens {
                    let candidates = includeExpander(pattern)
                    guard !candidates.isEmpty else {
                        state.warnings.append(.includeNotFound(pattern))
                        continue
                    }
                    for candidate in candidates {
                        let includedURL = URL(fileURLWithPath: candidate)
                        let includedPath = includedURL.standardizedFileURL.path

                        if stack.contains(includedPath) || includedPath == path {
                            state.warnings.append(.includeCycleSkipped(includedPath))
                            continue
                        }
                        guard depth + 1 <= options.maxIncludeDepth else {
                            state.warnings.append(.includeDepthExceeded(includedPath))
                            continue
                        }
                        try load(
                            url: includedURL,
                            depth: depth + 1,
                            stack: stack + [path],
                            currentSection: &currentSection,
                            state: &state
                        )
                    }
                }

            default:
                let value = tokens.joined(separator: " ")
                guard !value.isBlank else {
                    state.warnings.append(.malformedLine(path: path, line: offset + 1, content: rawLine))
                    continue
                }
                state.sections[currentSection].values[key.lowercased(), default: []].append(value)
            }
        }
    }

    // MARK: Resolution

    private func materialize(state: inout State) -> [SSHConfigEntry] {
        let sections = state.sections

        var aliasOrder: [String] = []
        var seenAliases: Set<String> = []
        for section in sections where !section.isMatch {
            for pattern in section.patterns {
                if pattern.hasPrefix("!") { continue }
                guard Self.isLiteral(pattern) else {
                    // `Host *` is the conventional defaults block: it contributes
                    // values via resolution but is not an importable connection.
                    if pattern != "*" {
                        state.warnings.append(.wildcardHostSkipped(pattern))
                    }
                    continue
                }
                if seenAliases.insert(pattern.lowercased()).inserted {
                    aliasOrder.append(pattern)
                }
            }
        }

        var entries: [SSHConfigEntry] = []
        for alias in aliasOrder {
            let resolved = resolve(alias: alias, sections: sections)
            entries.append(makeEntry(alias: alias, resolved: resolved, state: &state))
        }
        return entries
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
        state: inout State
    ) -> SSHConfigEntry {
        let hostName = expandTokens(resolved["hostname"]?.first ?? alias, resolved: resolved)
        let user = resolved["user"]?.first.map { expandTokens($0, resolved: resolved) }

        var port = AppConstants.defaultSSHPort
        if let rawPort = resolved["port"]?.first {
            if let parsed = Int(rawPort.trimmed), (1...65535).contains(parsed) {
                port = parsed
            } else {
                state.warnings.append(.invalidPort(alias: alias, value: rawPort))
            }
        }

        var identityFiles: [String] = []
        for rawPath in resolved["identityfile"] ?? [] {
            let expanded = expandTilde(expandTokens(rawPath, resolved: resolved))
            guard !identityFiles.contains(expanded) else { continue }
            identityFiles.append(expanded)
            if !fileExists(expanded) {
                state.warnings.append(.identityFileUnavailable(alias: alias, path: expanded))
            }
        }

        let unsupported = Self.connectivityDirectives
            .filter { key in
                guard let value = resolved[key]?.first else { return false }
                return value.lowercased() != "none"
            }
            .sorted()

        for directive in unsupported {
            state.warnings.append(.unsupportedDirective(alias: alias, directive: directive))
        }

        return SSHConfigEntry(
            alias: alias,
            hostName: hostName,
            user: user,
            port: port,
            identityFiles: identityFiles,
            unsupportedDirectives: unsupported
        )
    }

    // MARK: Tokens

    private func expandTilde(_ path: String) -> String {
        if path == "~" {
            return options.homeDirectory
        }
        if path.hasPrefix("~/") {
            return options.homeDirectory + String(path.dropFirst())
        }
        return path
    }

    /// Expands ssh's percent tokens. Unknown tokens are passed through unchanged.
    private func expandTokens(_ value: String, resolved: [String: [String]]) -> String {
        guard value.contains("%") else { return value }

        let host = resolved["hostname"]?.first ?? ""
        let user = resolved["user"]?.first ?? ""
        let port = resolved["port"]?.first ?? String(AppConstants.defaultSSHPort)

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
            case "d": output += options.homeDirectory
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

    /// Directives that change how a connection behaves but are not modelled by
    /// macSCP. Presence means the imported profile is not wire-equivalent.
    private static let connectivityDirectives: Set<String> = [
        "proxyjump",
        "proxycommand",
        "localforward",
        "remoteforward",
        "dynamicforward"
    ]

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
               patternBytes[patternIndex] == questionMark || patternBytes[patternIndex] == valueBytes[valueIndex] {
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

    // MARK: Include Glob Expansion

    /// Expands `~` and glob metacharacters for Include patterns using glob(3).
    /// Returns an empty array when nothing matches, including when the sandbox
    /// denies access to the containing directory.
    static func expandGlobs(_ pattern: String) -> [String] {
        var globResult = glob_t()
        let status = Darwin.glob(pattern, GLOB_TILDE, nil, &globResult)
        defer { Darwin.globfree(&globResult) }

        guard status == 0, let paths = globResult.gl_pathv else { return [] }

        return (0..<Int(globResult.gl_pathc)).compactMap { index in
            paths[index].map { String(cString: $0) }
        }
    }
}
