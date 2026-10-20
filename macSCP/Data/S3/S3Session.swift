//
//  S3Session.swift
//  macSCP
//
//  Actor-based S3 session using Soto SDK
//

import Foundation
import NIOCore
import NIOFoundationCompat
import SotoS3

actor S3Session: S3SessionProtocol {
    private var client: AWSClient?
    private var s3: S3?
    private(set) var isConnected = false
    private(set) var currentPath = "/"
    private(set) var bucketName = ""

    init() {}

    // MARK: - Logging Helper
    private nonisolated func log(_ message: String, category: LogCategory = .s3) {
        Task { @MainActor in
            logInfo(message, category: category)
        }
    }

    // MARK: - Connection

    func connect(
        accessKeyId: String,
        secretAccessKey: String,
        region: String,
        bucket: String,
        endpoint: String?
    ) async throws {
        log("Connecting to S3 bucket: \(bucket) in region: \(region)")

        do {
            let awsRegion = Region(rawValue: region)

            client = AWSClient(
                credentialProvider: .static(
                    accessKeyId: accessKeyId, secretAccessKey: secretAccessKey)
            )

            if let endpoint = endpoint, !endpoint.isEmpty {
                // Custom endpoint for S3-compatible services (MinIO, DigitalOcean Spaces, etc.)
                s3 = S3(client: client!, region: awsRegion, endpoint: endpoint)
            } else {
                s3 = S3(client: client!, region: awsRegion)
            }

            // Verify connection by checking if bucket exists
            let headBucketRequest = S3.HeadBucketRequest(bucket: bucket)
            _ = try await s3!.headBucket(headBucketRequest)

            bucketName = bucket
            currentPath = "/"
            isConnected = true

            log("Connected successfully to S3 bucket: \(bucket)")
        } catch let error as S3ErrorType {
            try await cleanup()
            throw parseS3Error(error)
        } catch {
            try await cleanup()
            throw parseConnectionError(error)
        }
    }

    func disconnect() async {
        log("Disconnecting from S3")
        try? await cleanup()
        isConnected = false
        currentPath = "/"
        bucketName = ""
    }

    private func cleanup() async throws {
        try? await client?.shutdown()
        client = nil
        s3 = nil
    }

    // MARK: - File Operations

    func listFiles(at path: String) async throws -> [RemoteFile] {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        let prefix = Self.normalizePrefix(path)
        currentPath = "/" + prefix

        let request = S3.ListObjectsV2Request(
            bucket: bucketName,
            delimiter: "/",
            prefix: prefix.isEmpty ? nil : prefix
        )

        let response = try await s3.listObjectsV2(request)

        var files: [RemoteFile] = []

        // Add directories (common prefixes)
        if let commonPrefixes = response.commonPrefixes {
            for prefixObj in commonPrefixes {
                if let prefixKey = prefixObj.prefix {
                    let name = extractName(from: prefixKey, basePrefix: prefix)
                    if !name.isEmpty && name != "/" {
                        let file = RemoteFile(
                            name: name,
                            path: "/" + prefixKey,
                            isDirectory: true,
                            size: 0,
                            permissions: "drwxr-xr-x",
                            modificationDate: nil
                        )
                        files.append(file)
                    }
                }
            }
        }

        // Add files (contents)
        if let contents = response.contents {
            for object in contents {
                if let key = object.key {
                    // Skip the prefix itself if it's a directory marker
                    if key == prefix || key.hasSuffix("/") {
                        continue
                    }

                    let name = extractName(from: key, basePrefix: prefix)
                    if !name.isEmpty {
                        let file = RemoteFile(
                            name: name,
                            path: "/" + key,
                            isDirectory: false,
                            size: object.size ?? 0,
                            permissions: "-rw-r--r--",
                            modificationDate: object.lastModified
                        )
                        files.append(file)
                    }
                }
            }
        }

        return RemoteFile.sortedFiles(files, by: .name)
    }

    func getFileInfo(at path: String) async throws -> RemoteFile {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        let key = normalizeKey(path)

        let request = S3.HeadObjectRequest(bucket: bucketName, key: key)

        do {
            let response = try await s3.headObject(request)

            let fileName = (path as NSString).lastPathComponent
            let isDirectory = key.hasSuffix("/")

            return RemoteFile(
                name: fileName,
                path: path,
                isDirectory: isDirectory,
                size: response.contentLength ?? 0,
                permissions: isDirectory ? "drwxr-xr-x" : "-rw-r--r--",
                modificationDate: response.lastModified
            )
        } catch {
            let mapped = parseS3Error(error)
            guard case .s3ObjectNotFound = mapped else { throw mapped }
            // An S3 directory can exist only as a marker or as an implicit prefix.
            // Probe without changing currentPath, and never mistake access errors for absence.
            try Task.checkCancellation()
            let prefix = Self.directoryProbePrefix(path)
            do {
                let listing = try await s3.listObjectsV2(
                    S3.ListObjectsV2Request(bucket: bucketName, maxKeys: 1, prefix: prefix)
                )
                guard !(listing.contents ?? []).isEmpty else { throw AppError.s3ObjectNotFound }
                return RemoteFile(
                    name: (path as NSString).lastPathComponent, path: path,
                    isDirectory: true, size: 0, permissions: "drwxr-xr-x"
                )
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                throw parseS3Error(error)
            }
        }
    }

    func createDirectory(at path: String) async throws {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        // In S3, directories are simulated with a zero-byte object ending with /
        var key = normalizeKey(path)
        if !key.hasSuffix("/") {
            key += "/"
        }

        let request = S3.PutObjectRequest(
            body: .init(),
            bucket: bucketName,
            key: key
        )

        do {
            _ = try await s3.putObject(request)
            log("Created directory: \(path)")
        } catch {
            throw parseS3Error(error)
        }
    }

    func createFile(at path: String) async throws {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        let key = normalizeKey(path)

        let request = S3.PutObjectRequest(
            body: .init(),
            bucket: bucketName,
            key: key
        )

        do {
            _ = try await s3.putObject(request)
            log("Created file: \(path)")
        } catch {
            throw parseS3Error(error)
        }
    }

    func deleteFile(at path: String) async throws {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        let key = normalizeKey(path)

        let request = S3.DeleteObjectRequest(bucket: bucketName, key: key)

        do {
            _ = try await s3.deleteObject(request)
            log("Deleted file: \(path)")
        } catch {
            throw parseS3Error(error)
        }
    }

    func deleteDirectory(at path: String) async throws {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        var prefix = normalizeKey(path)
        if !prefix.hasSuffix("/") {
            prefix += "/"
        }

        // List all objects with this prefix and delete them
        let listRequest = S3.ListObjectsV2Request(bucket: bucketName, prefix: prefix)
        let response = try await s3.listObjectsV2(listRequest)

        if let contents = response.contents, !contents.isEmpty {
            let objectsToDelete = contents.compactMap { object -> S3.ObjectIdentifier? in
                guard let key = object.key else { return nil }
                return S3.ObjectIdentifier(key: key)
            }

            if !objectsToDelete.isEmpty {
                let deleteRequest = S3.DeleteObjectsRequest(
                    bucket: bucketName,
                    delete: S3.Delete(objects: objectsToDelete)
                )
                _ = try await s3.deleteObjects(deleteRequest)
            }
        }

        // Also try to delete the directory marker itself
        let dirMarkerRequest = S3.DeleteObjectRequest(bucket: bucketName, key: prefix)
        _ = try? await s3.deleteObject(dirMarkerRequest)

        log("Deleted directory: \(path)")
    }

    func rename(from sourcePath: String, to destinationPath: String) async throws {
        // S3 doesn't support rename, so we copy then delete
        let sourceKey = normalizeKey(sourcePath)

        // Check if this is a directory (ends with "/" or has objects with this prefix)
        if sourceKey.hasSuffix("/") {
            try await copyDirectory(from: sourcePath, to: destinationPath)
            try await deleteDirectory(at: sourcePath)
        } else {
            // Check if it's a folder without trailing slash by listing objects
            guard let s3 = s3 else {
                throw AppError.notConnected
            }

            let listRequest = S3.ListObjectsV2Request(
                bucket: bucketName,
                maxKeys: 1,
                prefix: sourceKey + "/"
            )
            let response = try await s3.listObjectsV2(listRequest)

            if let contents = response.contents, !contents.isEmpty {
                // It's a directory - has objects under it
                try await copyDirectory(from: sourcePath + "/", to: destinationPath + "/")
                try await deleteDirectory(at: sourcePath + "/")
            } else {
                // It's a file
                try await copyFile(from: sourcePath, to: destinationPath)
                try await deleteFile(at: sourcePath)
            }
        }
        log("Renamed \(sourcePath) to \(destinationPath)")
    }

    func copyFile(from sourcePath: String, to destinationPath: String) async throws {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        let sourceKey = normalizeKey(sourcePath)
        let destKey = normalizeKey(destinationPath)

        let request = S3.CopyObjectRequest(
            bucket: bucketName,
            copySource: "\(bucketName)/\(sourceKey)",
            key: destKey
        )

        do {
            _ = try await s3.copyObject(request)
            log("Copied file: \(sourcePath) to \(destinationPath)")
        } catch {
            throw parseS3Error(error)
        }
    }

    func copyDirectory(from sourcePath: String, to destinationPath: String) async throws {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        var sourcePrefix = normalizeKey(sourcePath)
        if !sourcePrefix.hasSuffix("/") {
            sourcePrefix += "/"
        }

        var destPrefix = normalizeKey(destinationPath)
        if !destPrefix.hasSuffix("/") {
            destPrefix += "/"
        }

        // List all objects with source prefix
        let listRequest = S3.ListObjectsV2Request(bucket: bucketName, prefix: sourcePrefix)
        let response = try await s3.listObjectsV2(listRequest)

        if let contents = response.contents {
            for object in contents {
                if let key = object.key {
                    let relativePath = String(key.dropFirst(sourcePrefix.count))
                    let newKey = destPrefix + relativePath

                    let copyRequest = S3.CopyObjectRequest(
                        bucket: bucketName,
                        copySource: "\(bucketName)/\(key)",
                        key: newKey
                    )
                    _ = try await s3.copyObject(copyRequest)
                }
            }
        }

        log("Copied directory: \(sourcePath) to \(destinationPath)")
    }

    func move(from sourcePath: String, to destinationPath: String) async throws {
        let sourceKey = normalizeKey(sourcePath)

        if sourceKey.hasSuffix("/") {
            // Moving a directory
            try await copyDirectory(from: sourcePath, to: destinationPath)
            try await deleteDirectory(at: sourcePath)
        } else {
            // Moving a file
            try await copyFile(from: sourcePath, to: destinationPath)
            try await deleteFile(at: sourcePath)
        }

        log("Moved: \(sourcePath) to \(destinationPath)")
    }

    func downloadFile(from remotePath: String, to localURL: URL) async throws {
        try await downloadFile(from: remotePath, to: localURL, progress: nil)
    }

    func downloadFile(from remotePath: String, to localURL: URL, progress: TransferProgressHandler?)
        async throws
    {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        let key = normalizeKey(remotePath)

        let request = S3.GetObjectRequest(bucket: bucketName, key: key)

        do {
            let response = try await s3.getObject(request)

            // Report initial progress
            progress?(0)

            // Create/truncate local file
            FileManager.default.createFile(atPath: localURL.path, contents: nil)
            let fileHandle = try FileHandle(forWritingTo: localURL)
            defer { try? fileHandle.close() }

            // Stream the response body to disk in chunks
            var bytesWritten: Int64 = 0
            for try await chunk in response.body {
                try Task.checkCancellation()

                let data = Data(buffer: chunk)
                try fileHandle.write(contentsOf: data)
                bytesWritten += Int64(data.count)

                // Report progress
                progress?(bytesWritten)
            }

            log("Downloaded: \(remotePath) to \(localURL.path)")
        } catch {
            throw parseS3Error(error)
        }
    }

    func uploadFile(from localURL: URL, to remotePath: String) async throws {
        try await uploadFile(from: localURL, to: remotePath, progress: nil)
    }

    func uploadFile(from localURL: URL, to remotePath: String, progress: TransferProgressHandler?)
        async throws
    {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        try Task.checkCancellation()
        let key = normalizeKey(remotePath)
        let fileSize =
            try FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64 ?? 0

        // Use multipart upload for files > 5MB (S3 minimum part size)
        let multipartThreshold: Int64 = 5 * 1024 * 1024

        // Report initial progress
        progress?(0)

        do {
            if fileSize <= multipartThreshold {
                // Small file: use simple upload (still streamed from disk)
                let fileHandle = try FileHandle(forReadingFrom: localURL)
                defer { try? fileHandle.close() }
                let data = fileHandle.readDataToEndOfFile()
                let byteBuffer = ByteBuffer(data: data)

                let request = S3.PutObjectRequest(
                    body: .init(buffer: byteBuffer),
                    bucket: bucketName,
                    key: key
                )
                try Task.checkCancellation()
                _ = try await s3.putObject(request)
                try Task.checkCancellation()

                // Report completion for small files
                progress?(fileSize)
            } else {
                // Large file: use multipart upload to avoid memory issues
                try await uploadMultipart(
                    from: localURL, key: key, fileSize: fileSize, progress: progress)
            }
            try Task.checkCancellation()
            log("Uploaded: \(localURL.path) to \(remotePath)")
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw parseS3Error(error)
        }
    }

    /// Uploads a large file using S3 multipart upload
    private func uploadMultipart(
        from localURL: URL, key: String, fileSize: Int64, progress: TransferProgressHandler? = nil
    ) async throws {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        // Use 10MB part size for multipart uploads (larger than minimum 5MB for better performance)
        let partSize = 10 * 1024 * 1024
        let fileHandle = try FileHandle(forReadingFrom: localURL)
        defer { try? fileHandle.close() }

        try Task.checkCancellation()
        // 1. Initiate multipart upload
        let createRequest = S3.CreateMultipartUploadRequest(bucket: bucketName, key: key)
        let createResponse = try await s3.createMultipartUpload(createRequest)

        guard let uploadId = createResponse.uploadId else {
            throw AppError.s3OperationFailed("Failed to initiate multipart upload")
        }

        var completedParts: [S3.CompletedPart] = []
        var partNumber = 1
        var offset: UInt64 = 0

        do {
            // 2. Upload parts
            while offset < UInt64(fileSize) {
                try Task.checkCancellation()
                try fileHandle.seek(toOffset: offset)
                guard let partData = try fileHandle.read(upToCount: partSize), !partData.isEmpty
                else {
                    throw AppError.uploadFailed("Source was truncated during multipart upload")
                }

                let uploadPartRequest = S3.UploadPartRequest(
                    body: .init(buffer: ByteBuffer(data: partData)),
                    bucket: bucketName,
                    key: key,
                    partNumber: partNumber,
                    uploadId: uploadId
                )

                try Task.checkCancellation()
                let partResponse = try await s3.uploadPart(uploadPartRequest)
                try Task.checkCancellation()

                completedParts.append(
                    S3.CompletedPart(eTag: partResponse.eTag, partNumber: partNumber))
                partNumber += 1
                offset += UInt64(partData.count)

                // Report progress after each part
                progress?(Int64(offset))
            }

            try Task.checkCancellation()
            // 3. Complete multipart upload
            let completeRequest = S3.CompleteMultipartUploadRequest(
                bucket: bucketName,
                key: key,
                multipartUpload: S3.CompletedMultipartUpload(parts: completedParts),
                uploadId: uploadId
            )
            try Task.checkCancellation()
            _ = try await s3.completeMultipartUpload(completeRequest)

        } catch {
            // Abort multipart upload on failure to clean up partial uploads
            let abortRequest = S3.AbortMultipartUploadRequest(
                bucket: bucketName,
                key: key,
                uploadId: uploadId
            )
            // Cleanup must not inherit cancellation from the upload task.
            await Task.detached {
                _ = try? await s3.abortMultipartUpload(abortRequest)
            }.value
            throw error
        }
    }

    func readFileContent(at path: String) async throws -> String {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        let key = normalizeKey(path)

        let request = S3.GetObjectRequest(bucket: bucketName, key: key)

        do {
            let response = try await s3.getObject(request)

            let body = response.body
            let data = try await body.collect(upTo: .max)
            let content = String(buffer: data)
            return content
        } catch {
            throw parseS3Error(error)
        }
    }

    func writeFileContent(_ content: String, to path: String) async throws {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        let key = normalizeKey(path)
        let byteBuffer = ByteBuffer(string: content)

        let request = S3.PutObjectRequest(
            body: .init(buffer: byteBuffer),
            bucket: bucketName,
            key: key
        )

        do {
            _ = try await s3.putObject(request)
            log("Wrote content to: \(path)")
        } catch {
            throw parseS3Error(error)
        }
    }

    func getRealPath(at path: String) async throws -> String {
        // S3 doesn't have symlinks, just normalize the path
        if path == "~" || path == "." {
            return currentPath
        }
        if path == ".." {
            // Compute parent path manually since we're in an actor
            let components = currentPath.split(separator: "/")
            if components.count > 1 {
                return "/" + components.dropLast().joined(separator: "/")
            }
            return "/"
        }
        if path.hasPrefix("/") {
            return path
        }
        // Append path component manually
        if currentPath.hasSuffix("/") {
            return currentPath + path
        }
        return currentPath + "/" + path
    }

    // MARK: - Private Helpers

    /// Normalizes a path to an S3 key (removes leading /)
    private func normalizeKey(_ path: String) -> String {
        var key = path
        while key.hasPrefix("/") {
            key = String(key.dropFirst())
        }
        return key
    }

    /// Normalizes a path to a prefix for listing (removes leading /).
    /// Callers that probe a directory must append a trailing / themselves.
    private nonisolated static func normalizePrefix(_ path: String) -> String {
        var prefix = path
        while prefix.hasPrefix("/") {
            prefix = String(prefix.dropFirst())
        }
        if prefix == "/" || prefix.isEmpty {
            return ""
        }
        return prefix
    }

    /// A directory exists only through its descendants or marker object, so the
    /// probe prefix needs a trailing slash. Without it `report` would also match
    /// sibling keys such as `report.pdf`.
    nonisolated static func directoryProbePrefix(_ path: String) -> String {
        var prefix = normalizePrefix(path)
        guard !prefix.isEmpty else { return "" }
        if !prefix.hasSuffix("/") { prefix += "/" }
        return prefix
    }

    /// Extracts the name from a key given a base prefix
    private func extractName(from key: String, basePrefix: String) -> String {
        var name = String(key.dropFirst(basePrefix.count))
        // Remove trailing slash for directories
        if name.hasSuffix("/") {
            name = String(name.dropLast())
        }
        // Remove any remaining slashes (shouldn't happen with delimiter)
        if let slashIndex = name.firstIndex(of: "/") {
            name = String(name[..<slashIndex])
        }
        return name
    }

    private func parseConnectionError(_ error: Error) -> AppError {
        let description = error.localizedDescription.lowercased()

        if description.contains("invalid access key") || description.contains("signature") {
            return .invalidS3Credentials
        } else if description.contains("bucket") && description.contains("not found") {
            return .s3BucketNotFound
        } else if description.contains("access denied") || description.contains("forbidden") {
            return .s3AccessDenied
        } else if description.contains("timeout") {
            return .connectionTimeout
        }

        return .connectionFailed(error.localizedDescription)
    }

    private func parseS3Error(_ error: Error) -> AppError {
        if let appError = error as? AppError { return appError }
        if let awsError = error as? AWSErrorType {
            switch awsError.errorCode {
            case "NoSuchKey", "NotFound": return .s3ObjectNotFound
            case "NoSuchBucket": return .s3BucketNotFound
            case "AccessDenied", "Forbidden": return .s3AccessDenied
            default: return .s3OperationFailed(error.localizedDescription)
            }
        }
        let description = String(describing: error).lowercased()

        if description.contains("nosuchbucket")
            || (description.contains("bucket") && description.contains("not found"))
        {
            return .s3BucketNotFound
        } else if description.contains("nosuchkey") || description.contains("no such key")
            || description.contains("not found")
        {
            return .s3ObjectNotFound
        } else if description.contains("accessdenied") || description.contains("access denied")
            || description.contains("forbidden")
        {
            return .s3AccessDenied
        } else if description.contains("invalidsignature") || description.contains("credential") {
            return .invalidS3Credentials
        }

        return .s3OperationFailed(error.localizedDescription)
    }
}
