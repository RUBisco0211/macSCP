//
//  MacSCPApp.swift
//  macSCP
//
//  Main application entry point
//

import Sparkle
import SwiftData
import SwiftUI

@main
struct MacSCPApp: App {
    @NSApplicationDelegateAdaptor(ShareApplicationDelegate.self) private var applicationDelegate
    @StateObject private var container = DependencyContainer.shared

    private let updaterController: SPUStandardUpdaterController
    @StateObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel

    init() {
        do {
            try ShareRequestStore.appStore().removeExpiredRequests()
        } catch {
            logError(
                "Share staging cleanup unavailable: \(error.localizedDescription)", category: .app)
        }
        AnalyticsService.initialize()
        AppLockManager.shared.lockIfNeeded()

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.updaterController = controller
        self._checkForUpdatesViewModel = StateObject(
            wrappedValue: CheckForUpdatesViewModel(updater: controller.updater)
        )
    }

    var body: some Scene {
        // Main Window - Connection List
        WindowGroup {
            ConnectionListView(viewModel: container.makeConnectionListViewModel())
                .appLockOverlay()
        }
        .modelContainer(container.modelContainer)
        .defaultSize(WindowSize.main)
        .defaultLaunchBehavior(
            ShareApplicationDelegate.isShareImportLaunch ? .suppressed : .automatic
        )
        .restorationBehavior(
            ShareApplicationDelegate.isShareImportLaunch ? .disabled : .automatic
        )
        .commands {
            appCommands
        }

        // File Browser Window
        WindowGroup(id: WindowID.fileBrowser, for: String.self) { $windowId in
            if let windowId = windowId {
                FileBrowserWindow(windowId: windowId)
                    .appLockOverlay()
            }
        }
        .modelContainer(container.modelContainer)
        .defaultSize(WindowSize.fileBrowser)
        .restorationBehavior(
            ShareApplicationDelegate.isShareImportLaunch ? .disabled : .automatic
        )

        // File Editor Window
        WindowGroup(id: WindowID.fileEditor, for: String.self) { $windowId in
            if let windowId = windowId {
                FileEditorWindow(windowId: windowId)
                    .appLockOverlay()
            }
        }
        .modelContainer(container.modelContainer)
        .defaultSize(WindowSize.fileEditor)
        .restorationBehavior(
            ShareApplicationDelegate.isShareImportLaunch ? .disabled : .automatic
        )

        // File Info Window
        WindowGroup(id: WindowID.fileInfo, for: String.self) { $windowId in
            if let windowId = windowId {
                FileInfoWindow(windowId: windowId)
                    .appLockOverlay()
            }
        }
        .modelContainer(container.modelContainer)
        .defaultSize(WindowSize.fileInfo)
        .windowResizability(.contentSize)
        .restorationBehavior(
            ShareApplicationDelegate.isShareImportLaunch ? .disabled : .automatic
        )

        // Terminal Window
        WindowGroup(id: WindowID.terminal, for: String.self) { $windowId in
            if let windowId = windowId {
                TerminalWindow(windowId: windowId)
                    .appLockOverlay()
            }
        }
        .modelContainer(container.modelContainer)
        .defaultSize(WindowSize.terminal)
        .restorationBehavior(
            ShareApplicationDelegate.isShareImportLaunch ? .disabled : .automatic
        )

        // Settings Window (Cmd+,)
        Settings {
            SettingsView()
                .appLockOverlay()
        }
    }

    // MARK: - Commands
    @CommandsBuilder
    private var appCommands: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesView(viewModel: checkForUpdatesViewModel)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Connection") {
                // Handled by main window
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Folder") {
                // Handled by main window
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(after: .toolbar) {
            Button("Refresh") {
                // Handled by active window
            }
            .keyboardShortcut("r", modifiers: .command)
        }

        CommandGroup(replacing: .help) {
            Button("Report a Bug…") {
                if let url = URL(string: "https://github.com/macnev2013/macSCP/issues") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
