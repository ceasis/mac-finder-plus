import SwiftUI

struct ArchiveBrowserPanelView: View {
    @Environment(AppState.self) private var appState
    @State private var store = ArchiveBrowserStore.shared

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            panelHeader
            Divider()

            panelContent

            Divider()
            actionBar
        }
    }

    @ViewBuilder
    private var panelContent: some View {
        if !store.hasArchive {
            noArchiveState
        } else if store.isLoading {
            ProgressView("Reading archive...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.errorMessage {
            ContentUnavailableView {
                Label(
                    "Can’t Browse Archive",
                    systemImage: "archivebox"
                )
            } description: {
                Text(error)
            } actions: {
                if let archive = store.archive {
                    Button("Try Again") {
                        store.open(archive)
                    }
                }
            }
        } else if store.entries.isEmpty {
            ContentUnavailableView("Empty Archive", systemImage: "archivebox")
        } else {
            VStack(spacing: 0) {
                navigationBar
                Divider()
                if store.visibleEntries.isEmpty {
                    ContentUnavailableView(
                        "No Matching Entries",
                        systemImage: "magnifyingglass",
                        description: Text("Clear the archive search to show all entries.")
                    )
                } else {
                    ArchiveEntryList(
                        entries: store.visibleEntries,
                        selectedEntryID: Binding(
                            get: { store.selectedEntryID },
                            set: { store.selectedEntryID = $0 }
                        ),
                        openSelectedFolder: {
                            store.openSelectedFolder()
                        }
                    )
                }
            }
        }
    }

    private var noArchiveState: some View {
        ContentUnavailableView {
            Label("No Archive Selected", systemImage: "archivebox")
        } description: {
            Text("Select an archive in the active pane, then browse it here.")
        } actions: {
            Button("Browse Selection") {
                appState.browseArchive()
            }
            .disabled(!appState.activePane.selectedItems.contains(where: \.isArchive))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var panelHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "archivebox")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 28, height: 28)
                .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text(store.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(headerDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            PanelIconButton(systemName: "sidebar.right", help: "Hide Archive Browser") {
                appState.hideArchiveBrowser()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var headerDetail: String {
        if !store.hasArchive { return "Ready to inspect archives" }
        if store.isLoading { return "Reading archive..." }
        return "\(store.fileCount) files · \(store.folderCount) folders"
    }

    private var navigationBar: some View {
        @Bindable var store = store

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    store.goUp()
                } label: {
                    Image(systemName: "chevron.up")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .disabled(store.currentPath.isEmpty)
                .help("Enclosing folder")

                Button {
                    store.revealRoot()
                } label: {
                    Image(systemName: "archivebox")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .help("Archive root")

                Text(store.currentPath.isEmpty ? "/" : store.currentPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()
            }

            TextField("Search archive", text: $store.searchText)
                .textFieldStyle(.roundedBorder)
        }
        .padding(12)
    }

    private var actionBar: some View {
        AdaptiveActionBar {
            Button {
                appState.extractArchiveBrowserSelection()
            } label: {
                Label(store.isZipArchive ? "Extract Selection" : "Extract Archive", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canExtract)

            Button {
                if let url = store.archiveURL {
                    appState.revealInFinder([url])
                }
            } label: {
                Label("Reveal Archive", systemImage: "arrow.up.right.square")
            }
            .disabled(store.archiveURL == nil)
        } trailing: {
            if let extractionDetail {
                Text(extractionDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
    }

    private var canExtract: Bool {
        guard store.archiveURL != nil, !store.isLoading, store.errorMessage == nil else { return false }
        if store.isZipArchive {
            return !store.selectedFilePathsForZipExtraction.isEmpty
        }
        return store.hasArchive
    }

    private var extractionDetail: String? {
        guard store.hasArchive else { return nil }
        if store.isZipArchive {
            let count = store.selectedFilePathsForZipExtraction.count
            guard count > 0 else { return "Select an entry to extract" }
            return "\(count) file\(count == 1 ? "" : "s")"
        }
        return "Full archive"
    }
}

private struct ArchiveEntryList: View {
    let entries: [ArchiveBrowserEntry]
    @Binding var selectedEntryID: ArchiveBrowserEntry.ID?
    let openSelectedFolder: () -> Void

    var body: some View {
        List(selection: $selectedEntryID) {
            ForEach(entries) { entry in
                ArchiveEntryRow(entry: entry)
                    .tag(entry.id)
                    .onTapGesture(count: 2) {
                        if entry.isDirectory {
                            selectedEntryID = entry.id
                            openSelectedFolder()
                        }
                    }
            }
        }
        .listStyle(.inset)
    }
}

private struct ArchiveEntryRow: View {
    let entry: ArchiveBrowserEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder" : "doc")
                .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(1)
                if !entry.parentPath.isEmpty {
                    Text(entry.parentPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            if !entry.isDirectory {
                Text(entry.sizeText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
