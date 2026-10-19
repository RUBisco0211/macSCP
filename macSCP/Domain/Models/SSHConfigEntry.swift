//
//  SSHConfigEntry.swift
//  macSCP
//
//  Intermediate representation of an ~/.ssh/config Host block.
//  Parser output only — not persisted, not a domain entity.
//

import Foundation

/// A single concrete host discovered in an ssh_config file, already resolved
/// against all matching `Host` blocks (first-obtained-value-wins).
struct SSHConfigEntry: Hashable, Sendable {
    /// The literal alias used on the command line (`ssh <alias>`).
    let alias: String
    /// Resolved `HostName`, defaulting to the alias.
    let hostName: String
    /// Resolved `User`, if the config specified one.
    let user: String?
    /// Resolved `Port`, defaulting to 22.
    let port: Int
    /// All `IdentityFile` values in resolution order, tilde- and token-expanded.
    let identityFiles: [String]
    /// Directives we knowingly ignore during import (they change connectivity).
    let unsupportedDirectives: [String]

    /// First identity file, the one an import would wire up.
    var primaryIdentityFile: String? {
        identityFiles.first
    }

    var usesKeyAuthentication: Bool {
        primaryIdentityFile != nil
    }
}

/// Non-fatal problems encountered while parsing. Every case is something the
/// import UI is expected to surface next to the affected alias.
enum SSHConfigWarning: Hashable, Sendable {
    case wildcardHostSkipped(String)
    case unsupportedDirective(alias: String, directive: String)
    case identityFileUnavailable(alias: String, path: String)
    case invalidPort(alias: String, value: String)
    case includeNotFound(String)
    case includeCycleSkipped(String)
    case includeDepthExceeded(String)
    case malformedLine(path: String, line: Int, content: String)

    /// Alias the warning belongs to, or nil for file-wide problems.
    var alias: String? {
        switch self {
        case let .unsupportedDirective(alias, _),
             let .identityFileUnavailable(alias, _),
             let .invalidPort(alias, _):
            return alias
        case .wildcardHostSkipped,
             .includeNotFound,
             .includeCycleSkipped,
             .includeDepthExceeded,
             .malformedLine:
            return nil
        }
    }

    var message: String {
        switch self {
        case .wildcardHostSkipped(let pattern):
            return "\"\(pattern)\" is a wildcard host pattern and cannot be imported as a connection."
        case let .unsupportedDirective(alias, directive):
            return "\(alias) uses \(directive), which macSCP does not support. Only connection settings are imported."
        case let .identityFileUnavailable(alias, path):
            return "\(alias) references \(path), which could not be read. Check the path and file permissions."
        case let .invalidPort(alias, value):
            return "\(alias) has an invalid port \"\(value)\". Falling back to 22."
        case .includeNotFound(let pattern):
            return "\"Include \(pattern)\" did not resolve to any readable file."
        case .includeCycleSkipped(let path):
            return "Skipped recursive Include of \(path)."
        case .includeDepthExceeded(let path):
            return "Skipped Include of \(path): maximum include depth reached."
        case let .malformedLine(path, line, content):
            return "Ignored malformed line \(line) in \(path): \(content)"
        }
    }
}

/// Result of parsing one config file (plus everything it includes).
struct SSHConfigParseResult: Sendable {
    let entries: [SSHConfigEntry]
    let warnings: [SSHConfigWarning]
    /// Every file that was actually read, root first.
    let sourcePaths: [String]
}
