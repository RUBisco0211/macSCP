import Foundation

struct UploadConflict: Identifiable, Sendable {
    let id: UUID
    let localURL: URL
    let remotePath: String
    let sourceIsDirectory: Bool
    let destinationIsDirectory: Bool

    init(
        id: UUID = UUID(), localURL: URL, remotePath: String,
        sourceIsDirectory: Bool, destinationIsDirectory: Bool
    ) {
        self.id = id
        self.localURL = localURL
        self.remotePath = remotePath
        self.sourceIsDirectory = sourceIsDirectory
        self.destinationIsDirectory = destinationIsDirectory
    }
}

enum UploadConflictDecision: Sendable {
    case skip
    case overwrite
    case merge
    case cancel
}
