import AppKit

/// A native app-modal picker. A pop-up button is the accessory so the alert keeps
/// its default layout, width and background; a table accessory is resized by
/// NSAlert and produces a custom-looking, inconsistent dialog.
@MainActor
enum ShareConnectionPicker {
    static func run(connections: [Connection]) -> Connection? {
        guard !connections.isEmpty else { return nil }

        let popup = NSPopUpButton(
            frame: NSRect(x: 0, y: 0, width: 300, height: 25), pullsDown: false)
        popup.controlSize = .regular
        popup.addItems(
            withTitles: connections.map {
                "\($0.name) — \($0.connectionType.displayName) · \($0.connectionString)"
            })
        popup.selectItem(at: 0)

        let alert = NSAlert()
        alert.messageText = "Destination Connection"
        alert.accessoryView = popup
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = popup

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let index = popup.indexOfSelectedItem
        guard index >= 0, index < connections.count else { return nil }
        return connections[index]
    }
}

@MainActor
enum ShareAlert {
    static func run(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

@MainActor
enum SharePasswordPrompt {
    static func run(title: String, message: String, placeholder: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue
        return value.isEmpty ? nil : value
    }
}
