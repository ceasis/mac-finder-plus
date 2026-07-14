import SwiftUI

private struct CommandPaletteEntry: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let disabledReason: String?
    let action: () -> Void

    var isEnabled: Bool { disabledReason == nil }
}

struct CommandPaletteView: View {
    @Environment(AppState.self) private var appState
    @State private var workflowStore = SavedWorkflowStore.shared
    @State private var dropStack = DropStackStore.shared
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    private var entries: [CommandPaletteEntry] {
        var result: [CommandPaletteEntry] = [
            entry("new-folder", "New Folder", "Create a folder in the active pane", "folder.badge.plus") {
                appState.showNewFolderPrompt = true
            },
            entry("go-to-folder", "Go to Folder", "Jump to a path", "arrow.forward.to.line") {
                appState.showGoToPrompt = true
            },
            entry("find", "Find in Pane", "Focus the active pane search field", "magnifyingglass") {
                appState.searchFocusTick += 1
            },
            entry(
                "copy-selection-other-pane",
                "Copy to Other Pane",
                "Copy selected files into the inactive pane",
                "doc.on.doc",
                disabledReason: appState.selectionTransferUnavailableReason
            ) {
                appState.transferSelection(move: false)
            },
            entry(
                "move-selection-other-pane",
                "Move to Other Pane",
                "Move selected files into the inactive pane",
                "arrow.right.doc.on.clipboard",
                disabledReason: appState.selectionTransferUnavailableReason
            ) {
                appState.transferSelection(move: true)
            },
            entry(
                "airdrop-selection",
                "Share via AirDrop",
                "Share selected files with AirDrop",
                "square.and.arrow.up",
                disabledReason: appState.airDropUnavailableReason
            ) {
                appState.shareSelectionViaAirDrop()
            },
            entry("drop-stack", "Show Drop Stack", "Collect files from multiple folders", "tray.full") {
                appState.showDropStack()
            },
            entry(
                "add-selection-drop-stack",
                "Add Selection to Drop Stack",
                "Collect selected files for later",
                "tray.and.arrow.down",
                disabledReason: appState.addSelectionToDropStackUnavailableReason
            ) {
                appState.addSelectionToDropStack()
            },
            entry(
                "copy-stack-other-pane",
                "Copy Drop Stack to Other Pane",
                "Copy collected files into the inactive pane",
                "doc.on.doc",
                disabledReason: appState.dropStackTransferUnavailableReason
            ) {
                appState.transferDropStackToOtherPane(move: false)
            },
            entry(
                "move-stack-other-pane",
                "Move Drop Stack to Other Pane",
                "Move collected files into the inactive pane",
                "arrow.right.doc.on.clipboard",
                disabledReason: appState.dropStackTransferUnavailableReason
            ) {
                appState.transferDropStackToOtherPane(move: true)
            },
            entry("saved-workflows", "Show Saved Workflows", "Create and run file recipes", "slider.horizontal.3") {
                appState.showSavedWorkflows()
            },
            entry("advanced-search", "Advanced Search", "Regex, contents, tags, metadata, and archive search", "magnifyingglass") {
                appState.showAdvancedSearch()
            },
            entry(
                "browse-archive",
                "Archive Browser",
                "Inspect archive contents in the side panel",
                "archivebox"
            ) {
                appState.showArchiveBrowser()
            },
            entry(
                "batch-rename",
                "Batch Rename",
                "Rename selected files with a rule",
                "textformat.abc",
                disabledReason: appState.hasActiveSelection ? nil : "Select one or more files first."
            ) {
                appState.beginBatchRename()
            },
            entry(
                "resize-images",
                "Resize Images",
                "Resize selected images",
                "arrow.down.right.and.arrow.up.left",
                disabledReason: appState.hasSelectedImage ? nil : "Select one or more images first."
            ) {
                appState.beginResize()
            },
            entry(
                "convert-media",
                "Convert Media",
                "Convert selected images, video, audio, or documents",
                "arrow.triangle.2.circlepath",
                disabledReason: appState.hasActiveSelection ? nil : "Select one or more files first."
            ) {
                appState.beginConvert()
            },
            entry(
                "annotate-image",
                "Annotate Image",
                "Open the selected image in the annotation editor",
                "pencil",
                disabledReason: appState.annotateUnavailableReason
            ) {
                appState.beginAnnotateImage()
            },
            entry("preview", "Toggle Preview", "Show media and rich document preview", "photo") {
                appState.togglePreview()
            },
            entry("organize", "Organize Folder", "Plan folder organization by type, month, year, or size", "folder.badge.gearshape") {
                appState.showOrganizeTool()
            },
            entry("cleanup", "Clean Up", "Find large, old, duplicate, and leftover files", "sparkles") {
                appState.showCleanupTool()
            },
            entry("disk-space", "Disk Space", "Analyze the active folder", "chart.pie") {
                appState.showDiskSpaceAnalyzer()
            },
            entry("clipboard", "Clipboard History", "Show recent copied text, paths, and files", "clipboard") {
                appState.showClipboardHistory()
            },
            entry("notes", "Notes", "Open notes", "note.text") {
                appState.showNotes()
            },
            entry("snippets", "Snippets", "Open reusable text, images, and files", "text.quote") {
                appState.showSnippets()
            },
            entry("voice-recorder", "Voice Recorder", "Record audio into the active folder", "mic") {
                appState.showVoiceRecorderTool()
            },
            entry("screenshot", "Capture Screenshot", "Open screenshot capture", "camera.viewfinder") {
                appState.beginScreenshotCapture()
            },
            entry("recording", "Record Screen", "Open screen recording", "record.circle") {
                appState.beginScreenRecording()
            },
            entry(
                "compare-folders",
                "Compare Folders",
                "Compare the left and right panes",
                "rectangle.split.2x1",
                disabledReason: appState.isDualPane ? nil : "Open two panes first."
            ) {
                appState.compareFoldersAcrossPanes()
            },
            entry(
                "find-duplicates",
                "Find Duplicates in Both Views",
                "Search both panes for matching files",
                "doc.on.doc",
                disabledReason: appState.isDualPane ? nil : "Open two panes first."
            ) {
                appState.findDuplicatesAcrossPanes()
            },
            entry("activity", "Activity History", "Show file operation history", "clock.arrow.circlepath") {
                appState.showActivityHistory = true
            },
            entry("shortcuts", "Keyboard Shortcuts", "Show common keyboard commands", "keyboard") {
                appState.showKeyboardShortcuts = true
            },
        ]

        for workflow in workflowStore.workflows {
            result.append(entry(
                "workflow-\(workflow.id.uuidString)-selection",
                "Run \(workflow.name)",
                "Workflow on active selection · \(workflow.stepSummary)",
                "play.circle",
                disabledReason: workflowUnavailableReason(workflow, source: .selection)
            ) {
                appState.runWorkflow(workflow, source: .selection)
            })
            result.append(entry(
                "workflow-\(workflow.id.uuidString)-stack",
                "Run \(workflow.name) on Drop Stack",
                workflow.stepSummary,
                "tray.full",
                disabledReason: workflowUnavailableReason(workflow, source: .dropStack)
            ) {
                appState.runWorkflow(workflow, source: .dropStack)
            })
        }

        return result
    }

    private var filteredEntries: [CommandPaletteEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { entry in
            entry.title.localizedCaseInsensitiveContains(trimmed)
                || entry.subtitle.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "command")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 28, height: 28)

                TextField("Search commands, tools, and workflows", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isSearchFocused)
                    .onSubmit(runFirstResult)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filteredEntries) { entry in
                        Button {
                            run(entry)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: entry.systemImage)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(entry.isEnabled ? .blue : .secondary)
                                    .frame(width: 28, height: 28)
                                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(entry.disabledReason.map { "Unavailable: \($0)" } ?? entry.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                if !entry.isEnabled {
                                    Text("Unavailable")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!entry.isEnabled)
                        .background(
                            Color.secondary.opacity(0.001),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                }
                .padding(10)
            }

            Divider()

            HStack {
                Text("\(filteredEntries.count) result\(filteredEntries.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Return runs the first available command")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .frame(width: 700, height: 540)
        .onAppear {
            workflowStore.ensureSelection()
            isSearchFocused = true
        }
    }

    private func entry(
        _ id: String,
        _ title: String,
        _ subtitle: String,
        _ systemImage: String,
        enabled: Bool = true,
        disabledReason: String? = nil,
        action: @escaping () -> Void
    ) -> CommandPaletteEntry {
        CommandPaletteEntry(
            id: id,
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            disabledReason: disabledReason ?? (enabled ? nil : "Unavailable right now."),
            action: action
        )
    }

    private func workflowUnavailableReason(
        _ workflow: SavedWorkflow,
        source: SavedWorkflowRunSource
    ) -> String? {
        guard !workflow.steps.isEmpty else {
            return "Add at least one step to this workflow."
        }
        if workflow.steps.contains(where: \.requiresDualPane), !appState.isDualPane {
            return "Open two panes for this workflow."
        }
        switch source {
        case .selection:
            return appState.hasActiveSelection ? nil : "Select one or more files first."
        case .dropStack:
            return dropStack.existingItems.isEmpty ? "Add files to the drop stack first." : nil
        }
    }

    private func runFirstResult() {
        guard let first = filteredEntries.first(where: \.isEnabled) else { return }
        run(first)
    }

    private func run(_ entry: CommandPaletteEntry) {
        guard entry.isEnabled else { return }
        appState.hideCommandPalette()
        entry.action()
    }
}
