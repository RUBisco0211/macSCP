//
//  SSHConfigFilePicker.swift
//  macSCP
//
//  File selection for the ssh_config import.
//
//  The app never assumes a location: the user picks the file, and that choice is
//  the only input the importer uses.
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
        panel.message = "Select the ssh_config file to import."

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
