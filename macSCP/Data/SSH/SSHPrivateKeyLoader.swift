//
//  SSHPrivateKeyLoader.swift
//  macSCP
//
//  Loads OpenSSH private keys and builds the matching Citadel authentication
//  method. Shared by SFTPSession and TerminalSession so both support the same
//  key types with the same error messages.
//

import Foundation
import Citadel
import Crypto

enum SSHPrivateKeyError: LocalizedError, Equatable, Sendable {
    case unreadable(path: String)
    case unsupportedFormat
    case legacyPEMFormat
    case malformed
    case unsupportedKeyType(String)
    case passphraseRequired
    case incorrectPassphrase
    case unsupportedKeyEncryption(rounds: Int)

    var errorDescription: String? {
        switch self {
        case .unreadable(let path):
            return "Cannot read the private key at \(path). Check the path and file permissions."
        case .unsupportedFormat:
            return "This file is not an OpenSSH private key. Convert it with: ssh-keygen -p -f <key>"
        case .legacyPEMFormat:
            return "Legacy PEM private keys are not supported. Convert with: ssh-keygen -p -f <key>"
        case .malformed:
            return "The private key is damaged or in an unexpected format."
        case .unsupportedKeyType(let type):
            return "The \(type) key type is not supported. macSCP supports RSA and ed25519 keys."
        case .passphraseRequired:
            return "This key is protected by a passphrase, which is not supported yet. Use an unencrypted key."
        case .incorrectPassphrase:
            return "The passphrase for this private key is incorrect."
        case .unsupportedKeyEncryption(let rounds):
            return "This key uses \(rounds) bcrypt KDF rounds, but the SSH library supports fewer than \(Self.maxSupportedBCryptRounds). Re-encrypt it with ssh-keygen -p -a 16 -f <key>, or use an unencrypted key."
        }
    }

    /// Citadel 0.11.x rejects bcrypt KDF rounds at or above this value. OpenSSH 10
    /// defaults to 24, so passphrase-protected keys made on macOS 27 hit this.
    static let maxSupportedBCryptRounds = 18
}

enum SSHPrivateKeyLoader {
    enum KeyType: String, Sendable {
        case rsa = "ssh-rsa"
        case ed25519 = "ssh-ed25519"
    }

    struct Inspection: Equatable, Sendable {
        let type: KeyType
        let isEncrypted: Bool
    }

    struct LoadedKey {
        let method: SSHAuthenticationMethod
        let inspection: Inspection
    }

    /// Explains why an RSA key can fail even though the key itself is valid.
    /// Citadel 0.11.x/0.12.x signs with SHA-1 and labels the signature
    /// `ssh-rsa`; OpenSSH 8.8+ disables that algorithm by default, so servers
    /// require the newer rsa-sha2-256/512 signatures instead.
    static let legacyRSASignatureMessage = "The server rejected this RSA key. macSCP signs RSA authentication with the legacy ssh-rsa (SHA-1) algorithm, which modern OpenSSH servers disable. Use an ed25519 key instead."

    // MARK: - Public API

    /// Loads the key at `keyPath` and builds the Citadel authentication method,
    /// returning the detected key type so callers can explain failures.
    static func load(
        username: String,
        keyPath: String,
        passphrase: String? = nil
    ) throws -> LoadedKey {
        let pem = try readPEM(at: keyPath)
        let inspection = try inspect(pem: pem)
        let method = try authenticationMethod(
            username: username,
            pem: pem,
            inspection: inspection,
            passphrase: passphrase
        )
        return LoadedKey(method: method, inspection: inspection)
    }

    /// Builds the Citadel authentication method for the key at `keyPath`.
    /// Passing `passphrase` for an encrypted key decrypts it; encrypted keys
    /// without a passphrase throw `.passphraseRequired` instead of failing with
    /// an opaque authentication error.
    static func authenticationMethod(
        username: String,
        keyPath: String,
        passphrase: String? = nil
    ) throws -> SSHAuthenticationMethod {
        let pem = try readPEM(at: keyPath)
        let inspection = try inspect(pem: pem)
        return try authenticationMethod(
            username: username,
            pem: pem,
            inspection: inspection,
            passphrase: passphrase
        )
    }

    /// Detects the key type without building an authentication method.
    static func inspection(atPath keyPath: String) throws -> Inspection {
        try inspect(pem: readPEM(at: keyPath))
    }

    // MARK: - Internals

    private static func readPEM(at keyPath: String) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: keyPath))
        } catch {
            throw SSHPrivateKeyError.unreadable(path: keyPath)
        }

        guard let pem = String(data: data, encoding: .utf8) else {
            throw SSHPrivateKeyError.unsupportedFormat
        }
        return pem
    }

    private static func authenticationMethod(
        username: String,
        pem: String,
        inspection: Inspection,
        passphrase: String?
    ) throws -> SSHAuthenticationMethod {
        let decryptionKey = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }

        if inspection.isEncrypted, decryptionKey == nil {
            throw SSHPrivateKeyError.passphraseRequired
        }

        do {
            switch inspection.type {
            case .rsa:
                let key = try Insecure.RSA.PrivateKey(sshRsa: pem, decryptionKey: decryptionKey)
                return .rsa(username: username, privateKey: key)
            case .ed25519:
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: pem, decryptionKey: decryptionKey)
                return .ed25519(username: username, privateKey: key)
            }
        } catch {
            throw inspection.isEncrypted
                ? SSHPrivateKeyError.incorrectPassphrase
                : SSHPrivateKeyError.malformed
        }
    }

    /// Reads only the OpenSSH key header: enough to know the algorithm and
    /// whether a passphrase is needed, without decrypting anything.
    static func inspect(pem: String) throws -> Inspection {
        if pem.contains("-----BEGIN RSA PRIVATE KEY-----")
            || pem.contains("-----BEGIN EC PRIVATE KEY-----")
            || pem.contains("-----BEGIN DSA PRIVATE KEY-----") {
            throw SSHPrivateKeyError.legacyPEMFormat
        }

        guard let payload = openSSHPayload(from: pem) else {
            throw SSHPrivateKeyError.unsupportedFormat
        }

        var reader = ByteReader([UInt8](payload))

        let magic = "openssh-key-v1"
        guard reader.readFixedString(count: magic.utf8.count) == magic,
              reader.readUInt8() == 0 else {
            throw SSHPrivateKeyError.malformed
        }

        guard let cipher = reader.readSSHString(),
              let kdf = reader.readSSHString(),
              let kdfOptions = reader.readSSHBuffer(),
              reader.readUInt32() != nil,         // number of keys
              let publicKeyBlob = reader.readSSHBlob() else {
            throw SSHPrivateKeyError.malformed
        }

        // Refuse early when the library cannot decrypt this key at all.
        if kdf == "bcrypt" {
            var optionsReader = ByteReader(kdfOptions)
            _ = optionsReader.readSSHBuffer()      // salt
            if let rounds = optionsReader.readUInt32(),
               rounds >= UInt32(SSHPrivateKeyError.maxSupportedBCryptRounds) {
                throw SSHPrivateKeyError.unsupportedKeyEncryption(rounds: Int(rounds))
            }
        }

        var blobReader = ByteReader(publicKeyBlob)
        guard let typeName = blobReader.readSSHString() else {
            throw SSHPrivateKeyError.malformed
        }
        guard let type = KeyType(rawValue: typeName) else {
            throw SSHPrivateKeyError.unsupportedKeyType(typeName)
        }

        return Inspection(type: type, isEncrypted: cipher != "none")
    }

    // MARK: - Parsing Helpers

    private static func openSSHPayload(from pem: String) -> Data? {
        let header = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let footer = "-----END OPENSSH PRIVATE KEY-----"

        guard let headerRange = pem.range(of: header),
              let footerRange = pem.range(of: footer, range: headerRange.upperBound..<pem.endIndex) else {
            return nil
        }

        let base64Body = pem[headerRange.upperBound..<footerRange.lowerBound]
            .filter { !$0.isWhitespace }
        return Data(base64Encoded: String(base64Body), options: [.ignoreUnknownCharacters])
    }

    /// Minimal big-endian reader for the SSH wire format used by OpenSSH keys.
    private struct ByteReader {
        private let bytes: [UInt8]
        private var index = 0

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
        }

        var isAtEnd: Bool {
            index >= bytes.count
        }

        mutating func readUInt8() -> UInt8? {
            guard index < bytes.count else { return nil }
            defer { index += 1 }
            return bytes[index]
        }

        mutating func readUInt32() -> UInt32? {
            guard index + 4 <= bytes.count else { return nil }
            defer { index += 4 }
            return bytes[index..<index + 4].reduce(0) { ($0 << 8) | UInt32($1) }
        }

        mutating func readFixedString(count: Int) -> String? {
            guard count > 0, index + count <= bytes.count else { return nil }
            defer { index += count }
            return String(decoding: bytes[index..<index + count], as: UTF8.self)
        }

        mutating func readSSHBuffer() -> [UInt8]? {
            guard let length = readUInt32() else { return nil }
            let count = Int(length)
            guard index + count <= bytes.count else { return nil }
            defer { index += count }
            return Array(bytes[index..<index + count])
        }

        mutating func readSSHString() -> String? {
            guard let buffer = readSSHBuffer() else { return nil }
            return String(decoding: buffer, as: UTF8.self)
        }

        mutating func readSSHBlob() -> [UInt8]? {
            readSSHBuffer()
        }
    }
}
