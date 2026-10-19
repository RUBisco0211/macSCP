//
//  SSHConfigFilePicker.swift
//  macSCP
//
//  Sandbox-friendly file selection for the ssh config import.
//
//  The app is sandboxed, so `~/.ssh/config` can only be read after the user
//  explicitly picks it. The panel navigates straight to `~/.ssh` to keep that
//  one click short.
//

import AppKit
import Foundation

@MainActor
enum SSHConfigFilePicker {
    static func pickConfigFile() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Select the ssh config file to import."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
