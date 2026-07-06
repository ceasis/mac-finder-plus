import AppKit
import SwiftUI

struct AppCommands: Commands {
    let appState: AppState

    private var f5: KeyEquivalent {
        KeyEquivalent(Character(UnicodeScalar(UInt16(NSF5FunctionKey))!))
    }
    private var f6: KeyEquivalent {
        KeyEquivalent(Character(UnicodeScalar(UInt16(NSF6FunctionKey))!))
    }

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(appState.undoFileOperationTitle) { appState.undoLastFileOperation() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!appState.canUndoFileOperation)
        }

        CommandGroup(after: .newItem) {
            Button("New Folder") { appState.showNewFolderPrompt = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Rename…") { appState.beginRenameSelection() }
            Button("Batch Rename…") { appState.beginBatchRename() }
            Button("Duplicate") { appState.duplicateSelection() }
                .keyboardShortcut("d", modifiers: .command)
            Button("Resize Images…") { appState.beginResize() }
            Button("Convert…") { appState.beginConvert() }
            Button("Combine into Slideshow…") { appState.beginSlideshow() }
            Button("Export Contact Sheet PDF") { appState.exportContactSheet() }
            Button("Notes…") { appState.showNotes() }
            Button("Screenshot…") { appState.beginScreenshot() }
                .keyboardShortcut("5", modifiers: [.command, .option])
            Menu("Rating") {
                Button("Clear Rating") { appState.rateSelection(0) }
                Divider()
                ForEach(1...5, id: \.self) { rating in
                    Button("\(rating) Star\(rating == 1 ? "" : "s")") {
                        appState.rateSelection(rating)
                    }
                }
            }
            Button("Rotate Left") { appState.transformSelection(operation: .rotateLeft) }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button("Rotate Right") { appState.transformSelection(operation: .rotateRight) }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Flip Horizontal") { appState.transformSelection(operation: .flipHorizontal) }
            Button("Flip Vertical") { appState.transformSelection(operation: .flipVertical) }
            Button("Find") { appState.searchFocusTick += 1 }
                .keyboardShortcut("f", modifiers: .command)
            Button("Move to Trash") { appState.trashSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
        }

        CommandGroup(after: .sidebar) {
            Divider()
            Button("as List") { appState.activePane.viewMode = .list }
                .keyboardShortcut("1", modifiers: .command)
            Button("as Icons") { appState.activePane.viewMode = .icons }
                .keyboardShortcut("2", modifiers: .command)
            Button("Toggle Dual Pane") { appState.toggleDualPane() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Toggle Hidden Files") { appState.showHidden.toggle() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Toggle("Auto Calculate Folder Sizes", isOn: Binding(
                get: { appState.autoCalculateFolderSizes },
                set: { appState.autoCalculateFolderSizes = $0 }
            ))
            Button("Toggle Preview Pane") { appState.showPreview.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Quick Look") { appState.quickLookSelection() }
                .keyboardShortcut("y", modifiers: .command)
            Button("Refresh") { appState.activePane.refresh() }
                .keyboardShortcut("r", modifiers: .command)
        }

        CommandMenu("Go") {
            Button("Back") { appState.activePane.goBack() }
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward") { appState.activePane.goForward() }
                .keyboardShortcut("]", modifiers: .command)
            Button("Enclosing Folder") { appState.activePane.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Open Selection") {
                appState.activePane.open(appState.activePane.selection)
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            Divider()
            Button("Home") { appState.goHome() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Go to Folder…") { appState.showGoToPrompt = true }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }

        CommandMenu("Pane") {
            Button("New Tab") { appState.newTabInActivePane() }
                .keyboardShortcut("t", modifiers: .command)
            Button("Close Tab") { appState.closeActiveTab() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(appState.activePane.tabs.count <= 1)
            Button("Previous Tab") { appState.selectPreviousTab() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(appState.activePane.tabs.count <= 1)
            Button("Next Tab") { appState.selectNextTab() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(appState.activePane.tabs.count <= 1)
            Divider()
            Button("Copy to Other Pane") { appState.transferSelection(move: false) }
                .keyboardShortcut(f5, modifiers: [])
            Button("Move to Other Pane") { appState.transferSelection(move: true) }
                .keyboardShortcut(f6, modifiers: [])
            Divider()
            Button("Compare Folders") { appState.compareFoldersAcrossPanes() }
                .disabled(!appState.isDualPane)
            Button("Clear Folder Compare") { appState.clearFolderCompare() }
            Menu("Sync Compared Folders") {
                Button("Left to Right") { appState.syncComparedFolders(.leftToRight) }
                Button("Right to Left") { appState.syncComparedFolders(.rightToLeft) }
            }
            .disabled(!appState.isDualPane)
            Divider()
            Button("Find Duplicates Across Panes") { appState.findDuplicatesAcrossPanes() }
                .disabled(!appState.isDualPane)
            Button("Clear Duplicate Results") { appState.clearDuplicateResults() }
            Divider()
            Button("Focus Other Pane") {
                if appState.isDualPane {
                    appState.activePaneIndex = appState.activePaneIndex == 0 ? 1 : 0
                }
            }
            .keyboardShortcut("o", modifiers: [.command, .option])
        }

        CommandMenu("Notes") {
            Button("Show Notes") { appState.showNotes() }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("New Note") {
                appState.showNotes()
                NotesStore.shared.createNote()
            }
        }
    }
}
