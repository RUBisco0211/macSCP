//
//  SSHPrivateKeyLoaderTests.swift
//  macSCPTests
//
//  Tests for key type detection and Citadel authentication method construction.
//  RSA/ed25519 fixtures are generated at runtime with /usr/bin/ssh-keygen so no
//  private key material is committed to the repository.
//

import XCTest
@testable import macSCP

final class SSHPrivateKeyLoaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscp-key-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory = directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Detection

    func testDetectsUnencryptedEd25519Key() throws {
        let url = try generateKey(type: "ed25519", passphrase: "", name: "id_ed25519")
        let inspection = try SSHPrivateKeyLoader.inspect(pem: try contents(of: url))

        XCTAssertEqual(inspection.type, .ed25519)
        XCTAssertFalse(inspection.isEncrypted)
    }

    func testDetectsUnencryptedRSAKey() throws {
        let url = try generateKey(type: "rsa", passphrase: "", name: "id_rsa")
        let inspection = try SSHPrivateKeyLoader.inspect(pem: try contents(of: url))

        XCTAssertEqual(inspection.type, .rsa)
        XCTAssertFalse(inspection.isEncrypted)
    }

    func testDetectsEncryptedKey() throws {
        let url = try generateKey(type: "ed25519", passphrase: "secret123", name: "id_ed25519_enc")
        let inspection = try SSHPrivateKeyLoader.inspect(pem: try contents(of: url))

        XCTAssertEqual(inspection.type, .ed25519)
        XCTAssertTrue(inspection.isEncrypted)
    }

    func testRejectsUnsupportedKeyType() {
        let pem = makeOpenSSHPEM(keyType: "ecdsa-sha2-nistp256")

        XCTAssertThrowsError(try SSHPrivateKeyLoader.inspect(pem: pem)) { error in
            XCTAssertEqual(error as? SSHPrivateKeyError, .unsupportedKeyType("ecdsa-sha2-nistp256"))
        }
    }

    func testRejectsLegacyPEMFormat() {
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----\n"

        XCTAssertThrowsError(try SSHPrivateKeyLoader.inspect(pem: pem)) { error in
            XCTAssertEqual(error as? SSHPrivateKeyError, .legacyPEMFormat)
        }
    }

    func testRejectsUnsupportedFormat() {
        XCTAssertThrowsError(try SSHPrivateKeyLoader.inspect(pem: "not a key")) { error in
            XCTAssertEqual(error as? SSHPrivateKeyError, .unsupportedFormat)
        }
    }

    func testRejectsMalformedOpenSSHKey() {
        let pem = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjE=
        -----END OPENSSH PRIVATE KEY-----
        """

        XCTAssertThrowsError(try SSHPrivateKeyLoader.inspect(pem: pem)) { error in
            XCTAssertEqual(error as? SSHPrivateKeyError, .malformed)
        }
    }

    // MARK: - Authentication Method

    func testBuildsEd25519AuthenticationMethod() throws {
        let url = try generateKey(type: "ed25519", passphrase: "", name: "id_ed25519")

        XCTAssertNoThrow(
            try SSHPrivateKeyLoader.authenticationMethod(
                username: "tester",
                keyPath: url.path
            )
        )
    }

    func testBuildsRSAAuthenticationMethod() throws {
        let url = try generateKey(type: "rsa", passphrase: "", name: "id_rsa")

        XCTAssertNoThrow(
            try SSHPrivateKeyLoader.authenticationMethod(
                username: "tester",
                keyPath: url.path
            )
        )
    }

    func testEncryptedKeyWithoutPassphraseRequiresPassphrase() throws {
        let url = try generateKey(type: "ed25519", passphrase: "secret123", rounds: 16, name: "id_ed25519_enc")

        XCTAssertThrowsError(
            try SSHPrivateKeyLoader.authenticationMethod(
                username: "tester",
                keyPath: url.path
            )
        ) { error in
            XCTAssertEqual(error as? SSHPrivateKeyError, .passphraseRequired)
        }
    }

    func testEncryptedKeyWithPassphraseIsAccepted() throws {
        let url = try generateKey(type: "ed25519", passphrase: "secret123", rounds: 16, name: "id_ed25519_enc")

        XCTAssertNoThrow(
            try SSHPrivateKeyLoader.authenticationMethod(
                username: "tester",
                keyPath: url.path,
                passphrase: "secret123"
            )
        )
    }

    func testEncryptedKeyWithWrongPassphraseFails() throws {
        let url = try generateKey(type: "ed25519", passphrase: "secret123", rounds: 16, name: "id_ed25519_enc")

        XCTAssertThrowsError(
            try SSHPrivateKeyLoader.authenticationMethod(
                username: "tester",
                keyPath: url.path,
                passphrase: "wrong"
            )
        ) { error in
            XCTAssertEqual(error as? SSHPrivateKeyError, .incorrectPassphrase)
        }
    }

    func testMissingKeyFileIsReported() {
        let path = directory.appendingPathComponent("does-not-exist").path

        XCTAssertThrowsError(
            try SSHPrivateKeyLoader.authenticationMethod(username: "tester", keyPath: path)
        ) { error in
            XCTAssertEqual(error as? SSHPrivateKeyError, .unreadable(path: path))
        }
    }

    func testEncryptedKeyWithOpenSSHDefaultRoundsIsAccepted() throws {
        // OpenSSH 10 defaults to 24 bcrypt rounds; the pinned Citadel supports < 32.
        let url = try generateKey(type: "ed25519", passphrase: "secret123", name: "id_ed25519_default_rounds")

        XCTAssertNoThrow(
            try SSHPrivateKeyLoader.authenticationMethod(
                username: "tester",
                keyPath: url.path,
                passphrase: "secret123"
            )
        )
    }

    func testEncryptedKeyBeyondSupportedKDFRoundsIsRejected() throws {
        let url = try generateKey(type: "ed25519", passphrase: "secret123", rounds: 32, name: "id_ed25519_heavy")

        XCTAssertThrowsError(
            try SSHPrivateKeyLoader.authenticationMethod(
                username: "tester",
                keyPath: url.path,
                passphrase: "secret123"
            )
        ) { error in
            XCTAssertEqual(error as? SSHPrivateKeyError, .unsupportedKeyEncryption(rounds: 32))
        }
    }

    // MARK: - Helpers

    private func contents(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func generateKey(type: String, passphrase: String, rounds: Int = 0, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")

        var arguments = ["-t", type, "-f", url.path, "-N", passphrase, "-C", "macscp-test"]
        if type == "rsa" {
            arguments.insert(contentsOf: ["-b", "2048"], at: 2)
        }
        if rounds > 0 {
            arguments.append(contentsOf: ["-a", String(rounds)])
        }
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw XCTSkip("ssh-keygen is unavailable: \(error)")
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("ssh-keygen failed with status \(process.terminationStatus)")
        }
        return url
    }

    /// Builds the header of an OpenSSH private key: enough for type/encryption
    /// detection, with a dummy private section.
    private func makeOpenSSHPEM(keyType: String, cipher: String = "none") -> String {
        var bytes: [UInt8] = []

        func appendUInt32(_ value: UInt32) {
            bytes.append(UInt8((value >> 24) & 0xFF))
            bytes.append(UInt8((value >> 16) & 0xFF))
            bytes.append(UInt8((value >> 8) & 0xFF))
            bytes.append(UInt8(value & 0xFF))
        }

        func appendSSHString(_ string: String) {
            let encoded = Array(string.utf8)
            appendUInt32(UInt32(encoded.count))
            bytes.append(contentsOf: encoded)
        }

        bytes.append(contentsOf: Array("openssh-key-v1".utf8))
        bytes.append(0)
        appendSSHString(cipher)
        appendSSHString("none")   // KDF name
        appendSSHString("")       // KDF options
        appendUInt32(1)           // number of keys

        var blob: [UInt8] = []
        let typeBytes = Array(keyType.utf8)
        blob.append(UInt8((UInt32(typeBytes.count) >> 24) & 0xFF))
        blob.append(UInt8((UInt32(typeBytes.count) >> 16) & 0xFF))
        blob.append(UInt8((UInt32(typeBytes.count) >> 8) & 0xFF))
        blob.append(UInt8(UInt32(typeBytes.count) & 0xFF))
        blob.append(contentsOf: typeBytes)
        blob.append(contentsOf: [1, 2, 3, 4])

        appendUInt32(UInt32(blob.count))
        bytes.append(contentsOf: blob)

        let base64 = Data(bytes).base64EncodedString()
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(base64)\n-----END OPENSSH PRIVATE KEY-----\n"
    }
}
