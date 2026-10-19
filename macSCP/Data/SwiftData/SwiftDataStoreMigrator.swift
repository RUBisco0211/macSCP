//
//  SwiftDataStoreMigrator.swift
//  macSCP
//
//  Moves a SwiftData store from a legacy location to the app-specific one.
//
//  Two legacy locations matter:
//  - The App Sandbox container store, used by builds that shipped with
//    `com.apple.security.app-sandbox` (`~/Library/Containers/<bundle-id>/...`).
//  - SwiftData's default `~/Library/Application Support/default.store`, which is
//    shared by every non-sandboxed app using the default configuration. It is
//    only treated as ours when it actually contains macSCP's schema.
//

import Foundation

enum SwiftDataStoreMigrator {
    /// SQLite sidecar files of a SwiftData store. The main file comes last so its
    /// presence at the destination means the migration finished.
    static let sidecarSuffixes = ["-wal", "-shm", ""]

    /// Marker that only exists in a macSCP store.
    private static let schemaMarker = Data("ZCONNECTIONENTITY".utf8)

    /// Moves `legacyURL` (plus sidecars) to `destinationURL`.
    ///
    /// - Returns: `true` when a migration happened, `false` when there was
    ///   nothing to do (destination already exists, or no legacy store).
    /// - Throws: file-system errors. Anything already moved is moved back so the
    ///   next launch can retry from the original location.
    @discardableResult
    static func migrateIfNeeded(
        from legacyURL: URL,
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard !fileManager.fileExists(atPath: destinationURL.path),
              fileManager.fileExists(atPath: legacyURL.path) else {
            return false
        }

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var movedPairs: [(source: URL, destination: URL)] = []

        do {
            for suffix in sidecarSuffixes {
                let source = URL(fileURLWithPath: legacyURL.path + suffix)
                guard fileManager.fileExists(atPath: source.path) else { continue }

                let destination = URL(fileURLWithPath: destinationURL.path + suffix)
                try fileManager.moveItem(at: source, to: destination)
                movedPairs.append((source, destination))
            }
            return true
        } catch {
            for pair in movedPairs.reversed() {
                try? fileManager.moveItem(at: pair.destination, to: pair.source)
            }
            throw error
        }
    }

    /// Returns true when the SQLite files at `url` belong to a macSCP database.
    /// The schema name is stored in the file (or its WAL) as plain text, which is
    /// enough to avoid hijacking another app's `default.store`.
    static func looksLikeMacSCPStore(at url: URL, fileManager: FileManager = .default) -> Bool {
        for suffix in sidecarSuffixes {
            let candidate = URL(fileURLWithPath: url.path + suffix)
            guard let data = try? Data(contentsOf: candidate) else { continue }
            if data.range(of: schemaMarker) != nil {
                return true
            }
        }
        return false
    }
}
