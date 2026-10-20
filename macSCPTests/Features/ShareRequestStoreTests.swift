import XCTest

@testable import macSCP

@MainActor
final class ShareRequestStoreTests: XCTestCase {
    private func fixture() throws -> (URL, ShareRequestStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, ShareRequestStore(root: root.appendingPathComponent("requests")))
    }

    func testPublishPreservesNamesHiddenFilesAndEmptyDirectories() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: source.appendingPathComponent(".hidden"))
        let draft = try store.begin()
        let name = try store.stage(source, index: 0, in: draft, cancelled: { false })
        XCTAssertThrowsError(try store.load(id: draft.id))
        let request = try store.publish(draft, names: [name])
        XCTAssertEqual(request.id, draft.id)
        let staged = try XCTUnwrap(request.sources.first)
        XCTAssertEqual(staged.lastPathComponent, "Documents")
        XCTAssertEqual(
            try Data(contentsOf: staged.appendingPathComponent(".hidden")), Data("hello".utf8))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: staged.appendingPathComponent("empty").path))
        try FileManager.default.removeItem(at: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        try store.remove(id: request.id)
        XCTAssertThrowsError(try store.load(id: request.id))
    }

    func testCancelledPreparationCanBeDiscardedWithoutPublishing() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("file")
        try Data(repeating: 1, count: 16).write(to: source)
        let draft = try store.begin()
        XCTAssertThrowsError(try store.stage(source, index: 0, in: draft, cancelled: { true })) {
            error in
            XCTAssertTrue(error is CancellationError)
        }
        try store.discard(draft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.directory.path))
        XCTAssertThrowsError(try store.load(id: draft.id))
    }

    func testSymlinksAreRejected() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("file")
        try Data().write(to: source)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let draft = try store.begin()
        defer { try? store.discard(draft) }
        XCTAssertThrowsError(try store.stage(link, index: 0, in: draft, cancelled: { false }))
    }

    func testDuplicateNamesCannotBePublished() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = try store.begin()
        defer { try? store.discard(draft) }
        XCTAssertThrowsError(try store.publish(draft, names: ["same", "same"]))
        XCTAssertThrowsError(try store.publish(draft, names: ["../outside"]))
    }

    func testManifestCannotEscapePayload() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("file")
        try Data().write(to: source)
        let draft = try store.begin()
        let name = try store.stage(source, index: 0, in: draft, cancelled: { false })
        let request = try store.publish(draft, names: [name])
        let staged = try XCTUnwrap(request.sources.first)
        try FileManager.default.removeItem(at: staged)
        try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: source)
        XCTAssertThrowsError(try store.load(id: request.id))
    }

    func testExpiredPayloadsCleanedButFreshPayloadsRetained() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try store.begin()
        let fresh = try store.begin()
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -8 * 24 * 60 * 60)],
            ofItemAtPath: old.directory.path)
        try store.removeExpiredRequests()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.directory.path))
    }

    func testOnlyStrictShareURLsAreAccepted() throws {
        let id = UUID()
        XCTAssertEqual(
            ShareImportURL.requestID(from: URL(string: "macscp://share/" + id.uuidString)!), id)
        for address in [
            "macscp://share/../file", "macscp://share/" + id.uuidString + "/extra",
            "macscp://share/" + id.uuidString + "?path=/tmp/file",
            "macscp://share/" + id.uuidString + "#fragment",
            "https://share/" + id.uuidString, "macscp://other/" + id.uuidString,
            "macscp://user@share/" + id.uuidString, "macscp://share:80/" + id.uuidString,
        ] {
            XCTAssertNil(
                ShareImportURL.requestID(from: try XCTUnwrap(URL(string: address))), address)
        }
    }
}
