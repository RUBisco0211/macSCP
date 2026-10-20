//
//  FileTypeService.swift
//  macSCP
//
//  Service for file type detection and categorization
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum FileTypeService {
    /// Returns the SF Symbol name for a file
    static func iconName(for file: RemoteFile) -> String {
        if file.isDirectory {
            return "folder.fill"
        }

        return file.fileType.iconName
    }

    /// Returns the icon color for a file type
    static func iconColor(for file: RemoteFile) -> Color {
        if file.isDirectory {
            return .blue
        }

        switch file.fileType {
        case .code, .configuration:
            return .orange
        case .image:
            return .purple
        case .video:
            return .pink
        case .audio:
            return .green
        case .archive:
            return .brown
        case .document, .text:
            return .blue
        case .spreadsheet:
            return .green
        case .presentation:
            return .orange
        case .pdf:
            return .red
        case .executable:
            return .gray
        default:
            return .secondary
        }
    }

    /// Returns whether a file can be previewed/edited in the app
    static func isPreviewable(_ file: RemoteFile) -> Bool {
        guard file.isFile else { return false }
        guard file.size <= FileOperationConstants.maxFilePreviewSize else { return false }

        return file.fileType.isEditable
    }

    /// Returns the UTType for a file extension
    static func utType(for extension: String) -> UTType? {
        UTType(filenameExtension: `extension`)
    }

    /// Returns the MIME type for a file
    static func mimeType(for file: RemoteFile) -> String {
        guard let utType = utType(for: file.fileExtension) else {
            return "application/octet-stream"
        }
        return utType.preferredMIMEType ?? "application/octet-stream"
    }

    /// Returns a human-readable description of the file type (Finder style)
    static func typeDescription(for file: RemoteFile) -> String {
        if file.isDirectory {
            return String(localized: "Folder")
        }

        if file.isSymlink {
            return String(localized: "Alias")
        }

        // Check for specific extensions first
        switch file.fileExtension.lowercased() {
        case "swift":
            return String(localized: "Swift Source")
        case "js":
            return String(localized: "JavaScript")
        case "ts":
            return String(localized: "TypeScript")
        case "py":
            return String(localized: "Python Script")
        case "rb":
            return String(localized: "Ruby Script")
        case "go":
            return String(localized: "Go Source")
        case "rs":
            return String(localized: "Rust Source")
        case "java":
            return String(localized: "Java Source")
        case "c":
            return String(localized: "C Source")
        case "cpp", "cc":
            return String(localized: "C++ Source")
        case "h":
            return String(localized: "C Header")
        case "hpp":
            return String(localized: "C++ Header")
        case "m":
            return String(localized: "Objective-C Source")
        case "html", "htm":
            return String(localized: "HTML Document")
        case "css":
            return String(localized: "CSS Stylesheet")
        case "json":
            return String(localized: "JSON")
        case "xml":
            return String(localized: "XML Document")
        case "yaml", "yml":
            return String(localized: "YAML Document")
        case "md", "markdown":
            return String(localized: "Markdown Document")
        case "txt":
            return String(localized: "Plain Text")
        case "pdf":
            return String(localized: "PDF Document")
        case "png":
            return String(localized: "PNG Image")
        case "jpg", "jpeg":
            return String(localized: "JPEG Image")
        case "gif":
            return String(localized: "GIF Image")
        case "svg":
            return String(localized: "SVG Image")
        case "mp4":
            return String(localized: "MPEG-4 Movie")
        case "mov":
            return String(localized: "QuickTime Movie")
        case "mp3":
            return String(localized: "MP3 Audio")
        case "wav":
            return String(localized: "WAV Audio")
        case "zip":
            return String(localized: "ZIP Archive")
        case "tar":
            return String(localized: "TAR Archive")
        case "gz", "gzip":
            return String(localized: "Gzip Archive")
        case "dmg":
            return String(localized: "Disk Image")
        case "app":
            return String(localized: "Application")
        case "xcodeproj":
            return String(localized: "Xcode Project")
        case "xcworkspace":
            return String(localized: "Xcode Workspace")
        default:
            break
        }

        // Fallback to general type
        switch file.fileType {
        case .directory:
            return String(localized: "Folder")
        case .text:
            return String(localized: "Plain Text")
        case .code:
            return String(localized: "Source Code")
        case .image:
            return String(localized: "Image")
        case .video:
            return String(localized: "Movie")
        case .audio:
            return String(localized: "Audio")
        case .archive:
            return String(localized: "Archive")
        case .document:
            return String(localized: "Document")
        case .spreadsheet:
            return String(localized: "Spreadsheet")
        case .presentation:
            return String(localized: "Presentation")
        case .pdf:
            return String(localized: "PDF Document")
        case .executable:
            return String(localized: "Unix Executable")
        case .configuration:
            return String(localized: "Configuration")
        case .unknown:
            if file.fileExtension.isEmpty {
                return String(localized: "Document")
            }
            return String(localized: "Document")
        }
    }

    /// Groups files by their type
    static func groupByType(_ files: [RemoteFile]) -> [FileType: [RemoteFile]] {
        Dictionary(grouping: files, by: { $0.fileType })
    }

    /// Returns files filtered by type
    static func filter(_ files: [RemoteFile], byType type: FileType) -> [RemoteFile] {
        files.filter { $0.fileType == type }
    }
}

// MARK: - File Size Formatting
extension FileTypeService {
    /// Formats a byte count as a human-readable string
    static func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Formats permissions as a human-readable string
    static func formatPermissions(_ permissions: String) -> String {
        guard permissions.count == 10 else { return permissions }

        let type: String
        switch permissions.first {
        case "d": type = String(localized: "Directory")
        case "l": type = String(localized: "Symbolic Link")
        case "-": type = String(localized: "File")
        case "b": type = String(localized: "Block Device")
        case "c": type = String(localized: "Character Device")
        case "p": type = String(localized: "Named Pipe")
        case "s": type = String(localized: "Socket")
        default: type = String(localized: "Unknown")
        }

        let permString = String(permissions.dropFirst())
        let owner = formatPermissionGroup(String(permString.prefix(3)))
        let group = formatPermissionGroup(String(permString.dropFirst(3).prefix(3)))
        let other = formatPermissionGroup(String(permString.suffix(3)))

        return String(localized: "\(type) - Owner: \(owner), Group: \(group), Others: \(other)")
    }

    private static func formatPermissionGroup(_ perms: String) -> String {
        var result: [String] = []
        if perms.contains("r") { result.append(String(localized: "Read")) }
        if perms.contains("w") { result.append(String(localized: "Write")) }
        if perms.contains("x") { result.append(String(localized: "Execute")) }
        return result.isEmpty
            ? String(localized: "None")
            : ListFormatter.localizedString(byJoining: result)
    }
}
