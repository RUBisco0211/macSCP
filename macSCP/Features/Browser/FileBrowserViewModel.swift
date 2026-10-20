//
//  FileBrowserViewModel.swift
//  macSCP
//
//  ViewModel for the file browser feature
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class FileBrowserViewModel {
    // MARK: - Published State
    private(set) var files: [RemoteFile] = []
    private(set) var state: ViewState<Void> = .idle
    private(set) var currentPath: String = "/"
    private(set) var isConnected: Bool = false
    var error: AppError?

    // MARK: - Transfer Progress State
    private(set) var activeTransfers: [UUID: TransferProgress] = [:]
    private(set) var recentTransfers: [TransferProgress] = []  // Completed/failed transfers
    private var transferTasks: [UUID: Task<Void, Never>] = [:]  // Tasks for cancellation
    private(set) var isUploadingBatch = false
    private var uploadBatchTask: Task<Bool, Never>?
    private(set) var pendingUploadConflict: UploadConflict?
    private var uploadConflictContinuation: CheckedContinuation<UploadConflictDecision, Never>?
    private var connectTask: Task<Void, Never>?
    private var isDisconnecting = false
    var isShowingTransfersPopover: Bool = false

    /// Whether any transfer is currently in progress
    var hasActiveTransfers: Bool {
        !activeTransfers.isEmpty
    }

    /// Total number of active transfers
    var activeTransferCount: Int {
        activeTransfers.count
    }

    /// All transfers for display (active + recent)
    var allTransfers: [TransferProgress] {
        let active = activeTransfers.values.sorted { $0.startTime > $1.startTime }
        return active + recentTransfers
    }

    /// Overall progress of all active transfers (0.0 to 1.0)
    var overallProgress: Double {
        guard !activeTransfers.isEmpty else { return 0 }
        let totalBytes = activeTransfers.values.reduce(0) { $0 + $1.totalBytes }
        let transferredBytes = activeTransfers.values.reduce(0) { $0 + $1.bytesTransferred }
        guard totalBytes > 0 else { return 0 }
        return Double(transferredBytes) / Double(totalBytes)
    }

    var selectedFiles: Set<UUID> = []
    var sortCriteria: RemoteFile.SortCriteria = .name
    var sortAscending: Bool = true
    var showHiddenFiles: Bool = false

    // Sheet states
    var isShowingNewFolderSheet = false
    var isShowingNewFileSheet = false
    var isShowingRenameSheet = false
    var isShowingDeleteConfirmation = false

    // File to operate on
    var fileToRename: RemoteFile?
    var filesToDelete: [RemoteFile] = []

    // Window opening state
    var pendingFileInfoWindowId: String?
    var pendingEditorWindowId: String?
    var pendingTerminalWindowId: String?

    // MARK: - Connection Info
    let connection: Connection
    private let password: String

    // MARK: - Dependencies
    private let sftpSession: SFTPSessionProtocol?
    private let s3Session: S3SessionProtocol?
    private let fileRepository: FileRepositoryProtocol
    private let clipboardService: ClipboardService
    private let navigationService = NavigationService()

    // MARK: - Initialization (SFTP)
    init(
        connection: Connection,
        sftpSession: SFTPSessionProtocol,
        fileRepository: FileRepositoryProtocol,
        clipboardService: ClipboardService,
        password: String
    ) {
        self.connection = connection
        self.sftpSession = sftpSession
        self.s3Session = nil
        self.fileRepository = fileRepository
        self.clipboardService = clipboardService
        self.password = password
    }

    // MARK: - Initialization (S3)
    init(
        connection: Connection,
        s3Session: S3SessionProtocol,
        fileRepository: FileRepositoryProtocol,
        clipboardService: ClipboardService,
        secretAccessKey: String
    ) {
        self.connection = connection
        self.sftpSession = nil
        self.s3Session = s3Session
        self.fileRepository = fileRepository
        self.clipboardService = clipboardService
        self.password = secretAccessKey
    }

    // MARK: - Computed Properties

    var sortedFiles: [RemoteFile] {
        var result = files

        if !showHiddenFiles {
            result = result.filter { !$0.isHidden }
        }

        return RemoteFile.sortedFiles(result, by: sortCriteria, ascending: sortAscending)
    }

    var selectedFilesList: [RemoteFile] {
        files.filter { selectedFiles.contains($0.id) }
    }

    var canGoBack: Bool {
        navigationService.canGoBack
    }

    var canGoForward: Bool {
        navigationService.canGoForward
    }

    var canGoUp: Bool {
        currentPath != "/"
    }

    var pathComponents: [PathComponent] {
        var components: [PathComponent] = []
        var path = ""

        for component in currentPath.split(separator: "/") {
            path += "/" + component
            components.append(PathComponent(name: String(component), path: path))
        }

        if components.isEmpty {
            components.append(PathComponent(name: "/", path: "/"))
        }

        return components
    }

    var clipboardDisplayText: String {
        clipboardService.displayText
    }

    var hasClipboardItems: Bool {
        !clipboardService.isEmpty
    }

    var canPaste: Bool {
        clipboardService.canPaste(to: connection.id)
    }

    // MARK: - Connection

    func connect() async {
        guard !isDisconnecting, !Task.isCancelled else { return }
        if let connectTask {
            await withTaskCancellationHandler {
                await connectTask.value
            } onCancel: {
                connectTask.cancel()
            }
            return
        }
        let task = Task { await self.performConnect() }
        connectTask = task
        defer { connectTask = nil }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performConnect() async {
        state = .loading

        do {
            try Task.checkCancellation()
            if connection.connectionType == .s3 {
                // S3 connection
                guard let s3Session = s3Session else {
                    throw AppError.notConnected
                }
                try await s3Session.connect(
                    accessKeyId: connection.username,
                    secretAccessKey: password,
                    region: connection.s3Region ?? "us-east-1",
                    bucket: connection.s3Bucket ?? "",
                    endpoint: connection.s3Endpoint
                )
                try Task.checkCancellation()
                let connectedPath = await s3Session.currentPath
                try Task.checkCancellation()
                isConnected = true
                currentPath = connectedPath
                navigationService.reset(to: currentPath)
                AnalyticsService.trackFileBrowserOpened(
                    protocol: .init(from: connection.connectionType))
                await loadFiles()
            } else {
                // SFTP connection
                guard let sftpSession = sftpSession else {
                    throw AppError.notConnected
                }
                if connection.authMethod == .password {
                    try await sftpSession.connect(
                        host: connection.host,
                        port: connection.port,
                        username: connection.username,
                        password: password
                    )
                } else if let keyPath = connection.privateKeyPath {
                    try await sftpSession.connect(
                        host: connection.host,
                        port: connection.port,
                        username: connection.username,
                        privateKeyPath: keyPath,
                        passphrase: password.isEmpty ? nil : password
                    )
                }
                try Task.checkCancellation()
                let connectedPath = await sftpSession.currentPath
                try Task.checkCancellation()
                isConnected = true
                currentPath = connectedPath
                navigationService.reset(to: currentPath)
                AnalyticsService.trackFileBrowserOpened(
                    protocol: .init(from: connection.connectionType))
                await loadFiles()
            }
            try Task.checkCancellation()
        } catch {
            if error is CancellationError || Task.isCancelled {
                // A backend may finish connecting even after cancellation. If disconnect
                // is joining us it owns teardown; otherwise clean up before releasing ownership.
                if !isDisconnecting {
                    if connection.connectionType == .s3 {
                        await s3Session?.disconnect()
                    } else {
                        await sftpSession?.disconnect()
                    }
                }
                isConnected = false
                files = []
                currentPath = "/"
                navigationService.reset()
                state = .idle
                return
            }
            logError(
                "Connection failed: \(error)",
                category: connection.connectionType == .s3 ? .s3 : .sftp)
            state = .error(AppError.from(error))
        }
    }

    func disconnect() async {
        isDisconnecting = true
        defer { isDisconnecting = false }
        connectTask?.cancel()
        cancelAllTransfers()
        let pendingTransfers = Array(transferTasks.values)
        await connectTask?.value
        _ = await uploadBatchTask?.value
        for task in pendingTransfers {
            await task.value
        }
        if connection.connectionType == .s3 {
            await s3Session?.disconnect()
        } else {
            await sftpSession?.disconnect()
        }
        isConnected = false
        files = []
        currentPath = "/"
        navigationService.reset()
    }

    // MARK: - Navigation

    func loadFiles() async {
        state = .loading

        do {
            try Task.checkCancellation()
            let loadedFiles = try await fileRepository.listFiles(at: currentPath)
            let loadedPath: String
            if connection.connectionType == .s3 {
                loadedPath = await s3Session?.currentPath ?? "/"
            } else {
                loadedPath = await sftpSession?.currentPath ?? "/"
            }
            try Task.checkCancellation()
            files = loadedFiles
            currentPath = loadedPath
            state = .success(())
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            logError(
                "Failed to load files: \(error)",
                category: connection.connectionType == .s3 ? .s3 : .sftp)
            state = .error(AppError.from(error))
        }
    }

    func navigateTo(_ path: String) async {
        state = .loading

        do {
            files = try await fileRepository.listFiles(at: path)
            if connection.connectionType == .s3 {
                currentPath = await s3Session?.currentPath ?? "/"
            } else {
                currentPath = await sftpSession?.currentPath ?? "/"
            }
            navigationService.navigate(to: currentPath)
            selectedFiles.removeAll()
            state = .success(())
        } catch {
            logError(
                "Failed to navigate to \(path): \(error)",
                category: connection.connectionType == .s3 ? .s3 : .sftp)
            state = .error(AppError.from(error))
        }
    }

    func openFile(_ file: RemoteFile) async {
        if file.isDirectory {
            await navigateTo(file.path)
        } else if FileTypeService.isPreviewable(file) {
            // Open in editor - handled by view
        }
    }

    func goBack() async {
        if let path = navigationService.goBack() {
            await navigateWithoutHistory(to: path)
        }
    }

    func goForward() async {
        if let path = navigationService.goForward() {
            await navigateWithoutHistory(to: path)
        }
    }

    func goUp() async {
        await navigateTo(currentPath.parentPath)
    }

    func goHome() async {
        await navigateTo("~")
    }

    func refresh() async {
        await loadFiles()
    }

    private func navigateWithoutHistory(to path: String) async {
        state = .loading

        do {
            files = try await fileRepository.listFiles(at: path)
            if connection.connectionType == .s3 {
                currentPath = await s3Session?.currentPath ?? "/"
            } else {
                currentPath = await sftpSession?.currentPath ?? "/"
            }
            selectedFiles.removeAll()
            state = .success(())
        } catch {
            logError(
                "Failed to navigate to \(path): \(error)",
                category: connection.connectionType == .s3 ? .s3 : .sftp)
            state = .error(AppError.from(error))
        }
    }

    // MARK: - File Operations

    func createFolder(name: String) async {
        let path = currentPath.appendingPathComponent(name)

        do {
            try await fileRepository.createDirectory(at: path)
            isShowingNewFolderSheet = false
            AnalyticsService.trackFileOperation(
                .createFolder, protocol: .init(from: connection.connectionType))
            await loadFiles()
        } catch {
            logError("Failed to create folder: \(error)", category: .sftp)
            self.error = AppError.from(error)
        }
    }

    func createFile(name: String) async {
        let path = currentPath.appendingPathComponent(name)

        do {
            try await fileRepository.createFile(at: path)
            isShowingNewFileSheet = false
            await loadFiles()
        } catch {
            logError("Failed to create file: \(error)", category: .sftp)
            self.error = AppError.from(error)
        }
    }

    func renameFile(_ file: RemoteFile, to newName: String) async {
        let newPath = file.path.directoryPath.appendingPathComponent(newName)

        do {
            try await fileRepository.rename(from: file.path, to: newPath)
            isShowingRenameSheet = false
            fileToRename = nil
            AnalyticsService.trackFileOperation(
                .rename, protocol: .init(from: connection.connectionType))
            await loadFiles()
        } catch {
            logError("Failed to rename file: \(error)", category: .sftp)
            self.error = AppError.from(error)
        }
    }

    func deleteFiles(_ files: [RemoteFile]) async {
        for file in files {
            do {
                try await fileRepository.delete(at: file.path, isDirectory: file.isDirectory)
            } catch {
                logError("Failed to delete \(file.name): \(error)", category: .sftp)
                self.error = AppError.from(error)
                return
            }
        }

        isShowingDeleteConfirmation = false
        filesToDelete = []
        selectedFiles.removeAll()
        AnalyticsService.trackFileOperation(
            .delete, protocol: .init(from: connection.connectionType), count: files.count)
        await loadFiles()
    }

    func deleteSelectedFiles() async {
        await deleteFiles(selectedFilesList)
    }

    // MARK: - Clipboard Operations

    func copySelectedFiles() {
        clipboardService.copy(
            files: selectedFilesList, from: currentPath, connectionId: connection.id)
    }

    func cutSelectedFiles() {
        clipboardService.cut(
            files: selectedFilesList, from: currentPath, connectionId: connection.id)
    }

    func paste() async {
        guard canPaste else { return }

        let items = clipboardService.items
        let isCut = clipboardService.isCut

        for item in items {
            let destinationPath = currentPath.appendingPathComponent(item.fileName)

            do {
                if isCut {
                    try await fileRepository.move(from: item.fullSourcePath, to: destinationPath)
                } else {
                    try await fileRepository.copy(
                        from: item.fullSourcePath,
                        to: destinationPath,
                        isDirectory: item.isDirectory
                    )
                }
            } catch {
                logError("Failed to paste \(item.fileName): \(error)", category: .sftp)
                self.error = AppError.from(error)
                return
            }
        }

        if isCut {
            clipboardService.clear()
        }

        await loadFiles()
    }

    // MARK: - Download/Upload

    func downloadFile(_ file: RemoteFile) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let transferId = UUID()
        let transfer = TransferProgress(
            id: transferId,
            fileName: file.name,
            localURL: url,
            remotePath: file.path,
            bytesTransferred: 0,
            totalBytes: file.size,
            transferType: .download,
            status: .inProgress
        )
        activeTransfers[transferId] = transfer
        isShowingTransfersPopover = true

        let downloadTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                try Task.checkCancellation()

                try await self.fileRepository.download(remotePath: file.path, to: url) {
                    [weak self] bytesTransferred in
                    Task { @MainActor in
                        guard self?.activeTransfers[transferId] != nil else { return }
                        self?.activeTransfers[transferId]?.bytesTransferred = bytesTransferred
                    }
                }

                try Task.checkCancellation()

                await MainActor.run {
                    if var completedTransfer = self.activeTransfers.removeValue(forKey: transferId)
                    {
                        completedTransfer.status = .completed
                        completedTransfer.bytesTransferred = file.size
                        self.recentTransfers.insert(completedTransfer, at: 0)
                        if self.recentTransfers.count > 10 {
                            self.recentTransfers = Array(self.recentTransfers.prefix(10))
                        }
                    }
                    self.transferTasks.removeValue(forKey: transferId)
                }

                AnalyticsService.trackFileDownloaded(
                    protocol: .init(from: self.connection.connectionType), fileCount: 1,
                    totalBytes: file.size)
                logInfo(
                    "Downloaded: \(file.name)",
                    category: self.connection.connectionType == .s3 ? .s3 : .sftp)

            } catch {
                let isCancellation =
                    error is CancellationError || Task.isCancelled
                    || String(describing: error).contains("CancellationError")

                if isCancellation {
                    await MainActor.run {
                        if var cancelledTransfer = self.activeTransfers.removeValue(
                            forKey: transferId)
                        {
                            cancelledTransfer.status = .cancelled
                            self.recentTransfers.insert(cancelledTransfer, at: 0)
                        }
                        self.transferTasks.removeValue(forKey: transferId)
                    }
                    logInfo(
                        "Download cancelled: \(file.name)",
                        category: self.connection.connectionType == .s3 ? .s3 : .sftp)
                } else {
                    await MainActor.run {
                        if var failedTransfer = self.activeTransfers.removeValue(forKey: transferId)
                        {
                            failedTransfer.status = .failed
                            failedTransfer.error = error.localizedDescription
                            self.recentTransfers.insert(failedTransfer, at: 0)
                        }
                        self.transferTasks.removeValue(forKey: transferId)
                    }

                    logError(
                        "Download failed: \(error)",
                        category: self.connection.connectionType == .s3 ? .s3 : .sftp)
                    await MainActor.run {
                        self.error = AppError.from(error)
                    }
                }
            }
        }

        transferTasks[transferId] = downloadTask
    }

    func uploadFiles() async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true

        guard panel.runModal() == .OK else { return }

        await uploadSources(panel.urls, to: currentPath)
    }

    /// Uploads a fixed-destination batch and waits for preparation, transfers and cleanup.
    /// Concurrent batches are rejected, including while the first batch is preparing.
    /// Returns true for a nonempty batch fully handled without failure/cancellation.
    /// Explicit skips are accepted outcomes, so shared staging does not retain them for retry.
    @discardableResult
    func uploadSources(_ urls: [URL], to destinationPath: String) async -> Bool {
        logInfo(
            "uploadSources: urls=\(urls.count) destination=\(destinationPath) uploading=\(isUploadingBatch) disconnecting=\(isDisconnecting)",
            category: .ui)
        guard !isUploadingBatch else {
            error = .uploadFailed(String(localized: "Another upload batch is already running"))
            return false
        }
        guard !isDisconnecting else {
            error = .notConnected
            return false
        }
        guard !Task.isCancelled, !urls.isEmpty else { return false }
        isUploadingBatch = true
        let task = Task { await self.runUploadBatch(urls, destinationPath: destinationPath) }
        uploadBatchTask = task
        let succeeded = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        uploadBatchTask = nil
        isUploadingBatch = false
        return succeeded && !Task.isCancelled && !task.isCancelled
    }

    private func runUploadBatch(_ urls: [URL], destinationPath: String) async -> Bool {
        logInfo("runUploadBatch started", category: .ui)
        let scopedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
        var allSucceeded = true
        do {
            let batch = try await UploadBatch.prepare(urls, destinationPath: destinationPath)
            logInfo(
                "Upload batch prepared: \(batch.sources.count) source(s), \(batch.sources.reduce(0) { $0 + $1.entries.count }) entry(ies)",
                category: .ui)
            for source in batch.sources {
                try Task.checkCancellation()
                let id = UUID()
                activeTransfers[id] = TransferProgress(
                    id: id, fileName: source.url.lastPathComponent, localURL: source.url,
                    remotePath: source.remotePath, totalBytes: source.totalBytes
                )
                isShowingTransfersPopover = true
                var sourceSucceeded = false
                let itemTask = Task {
                    sourceSucceeded = await self.uploadSource(source, transferID: id)
                }
                transferTasks[id] = itemTask
                await withTaskCancellationHandler {
                    await itemTask.value
                } onCancel: {
                    itemTask.cancel()
                }
                transferTasks.removeValue(forKey: id)
                allSucceeded = allSucceeded && sourceSucceeded && !itemTask.isCancelled
                try Task.checkCancellation()
            }
        } catch {
            allSucceeded = false
            if !(error is CancellationError), !Task.isCancelled {
                self.error = AppError.from(error)
            }
        }
        // Do not refresh a cancelled batch or race the disconnect's session teardown.
        if !Task.isCancelled, !isDisconnecting {
            await loadFiles()
        }
        return allSucceeded && !Task.isCancelled
    }

    private func uploadSource(_ source: UploadBatch.Source, transferID: UUID) async -> Bool {
        logInfo(
            "Upload source started: \(source.url.lastPathComponent) entries=\(source.entries.count)",
            category: .ui)
        do {
            var completedBytes: Int64 = 0
            var uploadedBytes: Int64 = 0
            var uploadedFiles = 0
            var skippedEntries = 0
            var skippedDirectory: String?
            for entry in source.entries {
                try Task.checkCancellation()
                if let skippedDirectory,
                    entry.remotePath.hasPrefix(skippedDirectory + "/")
                {
                    completedBytes += entry.size
                    skippedEntries += 1
                    activeTransfers[transferID]?.bytesTransferred = completedBytes
                    continue
                }
                skippedDirectory = nil
                // Revalidate the source type in case it changed after preparation.
                let attributes = try FileManager.default.attributesOfItem(
                    atPath: entry.localURL.path)
                let expected: FileAttributeType = entry.isDirectory ? .typeDirectory : .typeRegular
                guard attributes[.type] as? FileAttributeType == expected else {
                    throw AppError.uploadFailed(
                        String(localized: "Source type changed: \(entry.localURL.path)"))
                }
                var skipped = false
                while true {
                    let accepted = try await UploadBatch.prepareDestination(
                        for: entry, repository: fileRepository,
                        resolve: { try await self.requestUploadConflictDecision($0) })
                    guard accepted else {
                        skipped = true
                        break
                    }
                    if entry.isDirectory { break }
                    try Task.checkCancellation()
                    let base = completedBytes
                    do {
                        try await fileRepository.upload(
                            localURL: entry.localURL, to: entry.remotePath
                        ) { [weak self] bytes in
                            Task { @MainActor in
                                guard let self, let transfer = self.activeTransfers[transferID]
                                else {
                                    return
                                }
                                // Late callbacks must not move aggregate progress backwards.
                                self.activeTransfers[transferID]?.bytesTransferred = max(
                                    transfer.bytesTransferred, base + min(max(0, bytes), entry.size)
                                )
                            }
                        }
                        uploadedBytes += entry.size
                        uploadedFiles += 1
                        break
                    } catch AppError.fileAlreadyExists {
                        // A backend-reported create race needs a fresh query and decision too.
                        continue
                    }
                }
                if skipped {
                    skippedEntries += 1
                    if entry.isDirectory { skippedDirectory = entry.remotePath }
                }
                completedBytes += entry.size
                activeTransfers[transferID]?.bytesTransferred = completedBytes
                try Task.checkCancellation()
            }
            finishUpload(
                transferID, status: .completed,
                message: skippedEntries > 0
                    ? String(localized: "Skipped \(skippedEntries) item(s)") : nil)
            if uploadedFiles > 0 {
                AnalyticsService.trackFileUploaded(
                    protocol: .init(from: connection.connectionType),
                    fileCount: uploadedFiles, totalBytes: uploadedBytes)
            }
            return true
        } catch {
            if error is CancellationError || Task.isCancelled {
                finishUpload(transferID, status: .cancelled)
            } else {
                finishUpload(transferID, status: .failed, message: error.localizedDescription)
                self.error = AppError.from(error)
            }
            return false
        }
    }

    private func requestUploadConflictDecision(_ conflict: UploadConflict) async throws
        -> UploadConflictDecision
    {
        logInfo(
            "Upload conflict needs a decision: \(conflict.remotePath) sourceDir=\(conflict.sourceIsDirectory) destinationDir=\(conflict.destinationIsDirectory)",
            category: .ui)
        try Task.checkCancellation()
        let decision: UploadConflictDecision = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Cancellation can arrive before continuation registration.
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancel)
                    return
                }
                uploadConflictContinuation = continuation
                pendingUploadConflict = conflict
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.completeUploadConflict(.cancel, for: conflict.id)
            }
        }
        try Task.checkCancellation()
        return decision
    }

    func resolveUploadConflict(_ decision: UploadConflictDecision) {
        guard let id = pendingUploadConflict?.id else { return }
        resolveUploadConflict(decision, for: id)
    }

    /// Sheets should capture their item's ID so a late dismiss/click cannot answer a later sheet.
    func resolveUploadConflict(_ decision: UploadConflictDecision, for id: UUID) {
        guard let conflict = pendingUploadConflict, conflict.id == id else { return }
        if case .merge = decision,
            !(conflict.sourceIsDirectory && conflict.destinationIsDirectory)
        {
            return
        }
        completeUploadConflict(decision, for: id)
        if case .cancel = decision { cancelAllTransfers() }
    }

    private func completeUploadConflict(_ decision: UploadConflictDecision, for id: UUID) {
        guard pendingUploadConflict?.id == id else { return }
        let continuation = uploadConflictContinuation
        uploadConflictContinuation = nil
        pendingUploadConflict = nil
        continuation?.resume(returning: decision)
    }

    private func finishUpload(_ id: UUID, status: TransferStatus, message: String? = nil) {
        guard var transfer = activeTransfers.removeValue(forKey: id) else { return }
        transfer.status = status
        transfer.error = message
        if status == .completed { transfer.bytesTransferred = transfer.totalBytes }
        recentTransfers.insert(transfer, at: 0)
        recentTransfers = Array(recentTransfers.prefix(10))
    }

    /// Cancels an active transfer
    func cancelTransfer(_ transfer: TransferProgress) {
        guard transfer.isInProgress else { return }

        // Keep the task and in-progress UI entry until its actual cleanup completes.
        // disconnect must still be able to join an individually cancelled transfer.
        transferTasks[transfer.id]?.cancel()
    }

    /// Cancels all active transfers
    func cancelAllTransfers() {
        if let conflict = pendingUploadConflict {
            completeUploadConflict(.cancel, for: conflict.id)
        }
        uploadBatchTask?.cancel()
        for task in transferTasks.values {
            task.cancel()
        }
    }

    // MARK: - Drag and Drop

    /// Downloads a file to a specific URL (used for drag-out file promises)
    func downloadFileToURL(_ file: RemoteFile, destinationURL: URL) async throws {
        let transferId = UUID()
        let transfer = TransferProgress(
            id: transferId,
            fileName: file.name,
            localURL: destinationURL,
            remotePath: file.path,
            bytesTransferred: 0,
            totalBytes: file.size,
            transferType: .download,
            status: .inProgress
        )
        activeTransfers[transferId] = transfer
        isShowingTransfersPopover = true

        do {
            try await fileRepository.download(remotePath: file.path, to: destinationURL) {
                [weak self] bytesTransferred in
                Task { @MainActor in
                    guard self?.activeTransfers[transferId] != nil else { return }
                    self?.activeTransfers[transferId]?.bytesTransferred = bytesTransferred
                }
            }

            if var completedTransfer = activeTransfers.removeValue(forKey: transferId) {
                completedTransfer.status = .completed
                completedTransfer.bytesTransferred = file.size
                recentTransfers.insert(completedTransfer, at: 0)
                if recentTransfers.count > 10 {
                    recentTransfers = Array(recentTransfers.prefix(10))
                }
            }

            AnalyticsService.trackFileDownloaded(
                protocol: .init(from: connection.connectionType), fileCount: 1,
                totalBytes: file.size)
            logInfo(
                "Downloaded via drag: \(file.name)",
                category: connection.connectionType == .s3 ? .s3 : .sftp)
        } catch {
            if var failedTransfer = activeTransfers.removeValue(forKey: transferId) {
                failedTransfer.status = .failed
                failedTransfer.error = error.localizedDescription
                recentTransfers.insert(failedTransfer, at: 0)
            }
            throw error
        }
    }

    /// Uploads files dropped from Finder into the current directory
    func uploadDroppedFiles(_ urls: [URL]) async {
        await uploadSources(urls, to: currentPath)
    }

    /// Clears completed/failed transfers from the list
    func clearCompletedTransfers() {
        recentTransfers.removeAll()
    }

    /// Removes a specific transfer from the recent list
    func removeTransfer(_ transfer: TransferProgress) {
        recentTransfers.removeAll { $0.id == transfer.id }
    }

    // MARK: - File Content

    func getFileContent(_ file: RemoteFile) async throws -> String {
        try await fileRepository.readFileContent(at: file.path)
    }

    func saveFileContent(_ content: String, to path: String) async throws {
        try await fileRepository.writeFileContent(content, to: path)
    }

    // MARK: - Selection

    func selectAll() {
        selectedFiles = Set(sortedFiles.map { $0.id })
    }

    func deselectAll() {
        selectedFiles.removeAll()
    }

    func toggleSelection(for file: RemoteFile) {
        if selectedFiles.contains(file.id) {
            selectedFiles.remove(file.id)
        } else {
            selectedFiles.insert(file.id)
        }
    }

    // MARK: - UI Actions

    func confirmDelete(_ files: [RemoteFile]) {
        filesToDelete = files
        isShowingDeleteConfirmation = true
    }

    func confirmDeleteSelected() {
        confirmDelete(selectedFilesList)
    }

    func startRename(_ file: RemoteFile) {
        fileToRename = file
        isShowingRenameSheet = true
    }

    func showFileInfo(_ file: RemoteFile) {
        let data = FileInfoWindowData(
            file: file,
            connectionName: connection.name
        )
        let windowId = WindowManager.shared.storeFileInfoData(data)
        pendingFileInfoWindowId = windowId
        AnalyticsService.track(.fileInfoOpened)
    }

    func clearPendingFileInfoWindow() {
        pendingFileInfoWindowId = nil
    }

    func openEditor(for file: RemoteFile, content: String) {
        let data = FileEditorWindowData(
            filePath: file.path,
            fileName: file.name,
            content: content,
            connectionId: connection.id,
            host: connection.host,
            port: connection.port,
            username: connection.username,
            password: password,
            authMethod: connection.authMethod,
            privateKeyPath: connection.privateKeyPath,
            connectionType: connection.connectionType,
            s3Region: connection.s3Region,
            s3Bucket: connection.s3Bucket,
            s3Endpoint: connection.s3Endpoint
        )
        let windowId = WindowManager.shared.storeFileEditorData(data)
        pendingEditorWindowId = windowId
        AnalyticsService.trackEditorOpened(fileExtension: (file.name as NSString).pathExtension)
    }

    func clearPendingEditorWindow() {
        pendingEditorWindowId = nil
    }

    func clearPendingTerminalWindow() {
        pendingTerminalWindowId = nil
    }

    // MARK: - Terminal

    func openTerminal() {
        // Only supported for SFTP connections
        guard connection.connectionType == .sftp else {
            logWarning("Terminal only supported for SFTP connections", category: .ui)
            return
        }

        let data = TerminalWindowData(
            connectionId: connection.id,
            connectionName: connection.name,
            host: connection.host,
            port: connection.port,
            username: connection.username,
            password: password,
            authMethod: connection.authMethod,
            privateKeyPath: connection.privateKeyPath
        )

        let windowId = WindowManager.shared.storeTerminalData(data)
        pendingTerminalWindowId = windowId
        logInfo("Opening terminal from file browser", category: .ui)
    }

    func clearError() {
        error = nil
    }
}

// MARK: - Path Component
struct PathComponent: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let path: String

    static func == (lhs: PathComponent, rhs: PathComponent) -> Bool {
        lhs.path == rhs.path && lhs.name == rhs.name
    }
}
