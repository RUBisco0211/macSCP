import Darwin
import XCTest

@testable import macSCP

@MainActor
final class UploadBatchTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ name: String, in directory: URL, bytes: Int = 3) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 42, count: bytes).write(to: url)
        return url
    }

    private func viewModel(
        _ repository: UploadRecordingRepository, session: SFTPSessionProtocol? = nil
    ) -> FileBrowserViewModel {
        FileBrowserViewModel(
            connection: Connection(name: "Upload test", host: "example.invalid", username: "test"),
            sftpSession: session ?? MockSFTPSession(), fileRepository: repository,
            clipboardService: .shared, password: ""
        )
    }

    private func waitForConflict(
        _ sut: FileBrowserViewModel, excluding id: UUID? = nil
    ) async throws -> UploadConflict {
        for _ in 0..<2_000 {
            if let conflict = sut.pendingUploadConflict, conflict.id != id { return conflict }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Upload never presented the expected conflict")
        throw CancellationError()
    }

    func testFileConflictWaitsWithoutResolverThenSkipIsSuccessful() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("file", in: root)
        let repository = UploadRecordingRepository()
        repository.existingFiles.insert("/fixed/file")
        let sut = viewModel(repository)
        let batch = Task { await sut.uploadSources([file], to: "/fixed") }
        defer { batch.cancel() }
        let conflict = try await waitForConflict(sut)
        XCTAssertEqual(conflict.localURL, file)
        XCTAssertEqual(conflict.remotePath, "/fixed/file")
        XCTAssertFalse(conflict.sourceIsDirectory)
        XCTAssertFalse(conflict.destinationIsDirectory)
        XCTAssertTrue(repository.uploads.isEmpty)
        XCTAssertTrue(repository.deletions.isEmpty)
        XCTAssertTrue(sut.isUploadingBatch)
        // Merge is not a valid decision for a file; it cannot authorize a write.
        sut.resolveUploadConflict(.merge, for: conflict.id)
        XCTAssertEqual(sut.pendingUploadConflict?.id, conflict.id)
        sut.resolveUploadConflict(.skip, for: conflict.id)
        let succeeded = await batch.value
        XCTAssertTrue(succeeded)
        XCTAssertNil(sut.pendingUploadConflict)
        XCTAssertNil(sut.error)
        XCTAssertEqual(sut.recentTransfers.first?.status, .completed)
        XCTAssertEqual(sut.recentTransfers.first?.bytesTransferred, 3)
        XCTAssertEqual(sut.recentTransfers.first?.error, "Skipped 1 item(s)")
        XCTAssertTrue(repository.uploads.isEmpty)
        XCTAssertTrue(repository.deletions.isEmpty)
    }

    func testFileOverwriteUsesBackendWithoutDeletingRegularFile() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("file", in: root)
        let repository = UploadRecordingRepository()
        repository.existingFiles.insert("/fixed/file")
        let sut = viewModel(repository)
        let batch = Task { await sut.uploadSources([file], to: "/fixed") }
        defer { batch.cancel() }
        let conflict = try await waitForConflict(sut)
        XCTAssertTrue(repository.uploads.isEmpty)
        sut.resolveUploadConflict(.overwrite, for: conflict.id)
        let succeeded = await batch.value
        XCTAssertTrue(succeeded)
        XCTAssertEqual(repository.uploads, ["/fixed/file"])
        XCTAssertTrue(repository.deletions.isEmpty)
    }

    func testDirectorySkipDoesNotQueryOrUploadAnyDescendants() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("child", in: root)
        let path = "/fixed/" + root.lastPathComponent
        let repository = UploadRecordingRepository()
        repository.existingDirectories.insert(path)
        let sut = viewModel(repository)
        let batch = Task { await sut.uploadSources([root], to: "/fixed") }
        defer { batch.cancel() }
        let conflict = try await waitForConflict(sut)
        sut.resolveUploadConflict(.skip, for: conflict.id)
        let succeeded = await batch.value
        XCTAssertTrue(succeeded)
        XCTAssertEqual(repository.infoPaths, [path])
        XCTAssertTrue(repository.uploads.isEmpty)
        XCTAssertTrue(repository.directories.isEmpty)
        XCTAssertTrue(repository.deletions.isEmpty)
        XCTAssertEqual(sut.recentTransfers.first?.error, "Skipped 2 item(s)")
    }

    func testDirectoryMergeAsksForNestedCollisionsAndIgnoresStaleClicks() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        _ = try write("child", in: nested)
        _ = try write("new", in: root)
        let path = "/fixed/" + root.lastPathComponent
        let repository = UploadRecordingRepository()
        repository.existingDirectories = [path, path + "/nested"]
        repository.existingFiles = [path + "/nested/child", path + "/extra"]
        let sut = viewModel(repository)
        let batch = Task { await sut.uploadSources([root], to: "/fixed") }
        defer { batch.cancel() }
        let parent = try await waitForConflict(sut)
        sut.resolveUploadConflict(.merge, for: parent.id)
        let directory = try await waitForConflict(sut, excluding: parent.id)
        XCTAssertEqual(directory.remotePath, path + "/nested")
        sut.resolveUploadConflict(.overwrite, for: parent.id)
        XCTAssertEqual(sut.pendingUploadConflict?.id, directory.id)
        XCTAssertTrue(repository.deletions.isEmpty)
        sut.resolveUploadConflict(.merge, for: directory.id)
        let child = try await waitForConflict(sut, excluding: directory.id)
        XCTAssertEqual(child.remotePath, path + "/nested/child")
        sut.resolveUploadConflict(.skip, for: child.id)
        let succeeded = await batch.value
        XCTAssertTrue(succeeded)
        XCTAssertEqual(repository.uploads, [path + "/new"])
        XCTAssertTrue(repository.existingFiles.contains(path + "/extra"))
        XCTAssertTrue(repository.deletions.isEmpty)
        XCTAssertTrue(repository.directories.isEmpty)
    }

    func testMergeThenSkipNestedDirectorySkipsOnlyItsWholeSubtree() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        _ = try write("child", in: nested)
        _ = try write("ab", in: root)
        let path = "/fixed/" + root.lastPathComponent
        let repository = UploadRecordingRepository()
        repository.existingDirectories = [path, path + "/a"]
        repository.existingFiles.insert(path + "/a/child")
        let sut = viewModel(repository)
        let batch = Task { await sut.uploadSources([root], to: "/fixed") }
        defer { batch.cancel() }
        let parent = try await waitForConflict(sut)
        sut.resolveUploadConflict(.merge, for: parent.id)
        let child = try await waitForConflict(sut, excluding: parent.id)
        XCTAssertEqual(child.remotePath, path + "/a")
        sut.resolveUploadConflict(.skip, for: child.id)
        let succeeded = await batch.value
        XCTAssertTrue(succeeded)
        XCTAssertFalse(repository.infoPaths.contains(path + "/a/child"))
        XCTAssertEqual(repository.uploads, [path + "/ab"])
        XCTAssertTrue(repository.deletions.isEmpty)
    }

    func testMergeThenExplicitlyOverwriteNestedFile() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("child", in: root)
        let path = "/fixed/" + root.lastPathComponent
        let repository = UploadRecordingRepository()
        repository.existingDirectories.insert(path)
        repository.existingFiles = [path + "/child", path + "/extra"]
        let sut = viewModel(repository)
        let batch = Task { await sut.uploadSources([root], to: "/fixed") }
        defer { batch.cancel() }
        let parent = try await waitForConflict(sut)
        sut.resolveUploadConflict(.merge, for: parent.id)
        let child = try await waitForConflict(sut, excluding: parent.id)
        XCTAssertEqual(child.remotePath, path + "/child")
        XCTAssertTrue(repository.uploads.isEmpty)
        sut.resolveUploadConflict(.overwrite, for: child.id)
        let succeeded = await batch.value
        XCTAssertTrue(succeeded)
        XCTAssertEqual(repository.uploads, [path + "/child"])
        XCTAssertTrue(repository.existingFiles.contains(path + "/extra"))
        XCTAssertTrue(repository.deletions.isEmpty)
    }

    func testDirectoryOverwriteReplacesEntireRemoteTree() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("child", in: root)
        let path = "/fixed/" + root.lastPathComponent
        let repository = UploadRecordingRepository()
        repository.existingDirectories = [path, path + "/extra-directory"]
        repository.existingFiles = [path + "/extra", path + "/child"]
        let sut = viewModel(repository)
        let batch = Task { await sut.uploadSources([root], to: "/fixed") }
        defer { batch.cancel() }
        let conflict = try await waitForConflict(sut)
        XCTAssertTrue(repository.deletions.isEmpty)
        sut.resolveUploadConflict(.overwrite, for: conflict.id)
        let succeeded = await batch.value
        XCTAssertTrue(succeeded)
        XCTAssertEqual(repository.deletions.map(\.path), [path])
        XCTAssertEqual(repository.deletions.map(\.isDirectory), [true])
        XCTAssertEqual(repository.directories, [path])
        XCTAssertEqual(repository.uploads, [path + "/child"])
        XCTAssertFalse(repository.existingFiles.contains(path + "/extra"))
        XCTAssertFalse(repository.existingDirectories.contains(path + "/extra-directory"))
    }

    func testTypeMismatchRequiresOverwriteAndDeletesUsingDestinationType() async throws {
        for sourceIsDirectory in [false, true] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let source: URL
            if sourceIsDirectory {
                source = root.appendingPathComponent("item")
                try FileManager.default.createDirectory(
                    at: source, withIntermediateDirectories: false)
                _ = try write("child", in: source)
            } else {
                source = try write("item", in: root)
            }
            let repository = UploadRecordingRepository()
            if sourceIsDirectory {
                repository.existingFiles.insert("/fixed/item")
            } else {
                repository.existingDirectories.insert("/fixed/item")
            }
            let sut = viewModel(repository)
            let batch = Task { await sut.uploadSources([source], to: "/fixed") }
            defer { batch.cancel() }
            let conflict = try await waitForConflict(sut)
            XCTAssertEqual(conflict.destinationIsDirectory, !sourceIsDirectory)
            sut.resolveUploadConflict(.merge, for: conflict.id)
            XCTAssertEqual(sut.pendingUploadConflict?.id, conflict.id)
            XCTAssertTrue(repository.deletions.isEmpty)
            sut.resolveUploadConflict(.overwrite, for: conflict.id)
            let succeeded = await batch.value
            XCTAssertTrue(succeeded)
            XCTAssertEqual(repository.deletions.map(\.path), ["/fixed/item"])
            XCTAssertEqual(repository.deletions.map(\.isDirectory), [!sourceIsDirectory])
        }
    }

    func testMkdirRaceQueriesAgainAndWaitsForExplicitDecision() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "/fixed/" + root.lastPathComponent
        let repository = UploadRecordingRepository()
        repository.onCreateDirectory = { path in
            repository.existingDirectories.insert(path)
            throw AppError.fileAlreadyExists
        }
        defer { repository.onCreateDirectory = nil }
        let sut = viewModel(repository)
        let batch = Task { await sut.uploadSources([root], to: "/fixed") }
        defer { batch.cancel() }
        let conflict = try await waitForConflict(sut)
        XCTAssertEqual(repository.infoPaths, [path, path])
        XCTAssertTrue(repository.deletions.isEmpty)
        sut.resolveUploadConflict(.skip, for: conflict.id)
        let succeeded = await batch.value
        XCTAssertTrue(succeeded)
        XCTAssertEqual(repository.directories, [path])
    }

    func testFileCreateRaceQueriesAgainBeforeOverwriting() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("file", in: root)
        let repository = UploadRecordingRepository()
        var raced = false
        repository.onUpload = { _, path in
            if !raced {
                raced = true
                repository.existingFiles.insert(path)
                throw AppError.fileAlreadyExists
            }
        }
        defer { repository.onUpload = nil }
        let sut = viewModel(repository)
        let batch = Task { await sut.uploadSources([file], to: "/fixed") }
        defer { batch.cancel() }
        let conflict = try await waitForConflict(sut)
        XCTAssertEqual(repository.infoPaths, ["/fixed/file", "/fixed/file"])
        XCTAssertEqual(repository.uploads.count, 1, "No retry before a decision")
        sut.resolveUploadConflict(.skip, for: conflict.id)
        let succeeded = await batch.value
        XCTAssertTrue(succeeded)
        XCTAssertEqual(repository.uploads.count, 1)
        XCTAssertTrue(repository.deletions.isEmpty)
    }

    func testConflictWaitIsResumedForEveryCancellationRoute() async throws {
        for route in ["decision", "caller", "all", "current", "disconnect"] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let first = try write("a", in: root)
            let second = try write("b", in: root)
            let repository = UploadRecordingRepository()
            repository.existingFiles.insert("/fixed/a")
            let sut = viewModel(repository)
            let batch = Task { await sut.uploadSources([first, second], to: "/fixed") }
            defer { batch.cancel() }
            let conflict = try await waitForConflict(sut)
            switch route {
            case "decision": sut.resolveUploadConflict(.cancel, for: conflict.id)
            case "caller": batch.cancel()
            case "all": sut.cancelAllTransfers()
            case "current": sut.cancelTransfer(try XCTUnwrap(sut.activeTransfers.values.first))
            default: await sut.disconnect()
            }
            let succeeded = await batch.value
            XCTAssertFalse(succeeded, route)
            XCTAssertNil(sut.pendingUploadConflict, route)
            XCTAssertFalse(sut.isUploadingBatch, route)
            XCTAssertTrue(sut.activeTransfers.isEmpty, route)
            XCTAssertNil(sut.error, route)
            XCTAssertFalse(repository.uploads.contains("/fixed/a"), route)
            if route != "current" { XCTAssertTrue(repository.uploads.isEmpty, route) }
            XCTAssertTrue(repository.deletions.isEmpty, route)
            XCTAssertTrue(sut.recentTransfers.contains { $0.status == .cancelled }, route)
        }
    }

    func testS3ObjectNotFoundPermitsNewUploadWithoutConflict() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("child", in: root)
        let path = "/fixed/" + root.lastPathComponent
        let repository = UploadRecordingRepository()
        repository.infoError = AppError.s3ObjectNotFound
        let sut = viewModel(repository)
        let succeeded = await sut.uploadSources([root], to: "/fixed")
        XCTAssertTrue(succeeded)
        XCTAssertNil(sut.pendingUploadConflict)
        XCTAssertEqual(repository.directories, [path])
        XCTAssertEqual(repository.uploads, [path + "/child"])
        XCTAssertTrue(repository.deletions.isEmpty)
    }

    func testMetadataFailureDoesNotBecomeMissingOrAuthorizeWrites() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("file", in: root)
        for source in [root, file] {
            let repository = UploadRecordingRepository()
            repository.infoError = AppError.permissionDenied
            let sut = viewModel(repository)
            let succeeded = await sut.uploadSources([source], to: "/fixed")
            XCTAssertFalse(succeeded)
            XCTAssertNotNil(sut.error)
            XCTAssertNil(sut.pendingUploadConflict)
            XCTAssertTrue(repository.uploads.isEmpty)
            XCTAssertTrue(repository.directories.isEmpty)
            XCTAssertTrue(repository.deletions.isEmpty)
            XCTAssertEqual(sut.recentTransfers.first?.status, .failed)
        }
    }

    func testDisconnectWaitsForLateConnectAndPreventsPublishingConnection() async {
        let repository = UploadRecordingRepository()
        let session = DelayedUploadTestSession()
        let sut = viewModel(repository, session: session)
        let entered = expectation(description: "Connect entered")
        let cancelled = expectation(description: "Connect cancellation requested")
        let gate = UploadTestGate()
        defer { gate.open() }
        session.onConnect = {
            entered.fulfill()
            await gate.wait()
        }
        session.onCancellation = { cancelled.fulfill() }
        let connecting = Task { await sut.connect() }
        await fulfillment(of: [entered], timeout: 2)
        let disconnecting = Task { await sut.disconnect() }
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertFalse(session.base.disconnectCalled, "Teardown must wait for connect to return")
        XCTAssertFalse(sut.isConnected)
        gate.open()
        await disconnecting.value
        await connecting.value
        XCTAssertEqual(session.events, ["connected", "disconnected"])
        XCTAssertFalse(session.base.isConnected)
        XCTAssertFalse(sut.isConnected)
        XCTAssertTrue(repository.listPaths.isEmpty, "A cancelled connect must not start loadFiles")
        XCTAssertEqual(sut.currentPath, "/")
        XCTAssertNil(sut.error)
    }

    func testCallerCancellationCleansUpLateConnectWithoutDisconnectCall() async {
        let repository = UploadRecordingRepository()
        let session = DelayedUploadTestSession()
        let sut = viewModel(repository, session: session)
        let entered = expectation(description: "Connect entered")
        let cancelled = expectation(description: "Connect cancellation requested")
        let gate = UploadTestGate()
        defer { gate.open() }
        session.onConnect = {
            entered.fulfill()
            await gate.wait()
        }
        session.onCancellation = { cancelled.fulfill() }
        let connecting = Task { await sut.connect() }
        await fulfillment(of: [entered], timeout: 2)
        connecting.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertFalse(session.base.disconnectCalled)
        gate.open()
        await connecting.value
        XCTAssertEqual(session.events, ["connected", "disconnected"])
        XCTAssertFalse(session.base.isConnected)
        XCTAssertFalse(sut.isConnected)
        XCTAssertTrue(repository.listPaths.isEmpty)
        XCTAssertNil(sut.error)
    }

    func testFailedSourceReturnsFalseEvenAfterHistoryIsClearedAndLaterSourceSucceeds() async throws
    {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try write("a", in: root)
        let second = try write("b", in: root)
        let repository = UploadRecordingRepository()
        let sut = viewModel(repository)
        repository.onUpload = { _, path in
            if path == "/fixed/a" { throw AppError.permissionDenied }
            sut.clearCompletedTransfers()
        }
        defer { repository.onUpload = nil }
        let succeeded = await sut.uploadSources([first, second], to: "/fixed")
        XCTAssertFalse(succeeded)
        XCTAssertEqual(repository.uploads, ["/fixed/a", "/fixed/b"])
        XCTAssertEqual(sut.recentTransfers.count, 1)
        XCTAssertEqual(sut.recentTransfers.first?.status, .completed)
    }

    func testEmptyBatchReturnsFalse() async {
        let repository = UploadRecordingRepository()
        let sut = viewModel(repository)
        let succeeded = await sut.uploadSources([], to: "/fixed")
        XCTAssertFalse(succeeded)
        XCTAssertFalse(sut.isUploadingBatch)
        XCTAssertTrue(repository.uploads.isEmpty)
    }

    func testPlanPreservesRootHiddenFilesAndEmptyDirectories() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write(".hidden", in: root, bytes: 7)
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        let batch = try await UploadBatch.prepare([root], destinationPath: "/fixed")
        let source = try XCTUnwrap(batch.sources.first)
        let base = "/fixed/" + root.lastPathComponent
        XCTAssertEqual(source.remotePath, base)
        XCTAssertEqual(source.totalBytes, 7)
        XCTAssertEqual(
            source.entries.map(\.remotePath), [base, base + "/.hidden", base + "/empty"])
        XCTAssertEqual(source.entries.map(\.isDirectory), [true, false, true])
    }

    func testDuplicateTopLevelNamesRejectBeforeWriting() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("same", in: root)
        let repository = UploadRecordingRepository()
        let sut = viewModel(repository)
        let succeeded = await sut.uploadSources([file, file], to: "/fixed")
        XCTAssertFalse(succeeded)
        XCTAssertNotNil(sut.error)
        XCTAssertTrue(repository.uploads.isEmpty)
        XCTAssertTrue(repository.directories.isEmpty)
        XCTAssertFalse(sut.isUploadingBatch)
    }

    func testSymlinksAndFIFOAreRejectedIncludingInsideDirectories() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("regular", in: root)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        for source in [link, root] {
            do {
                _ = try await UploadBatch.prepare([source], destinationPath: "/fixed")
                XCTFail("Symbolic link must be rejected")
            } catch { XCTAssertTrue(error is AppError) }
        }
        try FileManager.default.removeItem(at: link)
        let fifo = root.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        do {
            _ = try await UploadBatch.prepare([root], destinationPath: "/fixed")
            XCTFail("FIFO must be rejected without opening it")
        } catch { XCTAssertTrue(error is AppError) }
    }

    func testInvalidURLIsDisplayedAsPreparationError() async {
        let repository = UploadRecordingRepository()
        let sut = viewModel(repository)
        let succeeded = await sut.uploadSources(
            [URL(string: "https://example.invalid/file")!], to: "/fixed")
        XCTAssertFalse(succeeded)
        XCTAssertNotNil(sut.error)
        XCTAssertTrue(repository.uploads.isEmpty)
        XCTAssertFalse(sut.isUploadingBatch)
    }

    func testExistingDirectoryMergesWithoutMkdirAndUsesUnsuffixedPath() async throws {
        let repository = UploadRecordingRepository()
        repository.existingDirectories.insert("/fixed/folder")
        try await UploadBatch.ensureDirectory(at: "/fixed/folder", repository: repository)
        XCTAssertEqual(repository.infoPaths, ["/fixed/folder"])
        XCTAssertTrue(repository.directories.isEmpty)
    }

    func testDirectoryRejectsUnsuffixedFileEvenWhenS3MarkerAlsoExists() async throws {
        let repository = UploadRecordingRepository()
        repository.existingFiles.insert("/fixed/folder")
        repository.existingDirectories.insert("/fixed/folder/")
        do {
            try await UploadBatch.ensureDirectory(at: "/fixed/folder/", repository: repository)
            XCTFail("A regular file conflicts with a directory, even if a marker also exists")
        } catch AppError.fileAlreadyExists {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(repository.infoPaths, ["/fixed/folder"])
        XCTAssertTrue(repository.directories.isEmpty)
    }

    func testFileRejectsDirectoryButCanOverwriteRegularFile() async throws {
        let repository = UploadRecordingRepository()
        repository.existingDirectories.insert("/fixed/folder")
        do {
            try await UploadBatch.ensureFileDestination(at: "/fixed/folder", repository: repository)
            XCTFail("A directory cannot be replaced by an uploaded file")
        } catch AppError.fileAlreadyExists {} catch { XCTFail("Unexpected error: \(error)") }
        repository.existingFiles.insert("/fixed/file")
        try await UploadBatch.ensureFileDestination(at: "/fixed/file", repository: repository)
    }

    func testMkdirAndMetadataPermissionErrorsAreNotSwallowed() async throws {
        let repository = UploadRecordingRepository()
        repository.mkdirError = AppError.permissionDenied
        do {
            try await UploadBatch.ensureDirectory(at: "/fixed/folder", repository: repository)
            XCTFail("mkdir permission error must propagate")
        } catch AppError.permissionDenied {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(repository.directories, ["/fixed/folder"])

        repository.infoError = AppError.permissionDenied
        repository.directories = []
        do {
            try await UploadBatch.ensureDirectory(at: "/fixed/folder", repository: repository)
            XCTFail("metadata permission error must propagate")
        } catch AppError.permissionDenied {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(repository.directories.isEmpty)
    }

    func testMissingS3MarkerCreatesDirectory() async throws {
        let repository = UploadRecordingRepository()
        repository.infoError = AppError.s3ObjectNotFound
        try await UploadBatch.ensureDirectory(at: "/fixed/folder", repository: repository)
        XCTAssertEqual(repository.directories, ["/fixed/folder"])
    }

    func testOneCompletedTransferPerRootWithAggregateBytes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("a", in: root, bytes: 4)
        _ = try write(".b", in: root, bytes: 6)
        let repository = UploadRecordingRepository()
        let sut = viewModel(repository)
        let succeeded = await sut.uploadSources([root], to: "/fixed")
        XCTAssertTrue(succeeded)
        XCTAssertEqual(repository.uploads.count, 2)
        XCTAssertTrue(
            repository.uploads.allSatisfy { $0.hasPrefix("/fixed/" + root.lastPathComponent + "/") }
        )
        XCTAssertEqual(sut.recentTransfers.count, 1)
        let transfer = try XCTUnwrap(sut.recentTransfers.first)
        XCTAssertEqual(transfer.totalBytes, 10)
        XCTAssertEqual(transfer.bytesTransferred, 10)
        XCTAssertEqual(transfer.status, .completed)
        XCTAssertFalse(sut.isUploadingBatch)
    }

    func testConcurrentBatchRejectedAndCancelAllStopsLaterSources() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try write("a", in: root)
        let second = try write("b", in: root)
        let repository = UploadRecordingRepository()
        let sut = viewModel(repository)
        let entered = expectation(description: "First upload entered")
        let gate = UploadTestGate()
        defer { gate.open() }
        repository.onUpload = { _, _ in
            entered.fulfill()
            await gate.wait()
        }
        var returned = false
        var succeeded = true
        let batch = Task {
            succeeded = await sut.uploadSources([first, second], to: "/fixed")
            returned = true
        }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(sut.isUploadingBatch)
        XCTAssertFalse(returned)
        let concurrentSucceeded = await sut.uploadSources([second], to: "/other")
        XCTAssertFalse(concurrentSucceeded)
        XCTAssertNotNil(sut.error)
        XCTAssertEqual(repository.uploads, ["/fixed/a"])
        sut.cancelAllTransfers()
        XCTAssertEqual(sut.activeTransfers.count, 1, "Keep running tasks visible until cleanup")
        XCTAssertTrue(sut.recentTransfers.isEmpty)
        XCTAssertTrue(
            sut.isUploadingBatch, "Cancellation must retain ownership until cleanup finishes")
        XCTAssertFalse(returned)
        gate.open()
        await batch.value
        XCTAssertFalse(succeeded)
        XCTAssertFalse(sut.isUploadingBatch)
        XCTAssertEqual(repository.uploads, ["/fixed/a"])
        XCTAssertEqual(sut.recentTransfers.first?.status, .cancelled)
    }

    func testCallerCancellationStopsLaterSourcesWithoutDisconnect() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try write("a", in: root)
        let second = try write("b", in: root)
        let repository = UploadRecordingRepository()
        let sut = viewModel(repository)
        let entered = expectation(description: "Upload entered")
        let gate = UploadTestGate()
        defer { gate.open() }
        repository.onUpload = { _, _ in
            entered.fulfill()
            await gate.wait()
        }
        let batch = Task { await sut.uploadSources([first, second], to: "/fixed") }
        await fulfillment(of: [entered], timeout: 2)
        batch.cancel()
        gate.open()
        let succeeded = await batch.value
        XCTAssertFalse(succeeded)
        XCTAssertEqual(repository.uploads, ["/fixed/a"])
        XCTAssertEqual(sut.recentTransfers.first?.status, .cancelled)
        XCTAssertFalse(sut.isUploadingBatch)
    }

    func testNavigationDoesNotRetargetLaterSources() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try write("a", in: root)
        let second = try write("b", in: root)
        let repository = UploadRecordingRepository()
        let sut = viewModel(repository)
        let entered = expectation(description: "First upload entered")
        let gate = UploadTestGate()
        defer { gate.open() }
        repository.onUpload = { _, path in
            if path == "/fixed/a" {
                entered.fulfill()
                await gate.wait()
            }
        }
        let batch = Task { await sut.uploadSources([first, second], to: "/fixed") }
        await fulfillment(of: [entered], timeout: 2)
        await sut.navigateTo("/elsewhere")
        gate.open()
        let succeeded = await batch.value
        XCTAssertTrue(succeeded)
        XCTAssertEqual(repository.uploads, ["/fixed/a", "/fixed/b"])
        XCTAssertEqual(sut.recentTransfers.count, 2)
    }

    func testDisconnectWaitsForCleanup() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("a", in: root)
        let repository = UploadRecordingRepository()
        let session = MockSFTPSession()
        let sut = viewModel(repository, session: session)
        let entered = expectation(description: "Upload entered")
        let gate = UploadTestGate()
        defer { gate.open() }
        repository.onUpload = { _, _ in
            entered.fulfill()
            await gate.wait()
        }
        let batch = Task { await sut.uploadSources([file], to: "/fixed") }
        await fulfillment(of: [entered], timeout: 2)
        let transfer = try XCTUnwrap(sut.activeTransfers.values.first)
        sut.cancelTransfer(transfer)
        XCTAssertNotNil(sut.activeTransfers[transfer.id], "Retain in-progress state until cleanup")
        XCTAssertTrue(sut.recentTransfers.isEmpty)
        let disconnect = Task { await sut.disconnect() }
        await Task.yield()
        XCTAssertFalse(session.disconnectCalled)
        XCTAssertTrue(sut.isUploadingBatch)
        gate.open()
        await disconnect.value
        let succeeded = await batch.value
        XCTAssertFalse(succeeded)
        XCTAssertTrue(session.disconnectCalled)
        XCTAssertEqual(sut.recentTransfers.first?.status, .cancelled)
        XCTAssertFalse(sut.isUploadingBatch)
    }

    func testPreparingBatchCanBeCancelledWithoutRemoteWrites() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("a", in: root)
        let repository = UploadRecordingRepository()
        let sut = viewModel(repository)
        let batch = Task { await sut.uploadSources([root], to: "/fixed") }
        // runUploadBatch yields at every local item, before any remote writes.
        for _ in 0..<1000 {
            if sut.isUploadingBatch { break }
            await Task.yield()
        }
        XCTAssertTrue(sut.isUploadingBatch)
        sut.cancelAllTransfers()
        let succeeded = await batch.value
        XCTAssertFalse(succeeded)
        XCTAssertTrue(repository.uploads.isEmpty)
        XCTAssertTrue(repository.directories.isEmpty)
        XCTAssertFalse(sut.isUploadingBatch)
        XCTAssertNil(sut.error)
    }
}

@MainActor
private final class UploadRecordingRepository: FileRepositoryProtocol {
    var listPaths: [String] = []
    var uploads: [String] = []
    var directories: [String] = []
    var infoPaths: [String] = []
    var existingDirectories = Set<String>()
    var existingFiles = Set<String>()
    var infoError: Error?
    var mkdirError: Error?
    var deletions: [(path: String, isDirectory: Bool)] = []
    var onCreateDirectory: ((String) throws -> Void)?
    var onUpload: ((URL, String) async throws -> Void)?

    func getFileInfo(at path: String) async throws -> RemoteFile {
        infoPaths.append(path)
        if let infoError { throw infoError }
        if existingFiles.contains(path) {
            return RemoteFile(
                name: "file", path: path, isDirectory: false, size: 3, permissions: "-rw-r--r--")
        }
        guard existingDirectories.contains(path) else { throw AppError.fileNotFound }
        return RemoteFile(
            name: "folder", path: path, isDirectory: true, size: 0, permissions: "drwxr-xr-x")
    }

    func createDirectory(at path: String) async throws {
        directories.append(path)
        if let mkdirError { throw mkdirError }
        try onCreateDirectory?(path)
        existingDirectories.insert(path)
    }

    func upload(localURL: URL, to remotePath: String, progress: TransferProgressHandler?)
        async throws
    {
        uploads.append(remotePath)
        if let onUpload { try await onUpload(localURL, remotePath) }
        let size =
            (try FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        progress?(0)
        progress?(size)
        existingFiles.insert(remotePath)
    }

    func upload(localURL: URL, to remotePath: String) async throws {
        try await upload(localURL: localURL, to: remotePath, progress: nil)
    }

    func listFiles(at path: String) async throws -> [RemoteFile] {
        listPaths.append(path)
        return []
    }
    func createFile(at path: String) async throws {}
    func delete(at path: String, isDirectory: Bool) async throws {
        deletions.append((path, isDirectory))
        existingFiles = existingFiles.filter {
            $0 != path && !(isDirectory && $0.hasPrefix(path + "/"))
        }
        existingDirectories = existingDirectories.filter {
            $0 != path && !(isDirectory && $0.hasPrefix(path + "/"))
        }
    }
    func rename(from sourcePath: String, to destinationPath: String) async throws {}
    func copy(from sourcePath: String, to destinationPath: String, isDirectory: Bool) async throws {
    }
    func move(from sourcePath: String, to destinationPath: String) async throws {}
    func download(remotePath: String, to localURL: URL) async throws {}
    func download(remotePath: String, to localURL: URL, progress: TransferProgressHandler?)
        async throws
    {}
    func readFileContent(at path: String) async throws -> String { "" }
    func writeFileContent(_ content: String, to path: String) async throws {}
    func getRealPath(at path: String) async throws -> String { path }
}

/// Deliberately completes its backend connect after cancellation, like a non-cooperative SDK.
@MainActor
private final class DelayedUploadTestSession: SFTPSessionProtocol {
    let base = MockSFTPSession()
    var events: [String] = []
    var onConnect: (() async -> Void)?
    var onCancellation: @Sendable () -> Void = {}
    var isConnected: Bool { base.isConnected }
    var currentPath: String { base.currentPath }

    func connect(host: String, port: Int, username: String, password: String) async throws {
        let cancellation = onCancellation
        await withTaskCancellationHandler {
            await onConnect?()
        } onCancel: {
            cancellation()
        }
        try await base.connect(host: host, port: port, username: username, password: password)
        events.append("connected")
    }

    func connect(
        host: String, port: Int, username: String, privateKeyPath: String, passphrase: String?
    ) async throws {
        try await connect(host: host, port: port, username: username, password: passphrase ?? "")
    }

    func disconnect() async {
        events.append("disconnected")
        await base.disconnect()
    }

    func listFiles(at path: String) async throws -> [RemoteFile] {
        try await base.listFiles(at: path)
    }
    func getFileInfo(at path: String) async throws -> RemoteFile {
        try await base.getFileInfo(at: path)
    }
    func createDirectory(at path: String) async throws { try await base.createDirectory(at: path) }
    func createFile(at path: String) async throws { try await base.createFile(at: path) }
    func deleteFile(at path: String) async throws { try await base.deleteFile(at: path) }
    func deleteDirectory(at path: String) async throws { try await base.deleteDirectory(at: path) }
    func rename(from sourcePath: String, to destinationPath: String) async throws {
        try await base.rename(from: sourcePath, to: destinationPath)
    }
    func copyFile(from sourcePath: String, to destinationPath: String) async throws {
        try await base.copyFile(from: sourcePath, to: destinationPath)
    }
    func copyDirectory(from sourcePath: String, to destinationPath: String) async throws {
        try await base.copyDirectory(from: sourcePath, to: destinationPath)
    }
    func move(from sourcePath: String, to destinationPath: String) async throws {
        try await base.move(from: sourcePath, to: destinationPath)
    }
    func downloadFile(from remotePath: String, to localURL: URL) async throws {
        try await base.downloadFile(from: remotePath, to: localURL)
    }
    func downloadFile(from remotePath: String, to localURL: URL, progress: TransferProgressHandler?)
        async throws
    {
        try await base.downloadFile(from: remotePath, to: localURL, progress: progress)
    }
    func uploadFile(from localURL: URL, to remotePath: String) async throws {
        try await base.uploadFile(from: localURL, to: remotePath)
    }
    func uploadFile(from localURL: URL, to remotePath: String, progress: TransferProgressHandler?)
        async throws
    {
        try await base.uploadFile(from: localURL, to: remotePath, progress: progress)
    }
    func readFileContent(at path: String) async throws -> String {
        try await base.readFileContent(at: path)
    }
    func writeFileContent(_ content: String, to path: String) async throws {
        try await base.writeFileContent(content, to: path)
    }
    func getRealPath(at path: String) async throws -> String {
        try await base.getRealPath(at: path)
    }
    func executeCommand(_ command: String) async throws -> String {
        try await base.executeCommand(command)
    }
}

/// Open is permanent so a broken cancellation path cannot block a later queue item.
@MainActor
private final class UploadTestGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            XCTFail("Upload test gate timed out")
            self.open()
        }
        defer { watchdog.cancel() }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
