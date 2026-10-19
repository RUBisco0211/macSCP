//
//  SSHConnectionErrorMapperTests.swift
//  macSCPTests
//
//  Unit tests for translating SSH errors into user-facing messages.
//

import XCTest
import Citadel
@testable import macSCP

final class SSHConnectionErrorMapperTests: XCTestCase {
    func testAllAuthenticationOptionsFailedWithRSAKeyExplainsOfferedAlgorithms() throws {
        let mapped = SSHConnectionErrorMapper.map(
            SSHClientError.allAuthenticationOptionsFailed,
            keyType: .rsa
        )

        guard case .privateKeyError(let message) = try XCTUnwrap(mapped) else {
            return XCTFail("expected a privateKeyError, got \(String(describing: mapped))")
        }
        XCTAssertTrue(message.lowercased().contains("rsa-sha2-512"))
        XCTAssertTrue(message.lowercased().contains("authorized"))
    }

    func testAllAuthenticationOptionsFailedWithEd25519KeyIsPlainAuthFailure() throws {
        let mapped = SSHConnectionErrorMapper.map(
            SSHClientError.allAuthenticationOptionsFailed,
            keyType: .ed25519
        )

        guard case .authenticationFailed = try XCTUnwrap(mapped) else {
            return XCTFail("expected authenticationFailed, got \(String(describing: mapped))")
        }
    }

    func testAllAuthenticationOptionsFailedWithoutKeyTypeIsPlainAuthFailure() throws {
        let mapped = SSHConnectionErrorMapper.map(
            SSHClientError.allAuthenticationOptionsFailed,
            keyType: nil
        )

        guard case .authenticationFailed = try XCTUnwrap(mapped) else {
            return XCTFail("expected authenticationFailed, got \(String(describing: mapped))")
        }
    }

    func testConnectionRefusedIsReportedAsConnectionFailure() throws {
        let error = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ECONNREFUSED),
            userInfo: [NSLocalizedDescriptionKey: "Connection refused"]
        )

        let mapped = SSHConnectionErrorMapper.map(error, keyType: nil)

        guard case .connectionFailed = try XCTUnwrap(mapped) else {
            return XCTFail("expected connectionFailed, got \(String(describing: mapped))")
        }
    }

    func testTimeoutIsReportedAsTimeout() throws {
        let error = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ETIMEDOUT),
            userInfo: [NSLocalizedDescriptionKey: "Operation timed out"]
        )

        let mapped = SSHConnectionErrorMapper.map(error, keyType: nil)

        guard case .connectionTimeout = try XCTUnwrap(mapped) else {
            return XCTFail("expected connectionTimeout, got \(String(describing: mapped))")
        }
    }

    func testUnrecognisedErrorIsLeftToTheCaller() {
        let error = NSError(domain: "test", code: 1, userInfo: nil)

        XCTAssertNil(SSHConnectionErrorMapper.map(error, keyType: nil))
    }
}
