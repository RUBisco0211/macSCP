//
//  SwiftDataStoreMigrator.swift
//  macSCP
//
//  Moves a SwiftData store from a legacy location to the app-specific one.
//
//  SwiftData's default configuration writes to `~/Library/Application Support/
//  default.store`, a name shared by every non-sandboxed app using the default
//  configuration. macSCP now points at an app-specific file instead; this
//  migrator carries existing data over exactly once.
//

import Foundation

enum SwiftDataStoreMigrator {
    /// SQLite sidecar files that belong to a SwiftData store.
    static let sidecarSuffixes = ["", "-wal", "-shm"]

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
}
