//
//  SwiftDataStoreMigratorTests.swift
//  macSCPTests
//
//  Unit tests for moving the SwiftData store out of SwiftData's shared default
//  location into the app-specific one.
//

import XCTest
@testable import macSCP

final class SwiftDataStoreMigratorTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fileManager.temporaryDirectory
            .appendingPathComponent("macscp-store-migration-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root = root {
            try? fileManager.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    private var legacyURL: URL {
        root.appendingPathComponent("legacy/default.store")
    }

    private var destinationURL: URL {
        root.appendingPathComponent("app/macSCP/macSCP.store")
    }

    private func writeLegacyStore() throws {
        try fileManager.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        for suffix in SwiftDataStoreMigrator.sidecarSuffixes {
            let url = URL(fileURLWithPath: legacyURL.path + suffix)
            try Data("legacy\(suffix)".utf8).write(to: url)
        }
    }

    func testMovesStoreAndSidecars() throws {
        try writeLegacyStore()

        let migrated = try SwiftDataStoreMigrator.migrateIfNeeded(
            from: legacyURL,
            to: destinationURL,
            fileManager: fileManager
        )

        XCTAssertTrue(migrated)
        for suffix in SwiftDataStoreMigrator.sidecarSuffixes {
            let destination = URL(fileURLWithPath: destinationURL.path + suffix)
            let legacy = URL(fileURLWithPath: legacyURL.path + suffix)

            XCTAssertTrue(fileManager.fileExists(atPath: destination.path), "missing destination\(suffix)")
            XCTAssertFalse(fileManager.fileExists(atPath: legacy.path), "legacy\(suffix) still present")
            XCTAssertEqual(try Data(contentsOf: destination), Data("legacy\(suffix)".utf8))
        }
    }

    func testDoesNothingWhenDestinationAlreadyExists() throws {
        try writeLegacyStore()
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("new".utf8).write(to: destinationURL)

        let migrated = try SwiftDataStoreMigrator.migrateIfNeeded(
            from: legacyURL,
            to: destinationURL,
            fileManager: fileManager
        )

        XCTAssertFalse(migrated)
        XCTAssertEqual(try Data(contentsOf: destinationURL), Data("new".utf8))
        XCTAssertTrue(fileManager.fileExists(atPath: legacyURL.path))
    }

    func testDoesNothingWhenLegacyStoreIsMissing() throws {
        let migrated = try SwiftDataStoreMigrator.migrateIfNeeded(
            from: legacyURL,
            to: destinationURL,
            fileManager: fileManager
        )

        XCTAssertFalse(migrated)
        XCTAssertFalse(fileManager.fileExists(atPath: destinationURL.path))
    }

    func testRollsBackWhenMoveFails() throws {
        try writeLegacyStore()

        // A read-only destination directory makes the move fail mid-migration.
        let destinationDirectory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: destinationDirectory.path)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationDirectory.path)
        }

        XCTAssertThrowsError(
            try SwiftDataStoreMigrator.migrateIfNeeded(
                from: legacyURL,
                to: destinationURL,
                fileManager: fileManager
            )
        )

        for suffix in SwiftDataStoreMigrator.sidecarSuffixes {
            let legacy = URL(fileURLWithPath: legacyURL.path + suffix)
            XCTAssertTrue(fileManager.fileExists(atPath: legacy.path), "legacy\(suffix) should be restored")
        }
    }

    // MARK: - Locations

    func testApplicationStoreIsNamespacedByApp() {
        let url = DataStore.applicationStoreURL()

        XCTAssertEqual(url.lastPathComponent, "macSCP.store")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "macSCP")
    }

    func testSharedDefaultStoreIsSwiftDataDefault() {
        XCTAssertEqual(DataStore.sharedDefaultStoreURL().lastPathComponent, "default.store")
    }

    func testSandboxContainerStorePathUsesBundleIdentifier() {
        let url = DataStore.sandboxContainerStoreURL(bundleIdentifier: "com.example.app")

        XCTAssertTrue(url.path.contains("/Library/Containers/com.example.app/Data/Library/Application Support/"))
        XCTAssertEqual(url.lastPathComponent, "default.store")
    }

    func testLegacyCandidatesPreferSandboxContainer() {
        let candidates = DataStore.legacyStoreCandidates()

        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(candidates[0].path.contains("/Library/Containers/"))
        XCTAssertEqual(candidates[1], DataStore.sharedDefaultStoreURL())
    }

    // MARK: - Store identification

    func testDetectsMacSCPStoreBySchemaMarker() throws {
        let ours = root.appendingPathComponent("ours.store")
        try Data("sqlite...ZCONNECTIONENTITY...".utf8).write(to: ours)
        XCTAssertTrue(SwiftDataStoreMigrator.looksLikeMacSCPStore(at: ours))

        let foreign = root.appendingPathComponent("foreign.store")
        try Data("sqlite...ZFOREIGNENTITY...".utf8).write(to: foreign)
        XCTAssertFalse(SwiftDataStoreMigrator.looksLikeMacSCPStore(at: foreign))
    }

    func testDetectsSchemaMarkerInWALFile() throws {
        let store = root.appendingPathComponent("wal-only.store")
        try Data("empty".utf8).write(to: store)
        try Data("ZCONNECTIONENTITY".utf8).write(to: URL(fileURLWithPath: store.path + "-wal"))

        XCTAssertTrue(SwiftDataStoreMigrator.looksLikeMacSCPStore(at: store))
    }

    func testMainStoreMovesLast() {
        XCTAssertEqual(SwiftDataStoreMigrator.sidecarSuffixes.first, "-wal")
        XCTAssertEqual(SwiftDataStoreMigrator.sidecarSuffixes.last, "")
    }
}
