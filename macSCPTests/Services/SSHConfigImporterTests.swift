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
        user: String? = "linminlei",
        port: Int = 1185,
        identityFiles: [String] = ["/Users/test/.ssh/id_rsa"]
    ) -> SSHConfigEntry {
        SSHConfigEntry(
            alias: alias,
            hostName: hostName,
            user: user,
            port: port,
            identityFiles: identityFiles,
            unsupportedDirectives: []
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
        XCTAssertEqual(connection.username, "linminlei")
        XCTAssertEqual(connection.authMethod, .privateKey)
        XCTAssertEqual(connection.privateKeyPath, "/Users/test/.ssh/id_rsa")
        XCTAssertFalse(connection.savePassword)
        XCTAssertEqual(connection.tags, ["ssh-config"])
        XCTAssertNil(connection.folderId)
        XCTAssertEqual(connection.connectionType, .sftp)
        XCTAssertEqual(connection.createdAt, now)
        XCTAssertTrue(connection.isValid)
    }

    func testFallsBackToPasswordAuthAndDefaultUsername() throws {
        let connections = SSHConfigImporter.connections(
            from: [entry(user: nil, identityFiles: [])],
            defaultUsername: "fallback",
            now: now
        )

        let connection = try XCTUnwrap(connections.first)
        XCTAssertEqual(connection.username, "fallback")
        XCTAssertEqual(connection.authMethod, .password)
        XCTAssertNil(connection.privateKeyPath)
        XCTAssertTrue(connection.isValid)
    }

    func testImportsEveryEntryWithoutDeduplication() {
        let connections = SSHConfigImporter.connections(
            from: [
                entry(alias: "lab-port-1185"),
                entry(alias: "lab-port-1185-codex")
            ],
            defaultUsername: "fallback",
            now: now
        )

        XCTAssertEqual(connections.map(\.name), ["lab-port-1185", "lab-port-1185-codex"])
    }

    func testUsesProvidedFolderWhenRequested() {
        let folderId = UUID()
        let connections = SSHConfigImporter.connections(
            from: [entry()],
            folderId: folderId,
            now: now
        )

        XCTAssertEqual(connections.first?.folderId, folderId)
    }
}
