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

        let preferredURL = Self.applicationStoreURL()
        let legacyURL = Self.legacyStoreURL()

        do {
            let migrated = try SwiftDataStoreMigrator.migrateIfNeeded(from: legacyURL, to: preferredURL)
            if migrated {
                logInfo("Migrated SwiftData store to \(preferredURL.path)", category: .database)
            }
        } catch {
            logError("Failed to migrate SwiftData store: \(error)", category: .database)
        }

        let fileManager = FileManager.default
        let shouldUseLegacyURL = !fileManager.fileExists(atPath: preferredURL.path)
            && fileManager.fileExists(atPath: legacyURL.path)
        let storeURL = shouldUseLegacyURL ? legacyURL : preferredURL

        if shouldUseLegacyURL {
            logWarning("Using legacy SwiftData store at \(legacyURL.path); migration did not complete", category: .database)
        }

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

    /// Where SwiftData's default configuration used to write.
    nonisolated static func legacyStoreURL(fileManager: FileManager = .default) -> URL {
        applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("default.store", isDirectory: false)
    }

    private nonisolated static func applicationSupportDirectory(fileManager: FileManager) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
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
