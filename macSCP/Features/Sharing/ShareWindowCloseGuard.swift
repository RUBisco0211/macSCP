import AppKit

/// AppKit owns the share window so it does not depend on a SwiftUI main-window scene.
/// The panel is floating and explicitly activated. It intentionally does not pump an
/// app-modal session: splitting `runModalSession` across timer ticks breaks click
/// tracking and key-window focus inside the hosted SwiftUI views.
@MainActor
final class ShareWindowCloseGuard: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private let needsConfirmation: @MainActor () -> Bool
    private let beforeClose: @MainActor () async -> Void
    private let didClose: @MainActor () -> Void
    private var closeTask: Task<Void, Never>?
    private var hasClosed = false

    init(
        panel: NSPanel,
        needsConfirmation: @escaping @MainActor () -> Bool,
        beforeClose: @escaping @MainActor () async -> Void,
        didClose: @escaping @MainActor () -> Void
    ) {
        self.panel = panel
        self.needsConfirmation = needsConfirmation
        self.beforeClose = beforeClose
        self.didClose = didClose
        super.init()
        panel.delegate = self
    }

    func present() {
        guard !hasClosed else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        focus()
    }

    func focus() {
        guard !hasClosed else { return }
        // Do not steal key focus from a password/conflict/confirmation sheet.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeKey()
        panel.attachedSheet?.makeKeyAndOrderFront(nil)
        logInfo(
            "Share panel focus: visible=\(panel.isVisible) key=\(panel.isKeyWindow) main=\(panel.isMainWindow) canKey=\(panel.canBecomeKey) appActive=\(NSApp.isActive) level=\(panel.level.rawValue)",
            category: .ui)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { await close() }
        return false
    }

    /// All hosted-view and title-bar closes join the same teardown operation.
    func close() async {
        if let closeTask {
            await closeTask.value
            return
        }
        guard !hasClosed else { return }
        let task = Task { @MainActor in
            if needsConfirmation() {
                // Never replace an existing conflict or authentication sheet.
                guard panel.attachedSheet == nil else {
                    focus()
                    return
                }
                let alert = NSAlert()
                alert.messageText = String(localized: "Cancel transfers and close?")
                alert.informativeText = String(
                    localized:
                        "Transfers in this window will stop. Files already uploaded are not rolled back."
                )
                alert.addButton(withTitle: String(localized: "Keep Window Open"))
                alert.addButton(withTitle: String(localized: "Cancel Transfers and Close"))
                let response = await alert.beginSheetModal(for: panel)
                guard response == .alertSecondButtonReturn else { return }
            }
            await beforeClose()
            hasClosed = true
            panel.delegate = nil
            panel.close()
            didClose()
        }
        closeTask = task
        await task.value
        closeTask = nil
    }
}
