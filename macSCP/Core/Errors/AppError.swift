//
//  AppError.swift
//  macSCP
//
//  Unified error types for the application
//

import Foundation

enum AppError: LocalizedError, Sendable {
    // Connection errors
    case connectionFailed(String)
    case connectionTimeout
    case connectionLost
    case authenticationFailed
    case hostUnreachable
    case privateKeyError(String)

    // SFTP errors
    case sftpOperationFailed(String)
    case permissionDenied
    case fileNotFound
    case fileAlreadyExists
    case directoryNotEmpty
    case invalidPath

    // S3 errors
    case s3BucketNotFound
    case s3AccessDenied
    case s3ObjectNotFound
    case s3OperationFailed(String)
    case invalidS3Credentials

    // Data errors
    case saveFailed(String)
    case fetchFailed(String)
    case deleteFailed(String)
    case entityNotFound

    // Keychain errors
    case keychainSaveFailed
    case keychainReadFailed
    case keychainDeleteFailed

    // File operation errors
    case downloadFailed(String)
    case uploadFailed(String)
    case fileReadFailed
    case fileWriteFailed

    // Terminal errors
    case terminalConnectionFailed(String)
    case terminalConnectionLost
    case terminalPTYFailed

    // Biometric errors
    case biometricNotAvailable
    case biometricAuthFailed(String)

    // General errors
    case unknown(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let message):
            return String(localized: "Connection failed: \(message)")
        case .connectionTimeout:
            return String(localized: "Connection timed out")
        case .connectionLost:
            return String(localized: "Connection was lost")
        case .authenticationFailed:
            return String(localized: "Authentication failed. Please check your credentials.")
        case .privateKeyError(let message):
            return message
        case .hostUnreachable:
            return String(localized: "Host is unreachable. Check the hostname and network connection.")

        case .sftpOperationFailed(let message):
            return String(localized: "SFTP operation failed: \(message)")
        case .permissionDenied:
            return String(localized: "Permission denied")
        case .fileNotFound:
            return String(localized: "File or directory not found")
        case .fileAlreadyExists:
            return String(localized: "A file or directory with this name already exists")
        case .directoryNotEmpty:
            return String(localized: "Directory is not empty")
        case .invalidPath:
            return String(localized: "Invalid path")

        case .s3BucketNotFound:
            return String(localized: "S3 bucket not found")
        case .s3AccessDenied:
            return String(localized: "Access denied to S3 resource")
        case .s3ObjectNotFound:
            return String(localized: "S3 object not found")
        case .s3OperationFailed(let message):
            return String(localized: "S3 operation failed: \(message)")
        case .invalidS3Credentials:
            return String(localized: "Invalid S3 credentials")

        case .saveFailed(let message):
            return String(localized: "Failed to save: \(message)")
        case .fetchFailed(let message):
            return String(localized: "Failed to fetch: \(message)")
        case .deleteFailed(let message):
            return String(localized: "Failed to delete: \(message)")
        case .entityNotFound:
            return String(localized: "Entity not found")

        case .keychainSaveFailed:
            return String(localized: "Failed to save password to keychain")
        case .keychainReadFailed:
            return String(localized: "Failed to read password from keychain")
        case .keychainDeleteFailed:
            return String(localized: "Failed to delete password from keychain")

        case .downloadFailed(let message):
            return String(localized: "Download failed: \(message)")
        case .uploadFailed(let message):
            return String(localized: "Upload failed: \(message)")
        case .fileReadFailed:
            return String(localized: "Failed to read file")
        case .fileWriteFailed:
            return String(localized: "Failed to write file")

        case .terminalConnectionFailed(let message):
            return String(localized: "Terminal connection failed: \(message)")
        case .terminalConnectionLost:
            return String(localized: "Terminal connection was lost")
        case .terminalPTYFailed:
            return String(localized: "Failed to allocate pseudo-terminal")

        case .biometricNotAvailable:
            return String(localized: "Touch ID is not available on this Mac")
        case .biometricAuthFailed(let message):
            return String(localized: "Authentication failed: \(message)")

        case .unknown(let message):
            return message
        case .notConnected:
            return String(localized: "Not connected to server")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .connectionFailed, .connectionTimeout, .hostUnreachable:
            return String(localized: "Please check your network connection and server address.")
        case .authenticationFailed:
            return String(localized: "Please verify your username and password.")
        case .permissionDenied, .s3AccessDenied:
            return String(localized: "You don't have permission to perform this action.")
        case .notConnected:
            return String(localized: "Please connect to a server first.")
        case .s3BucketNotFound:
            return String(localized: "Please check your bucket name and region.")
        case .invalidS3Credentials:
            return String(localized: "Please verify your Access Key ID and Secret Access Key.")
        case .terminalConnectionFailed, .terminalConnectionLost:
            return String(localized: "Please check your network connection and try reconnecting.")
        case .terminalPTYFailed:
            return String(localized: "The server may not support interactive terminals. Please try again.")
        case .biometricNotAvailable:
            return String(localized: "Use a Mac with Touch ID or pair an Apple Watch to enable biometric authentication.")
        case .biometricAuthFailed:
            return String(localized: "Please try again or use your system password.")
        default:
            return nil
        }
    }
}

// MARK: - Error Conversion
extension AppError {
    static func from(_ error: Error) -> AppError {
        if let appError = error as? AppError {
            return appError
        }
        return .unknown(error.localizedDescription)
    }
}
