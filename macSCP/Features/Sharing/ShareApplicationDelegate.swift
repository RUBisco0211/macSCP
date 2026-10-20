import AppKit
import Carbon

/// URL delivery must not depend on (or instantiate) a SwiftUI main-window scene.
@MainActor
final class ShareApplicationDelegate: NSObject, NSApplicationDelegate {
    static let isShareImportLaunch: Bool = {
        if ProcessInfo.processInfo.arguments.contains("--share-import") { return true }
        // LaunchServices drops custom launch arguments when opening a URL, so the
        // freshly published request is the dependable cold-launch signal.
        guard let store = try? ShareRequestStore.shared() else { return false }
        return store.hasRecentRequest()
    }()

    override init() {
        super.init()
        // Install as early as possible: the URL event can arrive before the
        // delegate callbacks are forwarded by SwiftUI.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ShareImportCoordinator.shared.applicationDidFinishLaunching()
    }

    /// AppleEvent is the dependable path; SwiftUI may consume `open urls` itself.
    @objc private func handleGetURLEvent(
        _ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        guard
            let value = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?
                .stringValue,
            let url = URL(string: value)
        else { return }
        ShareImportCoordinator.shared.receive(url)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            ShareImportCoordinator.shared.receive(url)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ShareImportCoordinator.shared.focusActiveWindow()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        // A Dock click while sharing focuses the modal panel, not a new main window.
        !ShareImportCoordinator.shared.focusActiveWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
