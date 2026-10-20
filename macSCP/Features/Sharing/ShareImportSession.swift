import SwiftUI

@MainActor
@Observable
final class ShareImportSession {
    let id: UUID
    private(set) var sources: [URL] = []
    private(set) var browser: FileBrowserViewModel?
    private(set) var preparationError: String?
    private(set) var isClosing = false
    var notice: String?

    private var ownsRequest = false
    private var closeTask: Task<Void, Never>?

    init(id: UUID) {
        self.id = id
        do {
            let request = try ShareRequestStore.load(id: id)
            ownsRequest = request.id == id
            guard request.id == id, !request.sources.isEmpty else {
                preparationError =
                    "This share request contains no files or is invalid. Please share the files again."
                return
            }
            sources = request.sources
        } catch {
            preparationError =
                "The shared files could not be prepared. They may have expired. Please share them again.\n\(error.localizedDescription)"
        }
    }

    var canPrepareBrowser: Bool { preparationError == nil && !sources.isEmpty }

    /// The connection picker is a separate alert; this window only hosts the browser.
    func prepareBrowser(connection: Connection, secret: String) {
        guard browser == nil, !isClosing else { return }
        let container = DependencyContainer.shared
        if connection.connectionType == .s3 {
            browser = container.makeS3FileBrowserViewModel(
                connection: connection,
                s3Session: container.makeS3Session(),
                secretAccessKey: secret
            )
        } else {
            browser = container.makeFileBrowserViewModel(
                connection: connection,
                sftpSession: container.makeSFTPSession(),
                password: secret
            )
        }
    }

    /// Called only after the complete batch succeeds. Failed attempts keep their staged sources.
    func uploadFinished() {
        guard !isClosing else { return }
        removeRequest()
    }

    func close() async {
        if let closeTask {
            await closeTask.value
            return
        }
        isClosing = true
        let task = Task { @MainActor in
            await browser?.disconnect()
            removeRequest()
        }
        closeTask = task
        await task.value
    }

    private func removeRequest() {
        sources = []
        guard ownsRequest else { return }
        do {
            try ShareRequestStore.remove(id: id)
            ownsRequest = false
        } catch {
            notice =
                "The transfer has ended, but temporary shared files could not be removed. Closing this window will retry cleanup.\n\(error.localizedDescription)"
        }
    }
}
