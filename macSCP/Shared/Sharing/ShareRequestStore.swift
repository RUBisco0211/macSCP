import Foundation

struct ShareRequest: Sendable {
    let id: UUID
    let sources: [URL]
    let createdAt: Date
}

/// Only staged payloads cross the process seam; no credentials or arbitrary paths do.
struct ShareRequestStore: Sendable {
    private struct Manifest: Codable {
        let version: Int
        let id: UUID
        let names: [String]
        let createdAt: Date
    }

    struct Draft: Sendable {
        let id: UUID
        let directory: URL
    }

    enum StoreError: LocalizedError {
        case invalidRequest
        case unsupportedSource(String)
        case duplicateName(String)

        var errorDescription: String? {
            switch self {
            case .invalidRequest:
                return "The shared request is invalid or has expired. Please share the files again."
            case .unsupportedSource(let name):
                return "Symbolic links and special files are not supported: \(name)"
            case .duplicateName(let name):
                return "Two selected items have the same name: \(name). Share them separately."
            }
        }
    }

    let root: URL

    init(root: URL) {
        self.root = root
    }

    static let extensionBundleIdentifier = "com.macscp.macSCP.ShareExtension"

    /// The extension stages into its own sandbox container. This needs no app group,
    /// so ad-hoc signed builds work and existing app data is untouched.
    static func extensionStore() -> ShareRequestStore {
        ShareRequestStore(
            root: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Documents/ShareRequests", isDirectory: true))
    }

    /// The containing app is not sandboxed, so it can read the extension's
    /// container directly instead of requiring a shared app-group container.
    static func appStore() -> ShareRequestStore {
        ShareRequestStore(
            root: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers", isDirectory: true)
                .appendingPathComponent(extensionBundleIdentifier, isDirectory: true)
                .appendingPathComponent("Data/Documents/ShareRequests", isDirectory: true))
    }

    static func load(id: UUID) throws -> ShareRequest { try appStore().load(id: id) }
    static func remove(id: UUID) throws { try appStore().remove(id: id) }

    func begin() throws -> Draft {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let directory = root.appendingPathComponent(
            ".preparing-" + id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("payload"), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return Draft(id: id, directory: directory)
    }

    /// Copies the item into the draft. Must run inside the item-provider callback:
    /// providers may hand out a temporary representation that is removed when the
    /// callback returns, so copying later would read a file that no longer exists.
    func stage(_ source: URL, index: Int, in draft: Draft, cancelled: () -> Bool) throws -> String {
        guard source.isFileURL, index >= 0, Self.validName(source.lastPathComponent) else {
            throw StoreError.invalidRequest
        }
        let name = source.lastPathComponent
        let parent = draft.directory.appendingPathComponent("payload/\(index)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        try copy(source, to: parent.appendingPathComponent(name), cancelled: cancelled)
        return name
    }

    func publish(_ draft: Draft, names: [String]) throws -> ShareRequest {
        guard !names.isEmpty, names.allSatisfy(Self.validName) else {
            throw StoreError.invalidRequest
        }
        var seen = Set<String>()
        for name in names {
            guard seen.insert(name).inserted else { throw StoreError.duplicateName(name) }
        }
        let manifest = Manifest(version: 1, id: draft.id, names: names, createdAt: Date())
        try JSONEncoder().encode(manifest).write(
            to: draft.directory.appendingPathComponent("request.json"), options: .atomic)
        try FileManager.default.moveItem(at: draft.directory, to: directory(for: draft.id))
        do {
            return try load(id: draft.id)
        } catch {
            try? remove(id: draft.id)
            throw error
        }
    }

    func discard(_ draft: Draft) throws {
        if FileManager.default.fileExists(atPath: draft.directory.path) {
            try FileManager.default.removeItem(at: draft.directory)
        }
    }

    func load(id: UUID) throws -> ShareRequest {
        let directory = directory(for: id)
        let expected = root.resolvingSymlinksInPath().appendingPathComponent(id.uuidString)
            .standardizedFileURL
        guard directory.resolvingSymlinksInPath().standardizedFileURL == expected else {
            throw StoreError.invalidRequest
        }
        let manifest = try JSONDecoder().decode(
            Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("request.json")))
        guard manifest.version == 1, manifest.id == id, !manifest.names.isEmpty,
            manifest.names.allSatisfy(Self.validName),
            Set(manifest.names).count == manifest.names.count
        else { throw StoreError.invalidRequest }
        let resolvedRoot = directory.resolvingSymlinksInPath().standardizedFileURL
        let sources = try manifest.names.enumerated().map { index, name in
            let source = directory.appendingPathComponent("payload/\(index)/\(name)")
            let resolved = source.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(resolvedRoot.path + "/payload/"),
                FileManager.default.fileExists(atPath: source.path)
            else { throw StoreError.invalidRequest }
            return source
        }
        return ShareRequest(id: id, sources: sources, createdAt: manifest.createdAt)
    }

    /// A freshly published request is the reliable cold-launch signal for a share:
    /// LaunchServices does not forward custom launch arguments to the URL handler.
    func hasRecentRequest(now: Date = Date(), within: TimeInterval = 30) -> Bool {
        guard
            let directories = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [])
        else { return false }
        return directories.contains { directory in
            guard UUID(uuidString: directory.lastPathComponent) != nil,
                let data = try? Data(
                    contentsOf: directory.appendingPathComponent("request.json")),
                let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
            else { return false }
            return abs(now.timeIntervalSince(manifest.createdAt)) <= within
        }
    }

    func remove(id: UUID) throws {
        let directory = directory(for: id)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// Called once at app startup, before any share session can own a payload.
    func removeExpiredRequests(now: Date = Date()) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        for directory in try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [])
        {
            let name = directory.lastPathComponent
            guard UUID(uuidString: name) != nil || name.hasPrefix(".preparing-") else { continue }
            let modified = try directory.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            if let modified, now.timeIntervalSince(modified) > 7 * 24 * 60 * 60 {
                try FileManager.default.removeItem(at: directory)
            }
        }
    }

    private func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private nonisolated static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    private func copy(_ source: URL, to destination: URL, cancelled: () -> Bool) throws {
        if cancelled() { throw CancellationError() }
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        switch attributes[.type] as? FileAttributeType {
        case .typeDirectory:
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: false)
            for child in try FileManager.default.contentsOfDirectory(
                at: source, includingPropertiesForKeys: nil, options: [])
            {
                try copy(
                    child, to: destination.appendingPathComponent(child.lastPathComponent),
                    cancelled: cancelled)
            }
        case .typeRegular:
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            while true {
                if cancelled() { throw CancellationError() }
                guard let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty else {
                    break
                }
                try output.write(contentsOf: data)
            }
        default:
            throw StoreError.unsupportedSource(source.lastPathComponent)
        }
    }
}
