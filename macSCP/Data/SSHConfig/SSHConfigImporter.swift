//
//  SSHConfigImporter.swift
//  macSCP
//
//  Maps parsed ssh_config entries onto Connection domain models. Pure logic:
//  no I/O, no UI, no persistence.
//

import Foundation

enum SSHConfigImporter {
    /// Converts parsed hosts into connections ready to be saved through
    /// ConnectionRepository. Nothing the user owns is prefilled: no tags, no
    /// description and no folder.
    static func connections(
        from entries: [SSHConfigEntry],
        defaultUsername: String = NSUserName(),
        now: Date = Date()
    ) -> [Connection] {
        entries.map { entry in
            Connection(
                name: entry.alias,
                host: entry.hostName,
                port: entry.port,
                username: entry.user ?? defaultUsername,
                authMethod: entry.usesKeyAuthentication ? .privateKey : .password,
                privateKeyPath: entry.identityFile,
                savePassword: false,
                createdAt: now,
                updatedAt: now,
                connectionType: .sftp
            )
        }
    }

    /// Key used to recognise a host that is already stored:
    /// `host|port|username`.
    static func deduplicationKey(for connection: Connection) -> String {
        deduplicationKey(host: connection.host, port: connection.port, username: connection.username)
    }

    static func deduplicationKey(host: String, port: Int, username: String) -> String {
        "\(host.lowercased())|\(port)|\(username.lowercased())"
    }
}
