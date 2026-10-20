//
//  ConnectionType.swift
//  macSCP
//
//  Connection type for distinguishing SFTP vs S3 connections
//

import Foundation

enum ConnectionType: String, Codable, Sendable, CaseIterable {
    case sftp
    case s3

    var displayName: String {
        switch self {
        case .sftp:
            return "SFTP"
        case .s3:
            return "S3"
        }
    }

    var iconName: String {
        switch self {
        case .sftp:
            return "server.rack"
        case .s3:
            return "externaldrive.connected.to.line.below"
        }
    }

    var description: String {
        switch self {
        case .sftp:
            return String(localized: "Secure File Transfer Protocol")
        case .s3:
            return String(localized: "Amazon S3 / S3-Compatible Storage")
        }
    }
}
