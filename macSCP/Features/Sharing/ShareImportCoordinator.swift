import AppKit
import SwiftData
import SwiftUI

/// The URL contains only a request ID, never a path supplied by another app.
enum ShareImportURL {
    static func requestID(from url: URL) -> UUID? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme == "macscp", parts.host == "share",
            parts.user == nil, parts.password == nil, parts.port == nil,
            parts.query == nil, parts.fragment == nil
        else { return nil }
        let path = parts.percentEncodedPath
        guard path.first == "/", path.count == 37,
            let id = UUID(uuidString: String(path.dropFirst())),
            path.dropFirst().lowercased() == id.uuidString.lowercased()
        else { return nil }
        return id
    }
}

/// Two separate windows: a native app-modal connection picker, then a floating
/// destination browser that owns preview, transfer controls and conflict prompts.
@MainActor
final class ShareImportCoordinator {
    static let shared = ShareImportCoordinator()

    private var isReady = false
    private var pendingIDs: [UUID] = []
    private var finishedIDs: Set<UUID> = []
    private var activeID: UUID?
    private var window: ShareWindowCloseGuard?

    func applicationDidFinishLaunching() {
        isReady = true
        presentNextIfNeeded()
    }

    func receive(_ url: URL) {
        guard let id = ShareImportURL.requestID(from: url), !finishedIDs.contains(id) else {
            return
        }
        if activeID == id || pendingIDs.contains(id) {
            focusActiveWindow()
            return
        }
        pendingIDs.append(id)
        if activeID != nil {
            focusActiveWindow()
        } else {
            presentNextIfNeeded()
        }
    }

    @discardableResult
    func focusActiveWindow() -> Bool {
        guard let window else { return false }
        window.present()
        return true
    }

    /// Only used for a share-initiated launch, where any other window was restored
    /// state rather than something the user opened in this session. Never close
    /// app-modal alerts or sheets.
    func dismissRestoredWindows() {
        guard ShareApplicationDelegate.isShareImportLaunch else { return }
        let sharePanel = window?.panel
        for candidate in NSApp.windows where candidate !== sharePanel {
            guard candidate.isVisible, candidate.canBecomeMain else { continue }
            if candidate.level.rawValue > NSWindow.Level.normal.rawValue { continue }
            if NSApp.modalWindow != nil { continue }
            if candidate.sheetParent != nil { continue }
            candidate.close()
        }
    }

    // MARK: - Request flow

    private func presentNextIfNeeded() {
        guard isReady, activeID == nil, !pendingIDs.isEmpty else { return }
        let id = pendingIDs.removeFirst()
        activeID = id
        Task { @MainActor [weak self] in await self?.begin(id) }
    }

    private func begin(_ id: UUID) async {
        let session = ShareImportSession(id: id)
        guard session.canPrepareBrowser else {
            presentWindow(for: session, id: id)
            return
        }
        guard
            let connections = try? await DependencyContainer.shared.connectionRepository.fetchAll(),
            !connections.isEmpty
        else {
            ShareAlert.run(
                title: String(localized: "No Saved Connections"),
                message: String(
                    localized: "Create a connection in macSCP, then share the files again."))
            await abort(session, id: id)
            return
        }

        guard let connection = ShareConnectionPicker.run(connections: sorted(connections)) else {
            await abort(session, id: id)
            return
        }
        guard await AppLockManager.shared.authenticateForConnection() else {
            await abort(session, id: id)
            return
        }
        guard let secret = resolveSecret(for: connection) else {
            await abort(session, id: id)
            return
        }

        session.prepareBrowser(connection: connection, secret: secret)
        presentWindow(for: session, id: id)
    }

    private func resolveSecret(for connection: Connection) -> String? {
        let keychain = DependencyContainer.shared.keychainService
        switch connection.connectionType {
        case .s3:
            if let credentials = keychain.getS3Credentials(for: connection.id) {
                return credentials.secretAccessKey
            }
            return SharePasswordPrompt.run(
                title: String(localized: "S3 Credentials"),
                message: String(localized: "Enter the secret access key for “\(connection.name)”."),
                placeholder: String(localized: "Secret Access Key"))
        case .sftp:
            if let password = keychain.getPassword(for: connection.id) { return password }
            if connection.authMethod == .privateKey { return "" }
            return SharePasswordPrompt.run(
                title: String(localized: "Password"),
                message: String(localized: "Enter the password for “\(connection.name)”."),
                placeholder: String(localized: "Password"))
        }
    }

    private func sorted(_ connections: [Connection]) -> [Connection] {
        connections.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func abort(_ session: ShareImportSession, id: UUID) async {
        await session.close()
        finish(id)
    }

    private func finish(_ id: UUID) {
        guard activeID == id else { return }
        finishedIDs.insert(id)
        activeID = nil
        window = nil
        presentNextIfNeeded()
    }

    private func presentWindow(for session: ShareImportSession, id: UUID) {
        let panel = SharePanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        panel.title = String(localized: "Share to macSCP")
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.minSize = NSSize(width: 600, height: 400)
        panel.contentViewController = NSHostingController(
            rootView: ShareImportWindow(
                session: session,
                close: { await ShareImportCoordinator.shared.close(id) }
            )
            .appLockOverlay()
            .modelContainer(DependencyContainer.shared.modelContainer)
        )
        panel.center()

        let owner = ShareWindowCloseGuard(
            panel: panel,
            needsConfirmation: {
                session.browser?.isUploadingBatch == true
                    || session.browser?.hasActiveTransfers == true
            },
            beforeClose: { await session.close() },
            didClose: { [weak self] in self?.finish(id) }
        )
        window = owner
        owner.present()
        // Activation can land after the panel is ordered front during a cold launch.
        // The picker and destination window are the only UI for a share launch.
    }

    private func close(_ id: UUID) async {
        guard activeID == id, let window else { return }
        await window.close()
    }
}

/// A share panel must always accept key status: input from a floating panel is
/// dropped when the app was launched in the background.
final class SharePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
