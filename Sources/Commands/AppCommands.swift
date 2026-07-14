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
                .disabled(!appState.hasActiveSelection)
            Button("Batch Rename…") { appState.beginBatchRename() }
                .disabled(!appState.hasActiveSelection)
            Button("Duplicate") { appState.duplicateSelection() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!appState.hasActiveSelection)
            Button("Edit in Text Editor") { appState.beginEditText() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(!appState.hasActiveSelection)
            Button("Resize Images…") { appState.beginResize() }
                .disabled(!appState.hasActiveSelection)
            Button("Convert…") { appState.beginConvert() }
                .disabled(!appState.hasActiveSelection)
            Button("Play Preview Slideshow") { appState.beginPreviewSlideshow() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(!appState.hasActiveSelection)
            Button("Merge Into Video…") { appState.beginMergeIntoVideo() }
                .disabled(!appState.hasActiveSelection)
            Button("Export Contact Sheet PDF") { appState.exportContactSheet() }
                .disabled(!appState.hasActiveSelection)
            Menu("Rating") {
                Button("Clear Rating") { appState.rateSelection(0) }
                Divider()
                ForEach(1...5, id: \.self) { rating in
                    Button("\(rating) Star\(rating == 1 ? "" : "s")") {
                        appState.rateSelection(rating)
                    }
                }
            }
            .disabled(!appState.hasActiveSelection)
            Button("Rotate Left") { appState.transformSelection(operation: .rotateLeft) }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(!appState.hasActiveSelection)
            Button("Rotate Right") { appState.transformSelection(operation: .rotateRight) }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!appState.hasActiveSelection)
            Button("Flip Horizontal") { appState.transformSelection(operation: .flipHorizontal) }
                .disabled(!appState.hasActiveSelection)
            Button("Flip Vertical") { appState.transformSelection(operation: .flipVertical) }
                .disabled(!appState.hasActiveSelection)
            Button("Find") { appState.searchFocusTick += 1 }
                .keyboardShortcut("f", modifiers: .command)
            Button("Move to Trash") { appState.trashSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!appState.hasActiveSelection)
        }

        CommandGroup(after: .sidebar) {
            Divider()
            Button("as List") { appState.activePane.viewMode = .list }
                .keyboardShortcut("1", modifiers: .command)
            Button("as Icons") { appState.activePane.viewMode = .icons }
                .keyboardShortcut("2", modifiers: .command)
            Button("as Columns") { appState.activePane.viewMode = .columns }
                .keyboardShortcut("3", modifiers: .command)
            Button("Toggle Dual Pane") { appState.toggleDualPane() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Toggle Hidden Files") { appState.showHidden.toggle() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Toggle("Auto Calculate Folder Sizes", isOn: Binding(
                get: { appState.autoCalculateFolderSizes },
                set: { appState.autoCalculateFolderSizes = $0 }
            ))
            Button("Toggle Preview Pane") { appState.togglePreview() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Quick Look") { appState.quickLookSelection() }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(!appState.hasActiveSelection)
            Button("Refresh") { appState.activePane.refresh() }
                .keyboardShortcut("r", modifiers: .command)
        }

        CommandMenu("Go") {
            Button("Back") { appState.activePane.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!appState.activePane.canGoBack)
            Button("Forward") { appState.activePane.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!appState.activePane.canGoForward)
            Button("Enclosing Folder") { appState.activePane.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!appState.activePane.canGoUp)
            Button("Open Selection") {
                appState.activePane.open(appState.activePane.selection)
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(!appState.hasActiveSelection)
            Divider()
            Button("Home") { appState.goHome() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Go to Folder…") { appState.showGoToPrompt = true }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .help) {
            Button("Show Welcome Guide…") { appState.showOnboarding = true }
            Button("Release Readiness Checklist…") { appState.showReleaseChecklist = true }
            Divider()
            Button("Keyboard Shortcuts…") { appState.showKeyboardShortcuts = true }
                .keyboardShortcut("/", modifiers: .command)
            Button("Activity History…") { appState.showActivityHistory = true }
            Button("Version & Updates…") { appState.showUpdatePanel = true }
            Divider()
            Button("Export Workbench Data…") { appState.exportWorkbenchDataBackup() }
            Button("Import Workbench Data…") { appState.importWorkbenchDataBackup() }
            Button("Export Diagnostics…") { appState.exportWorkbenchDiagnostics() }
            Button("Open Support Folder") { appState.revealWorkbenchSupportFolder() }
            Button("Report a Problem…") { appState.reportProblem() }
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
                .disabled(!appState.canTransferSelectionToOtherPane)
            Button("Move to Other Pane") { appState.transferSelection(move: true) }
                .keyboardShortcut(f6, modifiers: [])
                .disabled(!appState.canTransferSelectionToOtherPane)
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
            Button("Find Duplicates in Both Views") { appState.findDuplicatesAcrossPanes() }
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

        CommandMenu("Snippets") {
            Button("Show Snippets") { appState.showSnippets() }
            Button("Save Current Clipboard") {
                appState.showSnippets()
                SnippetStore.shared.addCurrentClipboard()
            }
        }

        CommandMenu("Tools") {
            Button("Command Palette…") { appState.openCommandPalette() }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button("Drop Stack…") { appState.showDropStack() }
                .keyboardShortcut("d", modifiers: [.command, .option])
            Button("Notes…") { appState.showNotes() }
            Button("Clipboard History…") { appState.showClipboardHistory() }
            Button("Snippets…") { appState.showSnippets() }
            Button("Saved Workflows…") { appState.showSavedWorkflows() }
            Button("Advanced Search…") { appState.showAdvancedSearch() }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Button("Archive Browser…") { appState.showArchiveBrowser() }
            Divider()
            Button("Capture Screenshot or Recording…") { appState.beginScreenshot() }
                .keyboardShortcut("5", modifiers: [.command, .option])
            Button("Annotate Image…") { appState.beginAnnotateImage() }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(!appState.canAnnotateSelection)
            Button("Voice Recorder…") { appState.showVoiceRecorderTool() }
                .keyboardShortcut("m", modifiers: [.command, .option])
            Button("Organize Folder…") { appState.showOrganizeTool() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Clean Up…") { appState.showCleanupTool() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("Disk Space…") { appState.showDiskSpaceAnalyzer() }
            Divider()
            Button("Add Selection to Drop Stack") { appState.addSelectionToDropStack() }
                .disabled(!appState.canAddSelectionToDropStack)
            Button("Copy Drop Stack to Other Pane") { appState.transferDropStackToOtherPane(move: false) }
                .disabled(!appState.canTransferDropStackToOtherPane)
            Button("Move Drop Stack to Other Pane") { appState.transferDropStackToOtherPane(move: true) }
                .disabled(!appState.canTransferDropStackToOtherPane)
            Divider()
            Button("Run Workflow on Selection") { appState.runSelectedWorkflow(source: .selection) }
                .disabled(!appState.canRunSelectedWorkflow(source: .selection))
            Button("Run Workflow on Drop Stack") { appState.runSelectedWorkflow(source: .dropStack) }
                .disabled(!appState.canRunSelectedWorkflow(source: .dropStack))
        }

        CommandMenu("Clipboard") {
            Button("Show Clipboard History") { appState.showClipboardHistory() }
                .keyboardShortcut("v", modifiers: [.command, .option])
            Button("Copy Files") { appState.copyFilesOfSelection() }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!appState.hasActiveSelection)
            Button("Paste Files") { appState.pasteClipboardFilesToActiveFolder() }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(!appState.canPasteFilesFromClipboard)
            Button("Copy Names As Text") { appState.copyNamesOfSelection() }
                .disabled(!appState.hasActiveSelection)
            Button("Copy Paths As Text") { appState.copyPathOfSelection() }
                .disabled(!appState.hasActiveSelection)
            Divider()
            Button("Clear Clipboard History") { ClipboardHistoryStore.shared.clear() }
                .disabled(ClipboardHistoryStore.shared.entries.isEmpty)
        }
    }
}

struct WorkbenchAppInfoCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Workbench") { appState.showAboutWorkbench = true }
        }
    }
}
