import SwiftUI

struct MediaMetadataInspector: View {
    let item: FileItem

    @State private var metadata = MediaMetadata(sections: [])
    @State private var isLoading = false

    private var metadataKey: String {
        "\(item.id)|\(item.modified.timeIntervalSince1970)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Metadata", systemImage: "info.circle")
                    .font(.caption.weight(.semibold))
                Spacer()
            }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if metadata.isEmpty {
                EmptyView()
            } else {
                ForEach(metadata.sections) { section in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(section.title)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(section.rows) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(row.label)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 86, alignment: .leading)
                                Text(row.value)
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.caption)
                        }
                    }
                    if section.id != metadata.sections.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(10)
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .task(id: metadataKey) { await loadMetadata() }
    }

    @MainActor
    private func loadMetadata() async {
        isLoading = true
        metadata = await MediaMetadataReader.metadata(for: item)
        if !Task.isCancelled {
            isLoading = false
        }
    }
}
