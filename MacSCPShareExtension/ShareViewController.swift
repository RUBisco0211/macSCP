import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

private let sharePreparationLogger = Logger(
    subsystem: "com.macscp.macSCP.ShareExtension", category: "SharePreparation")

@MainActor
final class ShareViewController: NSViewController {
    private let state = SharePreparationState()
    private var preparation: Task<Void, Never>?
    private var started = false

    override func loadView() {
        view = NSHostingView(
            rootView: SharePreparationView(
                state: state,
                retry: { [weak self] in self?.prepare() },
                cancel: { [weak self] in self?.cancel() }
            ))
        preferredContentSize = NSSize(width: 420, height: 220)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !started else { return }
        started = true
        prepare()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        preparation?.cancel()
    }

    deinit {
        preparation?.cancel()
    }

    private func prepare() {
        guard preparation == nil else { return }
        state.error = nil
        state.message = "Preparing shared files…"
        state.isPreparing = true
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        let state = state
        let context = extensionContext
        // The task must outlive teardown long enough to join copying and discard the draft,
        // without retaining the controller and preventing its deinit cancellation.
        preparation = Task { [weak self] in
            defer { self?.preparation = nil }
            var store: ShareRequestStore?
            var draft: ShareRequestStore.Draft?
            var publishedID: UUID?
            do {
                guard !providers.isEmpty, providers.count <= 1000,
                    providers.allSatisfy({
                        $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                    })
                else {
                    throw SharePreparationError.invalidSelection
                }
                let requestStore = ShareRequestStore.extensionStore()
                store = requestStore
                let requestDraft = try requestStore.begin()
                draft = requestDraft
                var names: [String] = []
                for (index, provider) in providers.enumerated() {
                    try Task.checkCancellation()
                    state.message = "Preparing item \(index + 1) of \(providers.count)…"
                    let name = try await Self.stage(
                        provider, index: index, store: requestStore, draft: requestDraft)
                    names.append(name)
                }
                try Task.checkCancellation()
                let request = try requestStore.publish(requestDraft, names: names)
                publishedID = request.id
                sharePreparationLogger.info(
                    "Published share request \(request.id.uuidString, privacy: .public)")
                state.message = "Opening macSCP…"
                try await Self.openContainingApp(requestID: request.id)
                sharePreparationLogger.info(
                    "Containing app opened for share request \(request.id.uuidString, privacy: .public)"
                )
                // The main app owns the published payload after Launch Services accepts it.
                context?.completeRequest(returningItems: [], completionHandler: nil)
            } catch {
                if let store, let draft { try? store.discard(draft) }
                if let store, let publishedID { try? store.remove(id: publishedID) }
                if error is CancellationError || Task.isCancelled {
                    context?.cancelRequest(withError: CocoaError(.userCancelled))
                } else {
                    state.error = error.localizedDescription
                    state.isPreparing = false
                }
            }
        }
    }

    private func cancel() {
        if state.isPreparing {
            state.message = "Cancelling and cleaning up…"
            preparation?.cancel()
        } else {
            extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
    }

    private nonisolated static func stage(
        _ provider: NSItemProvider, index: Int, store: ShareRequestStore,
        draft: ShareRequestStore.Draft
    ) async throws -> String {
        let gate = ShareProviderLoadGate()
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    guard gate.install(continuation) else { return }
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) {
                        item, error in
                        guard gate.beginCopy() else { return }
                        if let error {
                            gate.finish(.failure(error))
                            return
                        }

                        let url: URL?
                        if let value = item as? URL {
                            url = value
                        } else if let data = item as? Data {
                            url = URL(dataRepresentation: data, relativeTo: nil)
                        } else {
                            url = nil
                        }
                        guard let url, url.isFileURL else {
                            gate.finish(.failure(SharePreparationError.invalidSelection))
                            return
                        }
                        let accessed = url.startAccessingSecurityScopedResource()
                        defer {
                            if accessed { url.stopAccessingSecurityScopedResource() }
                        }
                        // Copy inside the callback: a provider may delete its temporary
                        // representation as soon as this handler returns.
                        let result = Result {
                            try store.stage(
                                url, index: index, in: draft,
                                cancelled: { gate.progress.isCancelled })
                        }
                        gate.finish(result)
                    }
                }
            } onCancel: {
                gate.cancel()
            }
        } catch {
            if error is CancellationError || Task.isCancelled {
                sharePreparationLogger.info(
                    "Share stage cancelled: request=\(draft.id.uuidString, privacy: .public) item=\(index)"
                )
            } else {
                // Error descriptions/userInfo can contain source paths or file names.
                sharePreparationLogger.error(
                    "Share stage failed: request=\(draft.id.uuidString, privacy: .public) item=\(index) code=\((error as NSError).code)"
                )
            }
            throw error
        }
    }

    private static func openContainingApp(requestID: UUID) async throws {
        // Resolve the containing bundle, not a possibly different installed version's URL handler.
        let appURL = Bundle.main.bundleURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard appURL.pathExtension == "app",
            let url = URL(string: "macscp://share/" + requestID.uuidString)
        else { throw SharePreparationError.cannotOpenApp }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--share-import"]
        // The picker is the whole interaction; bring it forward instead of
        // leaving a floating panel behind an inactive app.
        configuration.activates = true
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open(
                [url], withApplicationAt: appURL, configuration: configuration
            ) { app, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if app == nil {
                    continuation.resume(throwing: SharePreparationError.cannotOpenApp)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

/// Cancellation may release a waiting load, but never a callback still writing its draft.
/// All continuation resumes and Progress cancellation happen outside the lock.
private final class ShareProviderLoadGate: @unchecked Sendable {
    private enum Phase { case waiting, copying, finished }

    let progress = Progress(totalUnitCount: 1)
    private let lock = NSLock()
    private var phase = Phase.waiting
    private var cancelled = false
    private var installed = false
    private var continuation: CheckedContinuation<String, Error>?
    private var pendingResult: Result<String, Error>?

    /// A cancellation handler may run before the operation installs its continuation.
    func install(_ continuation: CheckedContinuation<String, Error>) -> Bool {
        lock.lock()
        precondition(!installed)
        installed = true
        if let result = pendingResult {
            pendingResult = nil
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    /// Claim the callback before touching the draft; late/duplicate callbacks do nothing.
    func beginCopy() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .waiting, installed, !cancelled else { return false }
        phase = .copying
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let continuation: CheckedContinuation<String, Error>?
        if phase == .waiting {
            phase = .finished
            continuation = self.continuation
            self.continuation = nil
            if continuation == nil { pendingResult = .failure(CancellationError()) }
        } else {
            // A copying callback owns completion, so cleanup cannot overtake its writer.
            continuation = nil
        }
        lock.unlock()
        progress.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard phase == .copying else {
            lock.unlock()
            return
        }
        phase = .finished
        let continuation = self.continuation
        self.continuation = nil
        let completion: Result<String, Error> = cancelled ? .failure(CancellationError()) : result
        lock.unlock()
        continuation?.resume(with: completion)
    }
}

private enum SharePreparationError: LocalizedError {
    case invalidSelection, cannotOpenApp

    var errorDescription: String? {
        switch self {
        case .invalidSelection:
            return "Select between 1 and 1,000 files or folders in Finder and share again."
        case .cannotOpenApp:
            return "macSCP could not be opened. Keep the extension inside macSCP.app and try again."

        }
    }
}

@MainActor
private final class SharePreparationState: ObservableObject {
    @Published var message = "Preparing shared files…"
    @Published var error: String?
    @Published var isPreparing = true
}

private struct SharePreparationView: View {
    @ObservedObject var state: SharePreparationState
    let retry: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Label("Share to MacSCP", systemImage: "square.and.arrow.up")
                .font(.headline)
            if let error = state.error {
                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                ProgressView()
                Text(state.message)
                Text(
                    "Files are temporarily copied before opening the connection picker. Large folders need extra time and disk space."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                if state.error != nil { Button("Try Again", action: retry) }
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(width: 420)
    }
}
