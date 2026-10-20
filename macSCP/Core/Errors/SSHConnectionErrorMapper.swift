//
//  SSHConnectionErrorMapper.swift
//  macSCP
//
//  Maps Citadel/SSH errors onto user-facing AppError values.
//
//  Shared by SFTPSession and TerminalSession so both explain failures the same
//  way. Returns nil for errors it does not recognise so callers can apply their
//  own fallback.
//

import Citadel
import Foundation

enum SSHConnectionErrorMapper {
    static func map(_ error: Error, keyType: SSHPrivateKeyLoader.KeyType?) -> AppError? {
        let description = error.localizedDescription.lowercased()

        if description.contains("connection refused") {
            return .connectionFailed(
                String(localized: "Connection refused. Make sure the SSH server is running."))
        }
        if description.contains("host unreachable") || description.contains("no route to host") {
            return .hostUnreachable
        }
        if description.contains("timeout") || description.contains("timed out") {
            return .connectionTimeout
        }
        if isAuthenticationFailure(error) {
            // RSA offers rsa-sha2-512/256 and ssh-rsa, so a rejection means the
            // key (not the signature algorithm) is the likely problem.
            if keyType == .rsa {
                return .privateKeyError(SSHPrivateKeyLoader.rsaAuthenticationRejectedMessage)
            }
            return .authenticationFailed
        }
        if description.contains("operation not permitted") {
            return .connectionFailed(
                String(localized: "Operation not permitted. Check firewall settings."))
        }

        return nil
    }

    /// `SSHClientError.allAuthenticationOptionsFailed` (error code 4) carries no
    /// useful description, so it is matched by type first.
    private static func isAuthenticationFailure(_ error: Error) -> Bool {
        if let sshError = error as? SSHClientError {
            switch sshError {
            case .allAuthenticationOptionsFailed,
                .unsupportedPrivateKeyAuthentication,
                .unsupportedPasswordAuthentication,
                .unsupportedHostBasedAuthentication:
                return true
            case .channelCreationFailed:
                return false
            }
        }

        let description = error.localizedDescription.lowercased()
        return description.contains("authentication")
            || description.contains("permission denied")
            || description.contains("citadel.sshclienterror")
    }
}
