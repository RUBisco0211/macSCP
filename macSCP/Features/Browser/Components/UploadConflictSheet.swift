import SwiftUI

struct UploadConflictSheet: View {
    let conflict: UploadConflict
    let onDecision: (UploadConflictDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(
                conflict.destinationIsDirectory ? "Folder Already Exists" : "File Already Exists",
                systemImage: conflict.destinationIsDirectory
                    ? "folder.badge.questionmark" : "doc.badge.ellipsis"
            )
            .font(.headline)

            Text(conflict.localURL.lastPathComponent)
                .font(.body.weight(.semibold))
                .textSelection(.enabled)
            Text(conflict.remotePath)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if conflict.destinationIsDirectory {
                Text("Overwrite replaces the existing folder and its contents.")
                    .font(.callout)
            }

            HStack(spacing: 10) {
                Button("Cancel") { onDecision(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Skip") { onDecision(.skip) }
                    .keyboardShortcut(.defaultAction)
                if conflict.sourceIsDirectory && conflict.destinationIsDirectory {
                    Button("Merge") { onDecision(.merge) }
                }
                Button("Overwrite", role: .destructive) { onDecision(.overwrite) }
            }
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }
}
