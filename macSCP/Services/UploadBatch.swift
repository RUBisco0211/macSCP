import Foundation

/// A fully validated local snapshot of paths and sizes, before any remote writes.
struct UploadBatch: Sendable {
    struct Entry: Sendable {
        let localURL: URL
        let remotePath: String
        let isDirectory: Bool
        let size: Int64
    }

    struct Source: Sendable {
        let url: URL
        let remotePath: String
        let entries: [Entry]
        let totalBytes: Int64
    }

    let sources: [Source]

    static func prepare(_ urls: [URL], destinationPath: String) async throws -> UploadBatch {
        guard destinationPath.hasPrefix("/"), !destinationPath.contains("\0") else {
            throw AppError.invalidPath
        }
        var names = Set<String>()
        var sources: [Source] = []
        for url in urls {
            try Task.checkCancellation()
            let name = url.lastPathComponent
            guard url.isFileURL, !name.isEmpty, name != "/", name != ".", name != ".." else {
                throw AppError.invalidPath
            }
            guard names.insert(name).inserted else {
                throw AppError.uploadFailed("Duplicate top-level source name: \(name)")
            }
            let path = destinationPath.appendingPathComponent(name)
            var entries: [Entry] = []
            try await collect(url, remotePath: path, entries: &entries)
            var total: Int64 = 0
            for entry in entries {
                let (sum, overflow) = total.addingReportingOverflow(entry.size)
                guard !overflow else { throw AppError.uploadFailed("Upload size is too large") }
                total = sum
            }
            sources.append(Source(url: url, remotePath: path, entries: entries, totalBytes: total))
        }
        return UploadBatch(sources: sources)
    }

    private static func collect(_ url: URL, remotePath: String, entries: inout [Entry]) async throws
    {
        // Yield during preparation so cancellation/disconnect can interrupt large trees.
        await Task.yield()
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let type = attributes[.type] as? FileAttributeType
        guard type == .typeDirectory || type == .typeRegular else {
            throw AppError.uploadFailed(
                "Symbolic links and unsupported file types cannot be uploaded: \(url.path)")
        }
        let isDirectory = type == .typeDirectory
        let size = isDirectory ? 0 : (attributes[.size] as? NSNumber)?.int64Value ?? 0
        entries.append(
            Entry(localURL: url, remotePath: remotePath, isDirectory: isDirectory, size: size))
        if isDirectory {
            let children = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                try await collect(
                    child, remotePath: remotePath.appendingPathComponent(child.lastPathComponent),
                    entries: &entries)
            }
        }
    }

    /// Returns false for an accepted skip. No existing object is changed without a decision.
    /// Directory entries are preorder, so the caller can skip all descendants of a skipped root.
    @MainActor
    static func prepareDestination(
        for entry: Entry, repository: FileRepositoryProtocol,
        resolve: (UploadConflict) async throws -> UploadConflictDecision
    ) async throws -> Bool {
        while true {
            try Task.checkCancellation()
            let destination: RemoteFile?
            do {
                destination = try await repository.getFileInfo(at: directoryPath(entry.remotePath))
            } catch AppError.fileNotFound {
                destination = nil
            } catch AppError.s3ObjectNotFound {
                destination = nil
            }
            try Task.checkCancellation()
            if let destination {
                let conflict = UploadConflict(
                    localURL: entry.localURL, remotePath: entry.remotePath,
                    sourceIsDirectory: entry.isDirectory,
                    destinationIsDirectory: destination.isDirectory)
                let decision = try await resolve(conflict)
                try Task.checkCancellation()
                switch decision {
                case .skip:
                    return false
                case .cancel:
                    throw CancellationError()
                case .merge:
                    // Invalid/stale UI input must never authorize replacing a different type.
                    guard entry.isDirectory, destination.isDirectory else { continue }
                    return true
                case .overwrite:
                    if entry.isDirectory || destination.isDirectory {
                        // Directory overwrite means replacement of the entire tree, not merge.
                        try await repository.delete(
                            at: entry.remotePath, isDirectory: destination.isDirectory)
                        try Task.checkCancellation()
                    } else {
                        // Preserve the backend's regular-file overwrite implementation.
                        return true
                    }
                }
            }
            if !entry.isDirectory { return true }
            do {
                try Task.checkCancellation()
                try await repository.createDirectory(at: entry.remotePath)
                return true
            } catch AppError.fileAlreadyExists {
                // A concurrent creator is a new conflict, never implicit merge/overwrite.
                continue
            }
        }
    }

    /// Query metadata, not a directory listing (which changes session.currentPath).
    /// Query the unsuffixed path first: a trailing slash can hide a file conflict as ENOTDIR.
    static func ensureDirectory(at path: String, repository: FileRepositoryProtocol) async throws {
        try Task.checkCancellation()
        do {
            let info = try await repository.getFileInfo(at: directoryPath(path))
            guard info.isDirectory else { throw AppError.fileAlreadyExists }
            return
        } catch AppError.fileNotFound {
            // Only a confirmed missing path permits mkdir. Permission/transport errors propagate.
        } catch AppError.s3ObjectNotFound {
            // Implicit S3 prefixes can safely acquire a directory marker without touching children.
        }
        try Task.checkCancellation()
        try await repository.createDirectory(at: path)
    }

    /// Regular files may overwrite regular files, but never a directory/prefix.
    static func ensureFileDestination(at path: String, repository: FileRepositoryProtocol)
        async throws
    {
        try Task.checkCancellation()
        do {
            let info = try await repository.getFileInfo(at: path)
            guard !info.isDirectory else { throw AppError.fileAlreadyExists }
        } catch AppError.fileNotFound {
        } catch AppError.s3ObjectNotFound {
        }
    }

    private static func directoryPath(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }
}
