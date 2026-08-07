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
            Button(AppCommandResponder.canUndoFocusedTextEditor ? "Undo" : appState.undoFileOperationTitle) {
                if !AppCommandResponder.undoFocusedTextEditor() {
                    appState.undoLastFileOperation()
                }
            }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!AppCommandResponder.canUndoFocusedTextEditor && !appState.canUndoFileOperation)

            Button("Redo") {
                AppCommandResponder.redoFocusedTextEditor()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!AppCommandResponder.canRedoFocusedTextEditor)
        }

        CommandGroup(after: .newItem) {
            Button("New Folder") { appState.showNewFolderPrompt = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Rename") { appState.beginRenameSelection() }
                .disabled(!appState.hasActiveSelection)
            Button("Batch Rename…") { appState.beginBatchRename() }
                .disabled(!appState.hasActiveSelection)
            Button(duplicateCommandTitle) {
                if appState.activeToolPanel == .notes,
                   let noteID = NotesStore.shared.selectedNoteID {
                    NotesStore.shared.duplicateNote(noteID)
                } else if appState.activeToolPanel == .calendar,
                          let reminderID = CalendarToolState.shared.selectedReminderID,
                          let copy = CalendarToolReminderStore.shared.duplicate(reminderID) {
                    CalendarToolState.shared.selectReminder(copy)
                } else if appState.activeToolPanel == .snippets {
                    SnippetStore.shared.duplicateSelectedSnippet()
                } else {
                    appState.duplicateSelection()
                }
            }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(
                    appState.activeToolPanel == .notes
                        ? NotesStore.shared.selectedNoteID == nil
                        : appState.activeToolPanel == .calendar
                            ? CalendarToolState.shared.selectedReminderID == nil
                            : appState.activeToolPanel == .snippets
                                ? SnippetStore.shared.selectedSnippetID == nil
                                : !appState.hasActiveSelection
                )
            Button("Edit in Text Editor") { appState.beginEditText() }
                .keyboardShortcut("e", modifiers: [.command, .option])
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
            Button("Find") {
                if appState.activeToolPanel == .notes {
                    NotesStore.shared.searchFocusTick += 1
                } else if appState.activeToolPanel == .calendar {
                    CalendarToolState.shared.focusReminderSearch()
                } else if appState.activeToolPanel == .snippets {
                    SnippetStore.shared.focusSearch()
                } else {
                    appState.searchFocusTick += 1
                }
            }
                .keyboardShortcut("f", modifiers: .command)
            Button(deleteCommandTitle) {
                if AppCommandResponder.deleteToBeginningOfLineInFocusedTextEditor() {
                    return
                } else if appState.activeToolPanel == .notes {
                    NotesStore.shared.deleteSelectedNote()
                } else if appState.activeToolPanel == .calendar,
                          let reminder = CalendarToolReminderStore.shared.reminder(
                            id: CalendarToolState.shared.selectedReminderID
                          ) {
                    CalendarToolReminderStore.shared.delete(reminder)
                    CalendarToolState.shared.selectedReminderID = nil
                } else if appState.activeToolPanel == .snippets {
                    SnippetStore.shared.deleteSelectedSnippet()
                } else {
                    appState.trashSelection()
                }
            }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(
                    !AppCommandResponder.isFocusedTextEditor
                        && (appState.activeToolPanel == .notes
                            ? NotesStore.shared.selectedNoteID == nil
                            : appState.activeToolPanel == .calendar
                                ? CalendarToolState.shared.selectedReminderID == nil
                                : appState.activeToolPanel == .snippets
                                    ? SnippetStore.shared.selectedSnippetID == nil
                                    : !appState.hasActiveSelection)
                )
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
                appState.openSelection()
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
            .keyboardShortcut("n", modifiers: [.command, .control])
            Button("Save Note") {
                NotesStore.shared.saveNow()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(appState.activeToolPanel != .notes || !NotesStore.shared.hasUnsavedChanges)
            Divider()
            Button("Previous Note") { NotesStore.shared.selectAdjacentNote(offset: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(appState.activeToolPanel != .notes || NotesStore.shared.filteredNotes.isEmpty)
            Button("Next Note") { NotesStore.shared.selectAdjacentNote(offset: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(appState.activeToolPanel != .notes || NotesStore.shared.filteredNotes.isEmpty)
            Button("Pin or Unpin Note") { NotesStore.shared.toggleSelectedNotePinned() }
                .keyboardShortcut("p", modifiers: [.command, .control])
                .disabled(appState.activeToolPanel != .notes || NotesStore.shared.selectedNoteID == nil)
        }

        CommandMenu("Snippets") {
            Button("Show Snippets") { appState.showSnippets() }
                .keyboardShortcut("j", modifiers: [.command, .option])
            Button("New Text Snippet") {
                appState.showSnippets()
                SnippetStore.shared.focusComposer()
            }
            .keyboardShortcut("k", modifiers: [.command, .control])
            Button("Save Current Clipboard") {
                appState.showSnippets()
                SnippetStore.shared.addCurrentClipboard()
            }
            .keyboardShortcut("v", modifiers: [.command, .control])
            Divider()
            Button("Previous Snippet") { SnippetStore.shared.selectAdjacentSnippet(offset: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.control, .option])
                .disabled(appState.activeToolPanel != .snippets || SnippetStore.shared.filteredSnippets.isEmpty)
            Button("Next Snippet") { SnippetStore.shared.selectAdjacentSnippet(offset: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.control, .option])
                .disabled(appState.activeToolPanel != .snippets || SnippetStore.shared.filteredSnippets.isEmpty)
            Button("Edit Text") { SnippetStore.shared.focusEditor() }
                .keyboardShortcut("e", modifiers: [.command, .control])
                .disabled(
                    appState.activeToolPanel != .snippets
                        || SnippetStore.shared.snippet(for: SnippetStore.shared.selectedSnippetID)?.kind != .text
                )
            Button("Pin or Unpin Snippet") { SnippetStore.shared.toggleSelectedSnippetPinned() }
                .keyboardShortcut("p", modifiers: [.control, .option])
                .disabled(appState.activeToolPanel != .snippets || SnippetStore.shared.selectedSnippetID == nil)
        }

        CommandMenu("Tools") {
            Button("Command Palette…") { appState.openCommandPalette() }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button("Drop Stack…") { appState.showDropStack() }
                .keyboardShortcut("d", modifiers: [.command, .option])
            Button("Notes…") { appState.showNotes() }
            Button("Text Editor…") { appState.beginEditText() }
            Button("Calendar…") { appState.showCalendarTool() }
            Button("Calculator…") { appState.showCalculatorTool() }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Terminal…") { appState.showTerminalTool() }
            Button("Clipboard History…") { appState.showClipboardHistory() }
            Button("Snippets…") { appState.showSnippets() }
            Button("Saved Workflows…") { appState.showSavedWorkflows() }
            Button("Advanced Search…") { appState.showAdvancedSearch() }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Button("Archive Browser…") { appState.showArchiveBrowser() }
            Divider()
            Menu("Pro Tools") {
                if appState.proToolsEnabled {
                    Button("Screenshot…") { appState.beginScreenshotCapture() }
                        .keyboardShortcut("5", modifiers: [.command, .option])
                    Button("Screen Recording…") { appState.beginScreenRecording() }
                    Button("Voice Recorder…") { appState.showVoiceRecorderTool() }
                        .keyboardShortcut("m", modifiers: [.command, .option])
                } else {
                    Button("Enable Pro Tools…") { appState.enableProTools() }
                        .disabled(appState.isEnablingProTools)
                }
            }
            Button("Annotate Image…") { appState.beginAnnotateImage() }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(!appState.canAnnotateSelection)
            Button("Pomodoro…") { appState.showPomodoroTool() }
                .keyboardShortcut("t", modifiers: [.command, .option])
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
            Button(appState.activeToolPanel == .snippets ? "Copy Snippet" : "Copy Files") {
                if !AppCommandResponder.copyFocusedTextEditor() {
                    if appState.activeToolPanel == .snippets {
                        SnippetStore.shared.copySelectedSnippet()
                    } else {
                        appState.copyFilesOfSelection()
                    }
                }
            }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(
                    !AppCommandResponder.isFocusedTextEditor
                        && (appState.activeToolPanel == .snippets
                            ? SnippetStore.shared.selectedSnippetID == nil
                            : !appState.hasActiveSelection)
                )
            Button("Cut Files") {
                if !AppCommandResponder.cutFocusedTextEditor() {
                    if appState.activeToolPanel != .snippets {
                        appState.cutFilesOfSelection()
                    }
                }
            }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(appState.activeToolPanel == .snippets && !AppCommandResponder.isFocusedTextEditor)
            Button("Paste") {
                if !AppCommandResponder.pasteIntoFocusedTextEditor() {
                    if appState.activeToolPanel == .snippets {
                        SnippetStore.shared.addCurrentClipboard()
                    } else {
                        appState.pasteClipboardFilesToActiveFolder()
                    }
                }
            }
                .keyboardShortcut("v", modifiers: .command)
            Button("Copy Names As Text") { appState.copyNamesOfSelection() }
                .disabled(!appState.hasActiveSelection)
            Button("Copy Paths As Text") { appState.copyPathOfSelection() }
                .disabled(!appState.hasActiveSelection)
            Divider()
            Button("Clear Clipboard History") { ClipboardHistoryStore.shared.clear() }
                .disabled(ClipboardHistoryStore.shared.entries.isEmpty)
        }
    }

    private var duplicateCommandTitle: String {
        switch appState.activeToolPanel {
        case .notes: "Duplicate Note"
        case .calendar: "Duplicate Reminder"
        case .snippets: "Duplicate Snippet"
        default: "Duplicate"
        }
    }

    private var deleteCommandTitle: String {
        switch appState.activeToolPanel {
        case .notes: "Delete Note"
        case .calendar: "Delete Reminder"
        case .snippets: "Delete Snippet"
        default: "Move to Trash"
        }
    }
}

struct CalendarCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandMenu("Calendar") {
            Button("Show Calendar") { appState.showCalendarTool() }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button("New Reminder") {
                appState.showCalendarTool()
                CalendarToolState.shared.focusReminderComposer()
            }
            .keyboardShortcut("r", modifiers: [.command, .control])
            Button("Search Reminders") {
                appState.showCalendarTool()
                CalendarToolState.shared.focusReminderSearch()
            }
            Divider()
            Button("Today") { CalendarToolState.shared.goToToday() }
                .keyboardShortcut("t", modifiers: [.command, .control])
            Button("Previous Period") {
                CalendarToolState.shared.navigatePeriod(direction: -1)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Next Period") {
                CalendarToolState.shared.navigatePeriod(direction: 1)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Divider()
            Button("Week View") { CalendarToolState.shared.period = .week }
                .keyboardShortcut("1", modifiers: [.command, .control])
            Button("Month View") { CalendarToolState.shared.period = .month }
                .keyboardShortcut("2", modifiers: [.command, .control])
            Button("Year View") { CalendarToolState.shared.period = .year }
                .keyboardShortcut("3", modifiers: [.command, .control])
            Toggle("Show Agenda", isOn: Binding(
                get: { CalendarToolState.shared.showsAgenda },
                set: { CalendarToolState.shared.showsAgenda = $0 }
            ))
        }
    }
}

/// Lets standard text controls keep native paste behavior before Workbench
/// falls back to pasting files into the active browser pane.
@MainActor
enum AppCommandResponder {
    typealias ActionSender = (_ action: Selector, _ target: AnyObject) -> Bool

    static var isFocusedTextEditor: Bool {
        guard let firstResponder = NSApp.keyWindow?.firstResponder else { return false }
        return isEditingText(firstResponder)
    }

    static func copyFocusedTextEditor(
        firstResponder: NSResponder? = NSApp.keyWindow?.firstResponder,
        sendAction: ActionSender = { action, target in
            NSApp.sendAction(action, to: target, from: nil)
        }
    ) -> Bool {
        guard let firstResponder, isEditingText(firstResponder) else { return false }
        return sendAction(#selector(NSText.copy(_:)), firstResponder)
    }

    static func deleteToBeginningOfLineInFocusedTextEditor(
        firstResponder: NSResponder? = NSApp.keyWindow?.firstResponder,
        sendAction: ActionSender = { action, target in
            NSApp.sendAction(action, to: target, from: nil)
        }
    ) -> Bool {
        guard let firstResponder, isEditingText(firstResponder) else { return false }
        return sendAction(NSSelectorFromString("deleteToBeginningOfLine:"), firstResponder)
    }

    static func pasteIntoFocusedTextEditor(
        firstResponder: NSResponder? = NSApp.keyWindow?.firstResponder,
        sendAction: ActionSender = { action, target in
            NSApp.sendAction(action, to: target, from: nil)
        }
    ) -> Bool {
        guard let firstResponder, isEditingText(firstResponder) else { return false }
        return sendAction(#selector(NSText.paste(_:)), firstResponder)
    }

    static func cutFocusedTextEditor(
        firstResponder: NSResponder? = NSApp.keyWindow?.firstResponder,
        sendAction: ActionSender = { action, target in
            NSApp.sendAction(action, to: target, from: nil)
        }
    ) -> Bool {
        guard let firstResponder, isEditingText(firstResponder) else { return false }
        return sendAction(#selector(NSText.cut(_:)), firstResponder)
    }

    static var canUndoFocusedTextEditor: Bool {
        guard let firstResponder = NSApp.keyWindow?.firstResponder,
              isEditingText(firstResponder) else { return false }
        return firstResponder.undoManager?.canUndo == true
    }

    static var canRedoFocusedTextEditor: Bool {
        guard let firstResponder = NSApp.keyWindow?.firstResponder,
              isEditingText(firstResponder) else { return false }
        return firstResponder.undoManager?.canRedo == true
    }

    @discardableResult
    static func undoFocusedTextEditor(firstResponder: NSResponder? = NSApp.keyWindow?.firstResponder) -> Bool {
        guard let firstResponder,
              isEditingText(firstResponder),
              let undoManager = firstResponder.undoManager,
              undoManager.canUndo else { return false }
        undoManager.undo()
        return true
    }

    @discardableResult
    static func redoFocusedTextEditor(firstResponder: NSResponder? = NSApp.keyWindow?.firstResponder) -> Bool {
        guard let firstResponder,
              isEditingText(firstResponder),
              let undoManager = firstResponder.undoManager,
              undoManager.canRedo else { return false }
        undoManager.redo()
        return true
    }

    private static func isEditingText(_ responder: NSResponder) -> Bool {
        if responder is NSTextView || responder is NSText {
            return true
        }
        if let textField = responder as? NSTextField {
            return textField.currentEditor() != nil
        }
        return false
    }
}

struct WorkbenchAppInfoCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    let appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Workbench") { appState.showAboutWorkbench = true }
            Divider()
            Button("Review App Permissions…") {
                PermissionReviewPresentationPolicy.markPresented()
                openWindow(id: PermissionsReviewView.windowID)
            }
        }
    }
}
