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
    /// ConnectionRepository. No deduplication is performed: importing twice
    /// creates two sets of connections, matching what the preview shows.
    static func connections(
        from entries: [SSHConfigEntry],
        defaultUsername: String = NSUserName(),
        folderId: UUID? = nil,
        now: Date = Date()
    ) -> [Connection] {
        entries.map { entry in
            Connection(
                name: entry.alias,
                host: entry.hostName,
                port: entry.port,
                username: entry.user ?? defaultUsername,
                authMethod: entry.usesKeyAuthentication ? .privateKey : .password,
                privateKeyPath: entry.primaryIdentityFile,
                savePassword: false,
                description: "Imported from ~/.ssh/config",
                tags: ["ssh-config"],
                iconName: ConnectionType.sftp.iconName,
                folderId: folderId,
                createdAt: now,
                updatedAt: now,
                connectionType: .sftp
            )
        }
    }
}
