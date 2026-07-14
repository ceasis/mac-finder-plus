import AppKit
import SwiftUI

struct ClipboardHistoryColumnView: View {
    @Environment(AppState.self) private var appState
    @State private var store = ClipboardHistoryStore.shared

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            header
            searchField
            Divider()
            entriesList(selection: $store.selectedEntryID)
            Divider()
            selectedEntryPanel
        }
        .frame(minWidth: 250, idealWidth: 290, maxWidth: 360)
        .background(.bar)
        .onAppear {
            store.captureCurrentPasteboard(reportError: false)
            store.ensureSelection()
        }
        .alert("Clipboard Error", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Clipboard", systemImage: "clipboard")
                .font(.headline)

            Spacer()

            PanelIconButton(systemName: "plus.square.on.square", help: "Save current clipboard") {
                store.captureCurrentPasteboard()
                store.ensureSelection()
            }

            PanelIconButton(systemName: "xmark", help: "Hide clipboard history") {
                appState.hideClipboardHistory()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var searchField: some View {
        @Bindable var store = store
        return HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $store.searchText)
                .textFieldStyle(.plain)
            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func entriesList(
        selection: Binding<ClipboardHistoryEntry.ID?>
    ) -> some View {
        Group {
            if store.filteredEntries.isEmpty {
                ContentUnavailableView("No Items", systemImage: "clipboard")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: selection) {
                    ForEach(store.filteredEntries) { entry in
                        ClipboardHistoryRow(entry: entry)
                            .tag(entry.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minHeight: 180)
    }

    private var selectedEntryPanel: some View {
        Group {
            if let entry = store.entry(for: store.selectedEntryID) {
                ClipboardHistorySelectedEntryView(entry: entry, store: store)
            } else {
                ContentUnavailableView("No Selection", systemImage: "clipboard")
                    .frame(height: 160)
            }
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )
    }
}

struct ClipboardHistoryPanelView: View {
    var body: some View {
        ClipboardHistoryColumnView()
            .frame(width: 320, height: 560)
    }
}

private struct ClipboardHistoryRow: View {
    let entry: ClipboardHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: entry.kind.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(entry.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("\(entry.itemCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text(entryPreview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }

    private var entryPreview: String {
        entry.detailText
            .replacingOccurrences(of: "\n", with: "  ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ClipboardHistorySelectedEntryView: View {
    @Environment(AppState.self) private var appState

    let entry: ClipboardHistoryEntry
    let store: ClipboardHistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(entry.kind.title, systemImage: entry.kind.systemImage)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                Button {
                    store.restoreToPasteboard(entry)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy item to clipboard")
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())

                Button(role: .destructive) {
                    store.deleteEntry(entry.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Delete item")
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
            }

            preview

            if entry.kind == .files {
                fileActions
            } else {
                textActions
            }
        }
        .padding(10)
        .frame(minHeight: 170)
    }

    private var preview: some View {
        Group {
            if entry.kind == .files {
                filePreview
            } else {
                textPreview
            }
        }
        .frame(maxHeight: 150)
    }

    private var filePreview: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(entry.paths, id: \.self) { path in
                    ClipboardFilePreviewRow(path: path)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var textPreview: some View {
        ScrollView {
            Text(entry.detailText)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 6))
    }

    private var fileActions: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(appState.activePane.currentURL.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                Button {
                    appState.pasteClipboardHistoryFiles(entry, move: false)
                } label: {
                    Label("Copy Here", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .disabled(entry.existingFileURLs.isEmpty)
                .help("Copy selected clipboard files into the active folder")

                Button {
                    appState.pasteClipboardHistoryFiles(entry, move: true)
                } label: {
                    Label("Move Here", systemImage: "arrow.right.doc.on.clipboard")
                }
                .disabled(entry.existingFileURLs.isEmpty)
                .help("Move selected clipboard files into the active folder")
            }

            Button {
                store.reveal(entry)
            } label: {
                Label("Reveal", systemImage: "folder")
            }
            .buttonStyle(.plain)
            .disabled(entry.existingFileURLs.isEmpty)
            .help("Reveal files in Finder")
        }
    }

    private var textActions: some View {
        HStack(spacing: 8) {
            Button {
                store.restoreToPasteboard(entry)
            } label: {
                Label("Copy Text", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            .help("Copy selected text to clipboard")

            if let url = entry.webURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open URL", systemImage: "safari")
                }
                .buttonStyle(.bordered)
                .help("Open the link in your default browser")
            }
        }
    }
}

private struct ClipboardFilePreviewRow: View {
    let path: String

    var body: some View {
        let url = URL(fileURLWithPath: path)
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if !FileManager.default.fileExists(atPath: path) {
                Text("Missing")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
