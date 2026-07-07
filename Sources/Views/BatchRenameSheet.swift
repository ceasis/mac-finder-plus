import SwiftUI

struct BatchRenameSheet: View {
    @Environment(AppState.self) private var appState
    let targets: [FileItem]

    @State private var options = BatchRenameOptions(pattern: "Untitled-{date}-{seq}")
    @State private var previews: [BatchRenamePreviewItem] = []
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(targets.count == 1 ? "Batch Rename 1 Item" : "Batch Rename \(targets.count) Items")
                .font(.headline)

            HStack(spacing: 8) {
                TextField("Pattern", text: $options.pattern)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    tokenButton("{name}")
                    tokenButton("{date}")
                    tokenButton("{seq}")
                    tokenButton("{ext}")
                } label: {
                    Label("Token", systemImage: "curlybraces")
                }
                .menuStyle(.button)
                .help("Insert a rename token")
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Date")
                    TextField("yyyyMMdd", text: $options.dateFormat)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Start")
                    Stepper(value: $options.sequenceStart, in: 1...999_999) {
                        Text("\(options.sequenceStart)")
                            .monospacedDigit()
                    }
                }
                GridRow {
                    Text("Digits")
                    Stepper(value: $options.sequencePadding, in: 1...8) {
                        Text("\(options.sequencePadding)")
                            .monospacedDigit()
                    }
                }
            }

            Toggle("Keep Extensions", isOn: $options.preservesExtension)

            Divider()

            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(previews) { preview in
                                BatchRenamePreviewRow(preview: preview)
                                Divider()
                            }
                        }
                    }
                    .frame(minHeight: 180, maxHeight: 260)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    appState.showBatchRenameSheet = false
                }
                .keyboardShortcut(.cancelAction)
                .help("Cancel batch rename")
                Button("Rename") {
                    appState.performBatchRename(options: options)
                    appState.showBatchRenameSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(targets.isEmpty || options.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Rename selected files")
            }
        }
        .padding(20)
        .frame(width: 520)
        .task(id: options) { await reloadPreviews() }
        .onAppear {
            if targets.count == 1 {
                options.pattern = "{name}-{seq}"
            }
        }
    }

    private func tokenButton(_ token: String) -> some View {
        Button(token) {
            if !options.pattern.isEmpty, !options.pattern.hasSuffix("-") {
                options.pattern += "-"
            }
            options.pattern += token
        }
        .help("Insert \(token)")
    }

    @MainActor
    private func reloadPreviews() async {
        isLoading = true
        let loaded = await BatchRenameEngine.previews(for: targets, options: options)
        if !Task.isCancelled {
            previews = loaded
            isLoading = false
        }
    }
}

private struct BatchRenamePreviewRow: View {
    let preview: BatchRenamePreviewItem

    var body: some View {
        HStack(spacing: 10) {
            Text(preview.originalName)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            Text(preview.newName)
                .lineLimit(1)
                .truncationMode(.middle)
                .fontWeight(.medium)
            Spacer(minLength: 8)
            if let warning = preview.warning {
                Text(warning)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
    }
}
