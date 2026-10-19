//
//  SSHConfigEntry.swift
//  macSCP
//
//  Intermediate representation of an ssh_config Host block.
//  Parser output only — not persisted, not a domain entity.
//

import Foundation

/// A single concrete host discovered in an ssh_config file.
struct SSHConfigEntry: Hashable, Sendable {
    /// The literal alias used in the file (`Host <alias>`).
    let alias: String
    /// Resolved `HostName`, defaulting to the alias.
    let hostName: String
    /// Resolved `User`, if the file specified one.
    let user: String?
    /// Resolved `Port`, defaulting to 22.
    let port: Int
    /// First `IdentityFile`, resolved to an absolute path.
    let identityFile: String?

    var usesKeyAuthentication: Bool {
        identityFile != nil
    }
}
