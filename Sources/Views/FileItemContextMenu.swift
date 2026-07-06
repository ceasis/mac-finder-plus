import SwiftUI

/// The right-click menu for file items, shared by the list and icon views.
/// Empty `ids` means the click landed on the background.
struct FileItemContextMenu: View {
    @Environment(AppState.self) private var appState
    let ids: Set<FileItem.ID>
    let model: PaneModel
    let paneIndex: Int

    var body: some View {
        if ids.isEmpty {
            Button("New Folder") { appState.showNewFolderPrompt = true }
            Button("Refresh") { model.refresh() }
        } else {
            Button("Open") {
                activate()
                model.open(ids)
            }
            Button("Quick Look") {
                activate()
                appState.quickLookSelection()
            }
            Divider()
            if appState.isDualPane {
                Button("Copy to Other Pane") {
                    activate()
                    appState.transferSelection(ids, move: false)
                }
                Button("Move to Other Pane") {
                    activate()
                    appState.transferSelection(ids, move: true)
                }
                Divider()
            }
            Button("Duplicate") {
                activate()
                appState.duplicateSelection(ids)
            }
            Button("Batch Rename…") {
                activate()
                appState.beginBatchRename(ids)
            }
            Menu("Rating") {
                Button("Clear Rating") {
                    activate()
                    appState.rateSelection(0, ids: ids)
                }
                Divider()
                ForEach(1...5, id: \.self) { rating in
                    Button("\(rating) Star\(rating == 1 ? "" : "s")") {
                        activate()
                        appState.rateSelection(rating, ids: ids)
                    }
                }
            }
            if model.visibleSource.contains(where: { ids.contains($0.id) && $0.isImage }) {
                Button("Resize Image…") {
                    activate()
                    appState.beginResize(ids)
                }
                Button("Export Contact Sheet PDF") {
                    activate()
                    appState.exportContactSheet(ids)
                }
                Menu("Rotate & Flip") {
                    Button("Rotate Left") {
                        activate()
                        appState.transformSelection(ids, operation: .rotateLeft)
                    }
                    Button("Rotate Right") {
                        activate()
                        appState.transformSelection(ids, operation: .rotateRight)
                    }
                    Divider()
                    Button("Flip Horizontal") {
                        activate()
                        appState.transformSelection(ids, operation: .flipHorizontal)
                    }
                    Button("Flip Vertical") {
                        activate()
                        appState.transformSelection(ids, operation: .flipVertical)
                    }
                }
            }
            if model.visibleSource.contains(where: { ids.contains($0.id) && MediaConverter.canConvert($0) }) {
                Button("Convert…") {
                    activate()
                    appState.beginConvert(ids)
                }
            }
            if model.visibleSource.filter({ ids.contains($0.id) && $0.isImage }).count >= 2 {
                Button("Combine into Slideshow…") {
                    activate()
                    appState.beginSlideshow(ids)
                }
            }
            if ids.count == 1, let item = model.visibleSource.first(where: { ids.contains($0.id) }) {
                Button("Rename…") { appState.renameTarget = item }
                if item.isZipArchive {
                    Button("Extract") {
                        activate()
                        appState.extractArchive(ids)
                    }
                }
                if item.isDirectory {
                    Button("Calculate Size") { model.calculateSizes(ids) }
                }
            }
            Divider()
            Button("Copy Path") {
                activate()
                appState.copyPathOfSelection(ids)
            }
            Button("Reveal in Finder") {
                activate()
                appState.revealSelectionInFinder(ids)
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                activate()
                appState.trashSelection(ids)
            }
        }
    }

    private func activate() {
        appState.activePaneIndex = paneIndex
    }
}
