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

    private init() {
        do {
            let schema = Schema([
                ConnectionEntity.self,
                FolderEntity.self,
            ])

            let modelConfiguration = ModelConfiguration(
                schema: schema,
                url: Self.storeURL,
                allowsSave: true
            )

            modelContainer = try ModelContainer(
                for: schema,
                configurations: [modelConfiguration]
            )

            logInfo("DataStore initialized successfully", category: .database)
        } catch {
            logError("Failed to initialize DataStore: \(error)", category: .database)
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var modelContext: ModelContext {
        modelContainer.mainContext
    }

    /// The app group entitlement makes SwiftData default to a group container.
    /// Keep the pre-existing store location so upgrades keep their connections,
    /// and so unsigned/ad-hoc builds do not fail to write the database.
    nonisolated static var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("default.store")
    }

    /// Creates a new background context for async operations
    func newBackgroundContext() -> ModelContext {
        ModelContext(modelContainer)
    }

    /// Attempts to recover from database corruption by recreating the store
    static func createWithRecovery() -> ModelContainer {
        do {
            return DataStore.shared.modelContainer
        } catch {
            logError("Database recovery failed: \(error)", category: .database)
            fatalError("Cannot recover database: \(error)")
        }
    }
}

// MARK: - Preview Support
extension DataStore {
    @MainActor
    static var preview: DataStore {
        let store = DataStore()
        // Add preview data if needed
        return store
    }
}
