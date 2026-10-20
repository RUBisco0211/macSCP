import SwiftUI

/// The same source list is shown before choosing a host and before starting an upload.
struct SharedUploadPreview: View {
    let sources: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Files to Upload (\(sources.count))")
                .font(.subheadline.weight(.semibold))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(sources, id: \.self) { source in
                        let isDirectory =
                            (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
                            == true
                        HStack(spacing: 8) {
                            Image(systemName: isDirectory ? "folder.fill" : "doc")
                                .foregroundStyle(isDirectory ? Color.accentColor : Color.secondary)
                                .frame(width: 18)
                            Text(source.lastPathComponent)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(source.lastPathComponent)
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(10)
            }
            .frame(height: min(CGFloat(sources.count) * 26 + 12, 132))
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
