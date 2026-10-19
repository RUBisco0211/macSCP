//
//  SSHConfigImporterTests.swift
//  macSCPTests
//
//  Unit tests for mapping parsed ssh_config entries onto Connection models.
//

import XCTest
@testable import macSCP

final class SSHConfigImporterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(
        alias: String = "lab",
        hostName: String = "lab.example.com",
        user: String? = "deploy",
        port: Int = 1185,
        identityFile: String? = "/Users/test/.ssh/id_rsa"
    ) -> SSHConfigEntry {
        SSHConfigEntry(
            alias: alias,
            hostName: hostName,
            user: user,
            port: port,
            identityFile: identityFile
        )
    }

    func testMapsEntryToKeyBasedConnection() throws {
        let connections = SSHConfigImporter.connections(
            from: [entry()],
            defaultUsername: "fallback",
            now: now
        )

        XCTAssertEqual(connections.count, 1)
        let connection = try XCTUnwrap(connections.first)

        XCTAssertEqual(connection.name, "lab")
        XCTAssertEqual(connection.host, "lab.example.com")
        XCTAssertEqual(connection.port, 1185)
        XCTAssertEqual(connection.username, "deploy")
        XCTAssertEqual(connection.authMethod, .privateKey)
        XCTAssertEqual(connection.privateKeyPath, "/Users/test/.ssh/id_rsa")
        XCTAssertFalse(connection.savePassword)
        XCTAssertEqual(connection.connectionType, .sftp)
        XCTAssertEqual(connection.createdAt, now)
        XCTAssertTrue(connection.isValid)
    }

    func testDoesNotPrefillUserOwnedFields() throws {
        let connection = try XCTUnwrap(
            SSHConfigImporter.connections(from: [entry()], now: now).first
        )

        XCTAssertTrue(connection.tags.isEmpty)
        XCTAssertNil(connection.description)
        XCTAssertNil(connection.folderId)
        XCTAssertEqual(connection.iconName, "server.rack")
    }

    func testFallsBackToPasswordAuthAndDefaultUsername() throws {
        let connections = SSHConfigImporter.connections(
            from: [entry(user: nil, identityFile: nil)],
            defaultUsername: "fallback",
            now: now
        )

        let connection = try XCTUnwrap(connections.first)
        XCTAssertEqual(connection.username, "fallback")
        XCTAssertEqual(connection.authMethod, .password)
        XCTAssertNil(connection.privateKeyPath)
        XCTAssertTrue(connection.isValid)
    }

    // MARK: - Deduplication key

    func testDeduplicationKeyCombinesHostPortAndUsername() {
        let connection = Connection(
            name: "lab",
            host: "Lab.Example.com",
            port: 1185,
            username: "Deploy"
        )

        XCTAssertEqual(
            SSHConfigImporter.deduplicationKey(for: connection),
            "lab.example.com|1185|deploy"
        )
    }

    func testDeduplicationKeyIgnoresTheAlias() {
        let first = Connection(name: "one", host: "lab.example.com", port: 22, username: "deploy")
        let second = Connection(name: "two", host: "lab.example.com", port: 22, username: "deploy")

        XCTAssertEqual(
            SSHConfigImporter.deduplicationKey(for: first),
            SSHConfigImporter.deduplicationKey(for: second)
        )
    }
}
