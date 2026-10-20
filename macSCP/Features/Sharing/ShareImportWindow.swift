import SwiftUI

/// Destination browser window. Connection selection happens in a separate native alert.
struct ShareImportWindow: View {
    let session: ShareImportSession
    let close: @MainActor () async -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let error = session.preparationError {
                ContentUnavailableView {
                    Label("Unable to Open Shared Files", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Close") { Task { await close() } }
                }
            } else if let browser = session.browser {
                FileBrowserView(
                    viewModel: browser,
                    pendingUploadSources: session.sources,
                    onUploadFinished: { session.uploadFinished() },
                    onCancelPendingUpload: { await close() },
                    disconnectOnDisappear: false
                )
            } else {
                LoadingView(message: "Connecting…")
            }
            if let notice = session.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .disabled(session.isClosing)
        .overlay {
            if session.isClosing { LoadingView(message: "Stopping transfers and cleaning up…") }
        }
    }
}
