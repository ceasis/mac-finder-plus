import AppKit
import SwiftUI

struct DropStackPanelView: View {
    @Environment(AppState.self) private var appState
    @State private var store = DropStackStore.shared
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            panelHeader
            Divider()

            if store.items.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    if store.missingCount > 0 {
                        missingBanner
                    }
                    List(selection: $store.selection) {
                        ForEach(store.items) { item in
                            DropStackRow(item: item)
                                .tag(item.id)
                                .contextMenu {
                                    Button("Reveal in Finder") {
                                        appState.revealInFinder([item.url])
                                    }
                                    Button("Copy Path") {
                                        ClipboardHistoryStore.shared.copyPaths([item.path])
                                    }
                                    Divider()
                                    Button("Remove from Drop Stack") {
                                        store.remove(item)
                                    }
                                }
                        }
                    }
                    .listStyle(.inset)
                }
            }

            Divider()
            actionBar
        }
        .dropDestination(for: URL.self) { urls, _ in
            appState.addURLsToDropStack(urls)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .onDrop(of: [AppState.internalFileDragType], isTargeted: $isDropTargeted) { _ in
            let urls = appState.consumeCurrentFileDragURLs()
            appState.addURLsToDropStack(urls)
            return !urls.isEmpty
        }
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(isDropTargeted ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 2)
        )
    }

    private var panelHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.full")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 28, height: 28)
                .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text("Drop Stack")
                    .font(.headline)
                Text("\(store.existingItems.count) ready · collect files from any pane")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            PanelIconButton(systemName: "sidebar.right", help: "Hide Drop Stack") {
                appState.hideDropStack()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Files in Drop Stack", systemImage: "tray")
        } description: {
            Text("Drag files here or add the active selection before copying, moving, or running a workflow.")
        } actions: {
            Button("Add Selection") {
                appState.addSelectionToDropStack()
            }
            .help(appState.addSelectionToDropStackUnavailableReason ?? "Add the active selection")
            .disabled(!appState.canAddSelectionToDropStack)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var missingBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("\(store.missingCount) item\(store.missingCount == 1 ? "" : "s") no longer exist.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Remove Missing") {
                store.removeMissing()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            AdaptiveActionBar {
                Button {
                    appState.addSelectionToDropStack()
                } label: {
                    Label("Add Selection", systemImage: "plus")
                }
                .help(appState.addSelectionToDropStackUnavailableReason ?? "Add the active selection")
                .disabled(!appState.canAddSelectionToDropStack)

                Button {
                    appState.revealDropStackSelection()
                } label: {
                    Label("Reveal", systemImage: "arrow.up.right.square")
                }
                .help(store.selectedURLs.isEmpty ? "Add files to the drop stack first" : "Reveal selected drop stack files")
                .disabled(store.selectedURLs.isEmpty)
            } trailing: {
                Button(role: .destructive) {
                    if store.selection.isEmpty {
                        store.clear()
                    } else {
                        store.remove(store.selection)
                    }
                } label: {
                    Label(store.selection.isEmpty ? "Clear" : "Remove", systemImage: "trash")
                }
                .help(store.items.isEmpty ? "Add files to the drop stack first" : "Remove drop stack items")
                .disabled(store.items.isEmpty)
            }

            ViewThatFits(in: .horizontal) {
                dropStackTransferButtons
                VStack(alignment: .leading, spacing: 8) {
                    dropStackTransferButtons
                }
            }
        }
        .padding(12)
    }

    private var dropStackTransferButtons: some View {
        HStack(spacing: 8) {
            Button {
                appState.transferDropStackToOtherPane(move: false)
            } label: {
                Label("Copy to Other Pane", systemImage: "doc.on.doc")
            }
            .help(appState.dropStackTransferUnavailableReason ?? "Copy drop stack files to the inactive pane")
            .disabled(!appState.canTransferDropStackToOtherPane)

            Button {
                appState.transferDropStackToOtherPane(move: true)
            } label: {
                Label("Move", systemImage: "arrow.right.doc.on.clipboard")
            }
            .help(appState.dropStackTransferUnavailableReason ?? "Move drop stack files to the inactive pane")
            .disabled(!appState.canTransferDropStackToOtherPane)

            Menu {
                Button("Copy to Active Folder") {
                    appState.transferDropStackToActiveFolder(move: false)
                }
                Button("Move to Active Folder") {
                    appState.transferDropStackToActiveFolder(move: true)
                }
                Divider()
                ForEach(SavedWorkflowStore.shared.workflows) { workflow in
                    Button("Run \(workflow.name)") {
                        appState.runWorkflow(workflow, source: .dropStack)
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help(store.selectedURLs.isEmpty ? "Add files to the drop stack first" : "More drop stack actions")
            .disabled(store.selectedURLs.isEmpty)
        }
    }

}

private struct DropStackRow: View {
    @Environment(AppState.self) private var appState
    let item: DropStackItem

    @ViewBuilder
    var body: some View {
        if item.exists {
            rowContent
                .onDrag {
                    appState.dropStackDragProvider(for: item)
                }
                .draggableCursor()
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            if let fileItem = item.fileItem {
                Image(nsImage: fileItem.icon)
                    .resizable()
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "questionmark.square.dashed")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                Text(item.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if let fileItem = item.fileItem {
                Text(fileItem.sizeText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("Missing")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
