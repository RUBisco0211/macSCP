//
//  ClipboardItem.swift
//  macSCP
//
//  Domain model for clipboard operations (copy/cut/paste)
//

import Foundation

enum ClipboardOperation: String, Sendable {
    case copy
    case cut

    var displayName: String {
        switch self {
        case .copy: return String(localized: "Copy")
        case .cut: return String(localized: "Cut")
        }
    }

    var pastTense: String {
        switch self {
        case .copy: return String(localized: "Copied")
        case .cut: return String(localized: "Cut")
        }
    }

    var iconName: String {
        switch self {
        case .copy: return "doc.on.doc"
        case .cut: return "scissors"
        }
    }
}

struct ClipboardItem: Identifiable, Sendable {
    let id: UUID
    let file: RemoteFile
    let operation: ClipboardOperation
    let sourcePath: String
    let connectionId: UUID

    init(
        id: UUID = UUID(),
        file: RemoteFile,
        operation: ClipboardOperation,
        sourcePath: String,
        connectionId: UUID
    ) {
        self.id = id
        self.file = file
        self.operation = operation
        self.sourcePath = sourcePath
        self.connectionId = connectionId
    }

    var fileName: String {
        file.name
    }

    var isDirectory: Bool {
        file.isDirectory
    }

    var fullSourcePath: String {
        file.path
    }
}

// MARK: - Clipboard State
struct ClipboardState: Sendable {
    var items: [ClipboardItem]
    var operation: ClipboardOperation?

    init(items: [ClipboardItem] = [], operation: ClipboardOperation? = nil) {
        self.items = items
        self.operation = operation
    }

    var isEmpty: Bool {
        items.isEmpty
    }

    var isCopy: Bool {
        operation == .copy
    }

    var isCut: Bool {
        operation == .cut
    }

    var fileCount: Int {
        items.count
    }

    var displayText: String {
        guard !isEmpty, let op = operation else {
            return String(localized: "Clipboard empty")
        }

        if items.count == 1 {
            return String(localized: "\(op.pastTense): \(items[0].fileName)")
        }
        let itemsText = String(localized: "\(items.count) items")
        return String(localized: "\(op.pastTense): \(itemsText)")
    }

    var connectionId: UUID? {
        items.first?.connectionId
    }

    mutating func clear() {
        items = []
        operation = nil
    }
}
