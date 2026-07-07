import SwiftUI

/// The right-click menu for file items, shared by the list and icon views.
/// Empty `ids` means the click landed on the background.
struct FileItemContextMenu: View {
    @Environment(AppState.self) private var appState
    let ids: Set<FileItem.ID>
    let model: PaneModel
    let paneIndex: Int

    var body: some View {
        let items = resolvedMenuItems
        if ids.isEmpty {
            Button("New Folder") {
                activate()
                appState.showNewFolderPrompt = true
            }
            Button("New Text File") {
                activate()
                appState.showNewFilePrompt = true
            }
            if appState.canPasteFilesFromClipboard {
                Divider()
                Button("Paste Item") {
                    activate()
                    appState.pasteClipboardFiles(to: model.currentURL, move: false)
                }
            }
            Divider()
            Button("Open in Terminal") {
                activate()
                appState.openTerminal(at: model.currentURL)
            }
            Button("Refresh") { model.refresh() }
        } else {
            Button("Open") {
                activate()
                model.open(ids)
            }
            if ids.count == 1, let item = items.first, !item.isDirectory {
                Button("Edit in Text Editor") {
                    activate()
                    appState.beginEditText(ids)
                }
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
            if items.contains(where: \.isImage) {
                Button("Annotate Image…") {
                    activate()
                    appState.beginAnnotateImage(ids)
                }
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
            if items.contains(where: MediaConverter.canConvert) {
                Button("Convert…") {
                    activate()
                    appState.beginConvert(ids)
                }
            }
            if items.filter(\.isImage).count >= 2 {
                Button("Combine into Slideshow…") {
                    activate()
                    appState.beginSlideshow(ids)
                }
            }
            if ids.count == 1, let item = items.first {
                Button("Rename…") { appState.renameTarget = item }
                if item.isZipArchive {
                    Button("Extract") {
                        activate()
                        appState.extractArchive(ids)
                    }
                }
                if item.isDirectory {
                    Button("Calculate Size") { model.calculateSizes(ids) }
                    if appState.canPasteFilesFromClipboard {
                        Divider()
                        Button("Move files here") {
                            activate()
                            appState.pasteClipboardFiles(to: item.url, move: true)
                        }
                        Button("Copy files here") {
                            activate()
                            appState.pasteClipboardFiles(to: item.url, move: false)
                        }
                    }
                }
            }
            Divider()
            Button("Copy Files") {
                activate()
                appState.copyFilesOfSelection(ids)
            }
            Button("Copy Path") {
                activate()
                appState.copyPathOfSelection(ids)
            }
            Button("Copy Names As Text") {
                activate()
                appState.copyNamesOfSelection(ids)
            }
            Button("Show Clipboard History") {
                activate()
                appState.showClipboardHistory()
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
        if !ids.isEmpty {
            model.selection = ids
        }
    }

    private var resolvedMenuItems: [FileItem] {
        let visible = model.visibleSource.filter { ids.contains($0.id) }
        let visibleIDs = Set(visible.map(\.id))
        let missing = ids.subtracting(visibleIDs).compactMap(PaneModel.itemIfReachable)
        return visible + missing
    }
}
