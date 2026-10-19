//
//  DataStore.swift
//  macSCP
//
//  SwiftData ModelContainer setup and management
//

import Foundation
import SwiftData

@MainActor
final class DataStore {
    static let shared = DataStore()

    let modelContainer: ModelContainer
    /// File backing `modelContainer`, useful for diagnostics and backups.
    let storeURL: URL

    private init() {
        let schema = Schema([
            ConnectionEntity.self,
            FolderEntity.self
        ])

        let storeURL = Self.migrateLegacyStoreIfNeeded()
            ?? Self.applicationStoreURL()

        let modelConfiguration = ModelConfiguration(
            schema: schema,
            url: storeURL,
            allowsSave: true
        )

        do {
            modelContainer = try ModelContainer(
                for: schema,
                configurations: [modelConfiguration]
            )
            self.storeURL = storeURL
            logInfo("DataStore initialized at \(storeURL.path)", category: .database)
        } catch {
            logError("Failed to initialize DataStore: \(error)", category: .database)
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var modelContext: ModelContext {
        modelContainer.mainContext
    }

    /// Creates a new background context for async operations
    func newBackgroundContext() -> ModelContext {
        ModelContext(modelContainer)
    }

    /// Attempts to recover from database corruption by recreating the store
    static func createWithRecovery() -> ModelContainer {
        return DataStore.shared.modelContainer
    }

    // MARK: - Locations

    /// App-specific store, so macSCP never shares SwiftData's generic
    /// `default.store` with another application.
    nonisolated static func applicationStoreURL(fileManager: FileManager = .default) -> URL {
        applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("macSCP", isDirectory: true)
            .appendingPathComponent("macSCP.store", isDirectory: false)
    }

    /// SwiftData's default location. Inside the App Sandbox this resolves to the
    /// app container (`~/Library/Containers/<bundle-id>/Data/Library/Application
    /// Support`), which is where builds that shipped before this change stored
    /// their data. Unsandboxed builds would resolve to the user's shared
    /// Application Support directory, so the file is only adopted when it is
    /// recognisably a macSCP database.
    nonisolated static func sharedDefaultStoreURL(fileManager: FileManager = .default) -> URL {
        applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("default.store", isDirectory: false)
    }

    private nonisolated static func applicationSupportDirectory(fileManager: FileManager) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    // MARK: - Migration

    /// Moves an existing store into the app-specific location.
    ///
    /// - Returns: the URL the container should open. When nothing was migrated
    ///   and the app-specific store does not exist yet, returns `nil` so the
    ///   caller falls back to the (new) app-specific location.
    private static func migrateLegacyStoreIfNeeded(fileManager: FileManager = .default) -> URL? {
        let preferredURL = applicationStoreURL(fileManager: fileManager)
        guard !fileManager.fileExists(atPath: preferredURL.path) else {
            return preferredURL
        }

        let source = sharedDefaultStoreURL(fileManager: fileManager)
        guard fileManager.fileExists(atPath: source.path) else {
            return nil
        }

        // Do not adopt a database that belongs to another application.
        guard SwiftDataStoreMigrator.looksLikeMacSCPStore(at: source, fileManager: fileManager) else {
            logWarning("Ignoring \(source.path): not a macSCP store", category: .database)
            return nil
        }

        do {
            if try SwiftDataStoreMigrator.migrateIfNeeded(
                from: source,
                to: preferredURL,
                fileManager: fileManager
            ) {
                logInfo("Migrated SwiftData store from \(source.path)", category: .database)
                return preferredURL
            }
        } catch {
            logError("Failed to migrate SwiftData store from \(source.path): \(error)", category: .database)
            // Keep using the source so the app still starts with its data.
            return source
        }

        return nil
    }
}

// MARK: - Preview Support
extension DataStore {
    @MainActor
    static var preview: DataStore {
        let store = DataStore()
        return store
    }
}
