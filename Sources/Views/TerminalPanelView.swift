import AppKit
import SwiftUI

enum TerminalCommandInputLayout {
    static let defaultHeight = 72.0
    static let minimumHeight = 64.0
    static let maximumHeight = 260.0

    static func clampedHeight(_ height: Double) -> Double {
        min(max(height, minimumHeight), maximumHeight)
    }

    static func resizedHeight(from startingHeight: Double, translation: CGFloat) -> Double {
        clampedHeight(startingHeight - Double(translation))
    }
}

struct TerminalPanelView: View {
    @Environment(AppState.self) private var appState
    @State private var store = TerminalStore.shared
    @State private var showsCommandLibrary = false
    @FocusState private var commandIsFocused: Bool
    @AppStorage("terminal.outputFontSize") private var outputFontSize = 12.0
    @AppStorage("terminal.wrapOutputLines") private var wrapsOutputLines = true
    @AppStorage("terminal.commandInputHeight") private var commandInputHeight =
        TerminalCommandInputLayout.defaultHeight

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            sessionBar
            Divider()
            output
            TerminalCommandInputResizeHandle(height: $commandInputHeight)
            commandBar
                .frame(height: TerminalCommandInputLayout.clampedHeight(commandInputHeight))
        }
        .frame(minWidth: 340, idealWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
        .task {
            commandInputHeight = TerminalCommandInputLayout.clampedHeight(commandInputHeight)
            store.startIfNeeded(at: appState.activePane.currentURL)
            await focusCommandField()
        }
        .onChange(of: store.isExecuting) { _, isExecuting in
            if !isExecuting {
                Task { @MainActor in await focusCommandField() }
            }
        }
        .onChange(of: store.isAwaitingSecureInput) {
            Task { @MainActor in await focusCommandField() }
        }
        .onChange(of: showsCommandLibrary) { _, isShowing in
            if !isShowing {
                Task { @MainActor in await focusCommandField() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Terminal", systemImage: "terminal")
                .font(.headline)

            Circle()
                .fill(store.isRunning ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
                .accessibilityLabel(store.isRunning ? "Shell running" : "Shell stopped")

            Spacer()

            PanelIconButton(
                systemName: store.presetCommands.isEmpty ? "clock.arrow.circlepath" : "list.star",
                help: "Search Commands and Presets (Control-R)"
            ) {
                showsCommandLibrary.toggle()
            }
            .popover(isPresented: $showsCommandLibrary, arrowEdge: .bottom) {
                TerminalCommandLibraryView(
                    store: store,
                    isPresented: $showsCommandLibrary
                )
            }

            outputOptionsMenu

            PanelIconButton(systemName: "eraser", help: "Clear Terminal Output") {
                store.clearOutput()
                commandIsFocused = true
            }

            PanelIconButton(systemName: "arrow.clockwise", help: "New Session in Active Folder") {
                store.restart(at: appState.activePane.currentURL)
                commandIsFocused = true
            }

            PanelIconButton(systemName: "xmark", help: "Hide Terminal") {
                appState.hideTerminalTool()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var sessionBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)

            Text(store.currentDirectory.path(percentEncoded: false))
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .help(store.currentDirectory.path(percentEncoded: false))

            Text(URL(fileURLWithPath: store.shellPath).lastPathComponent)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)

            Spacer(minLength: 8)

            Button {
                store.changeDirectory(to: appState.activePane.currentURL)
                commandIsFocused = true
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(activeFolderMatchesSession ? Color.secondary : Color.accentColor)
            .disabled(store.isExecuting || activeFolderMatchesSession)
            .help("Use the Active Pane Folder")
            .accessibilityLabel("Change terminal to the active pane folder")

            if store.isExecuting {
                ProgressView()
                    .controlSize(.mini)
                    .help("Command is running")
            } else if let exitCode = store.lastExitCode {
                Text("exit \(exitCode)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(exitCode == 0 ? Color.secondary : Color.red)
            }

            if store.isRunning {
                Button {
                    store.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Stop Shell Session")
                .accessibilityLabel("Stop shell session")
            } else {
                Button {
                    store.start(at: appState.activePane.currentURL)
                    commandIsFocused = true
                } label: {
                    Image(systemName: "play.fill")
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Start Shell Session")
                .accessibilityLabel("Start shell session")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var output: some View {
        TerminalOutputView(
            text: store.output,
            fontSize: outputFontSize,
            wrapsLines: wrapsOutputLines
        )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(alignment: .center) {
                if store.output.isEmpty {
                    ContentUnavailableView {
                        Label("Terminal Ready", systemImage: "terminal")
                    } description: {
                        Text("Enter a shell command below.")
                    }
                    .allowsHitTesting(false)
                }
            }
            .accessibilityLabel("Terminal output")
    }

    private var commandBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let errorMessage = store.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: store.isAwaitingSecureInput ? "lock.fill" : "chevron.right")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(store.isRunning ? Color.green : Color.secondary)
                    .padding(.top, 3)
                    .accessibilityHidden(true)

                commandInput

                Button {
                    store.beginSecureInput()
                    commandIsFocused = true
                } label: {
                    Image(systemName: store.isAwaitingSecureInput ? "key.fill" : "key")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(store.isAwaitingSecureInput ? Color.accentColor : Color.secondary)
                .disabled(!store.canBeginSecureInput)
                .help(
                    store.isAwaitingSecureInput
                        ? "Password input is active"
                        : store.isExecuting
                            ? "Enter Password Securely"
                            : "Run a command first, then use secure password input"
                )
                .accessibilityLabel(
                    store.isAwaitingSecureInput
                        ? "Password input active"
                        : "Enter password securely"
                )

                if store.isExecuting {
                    Button {
                        store.interruptCommand()
                        commandIsFocused = true
                    } label: {
                        Image(systemName: "xmark.circle")
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Interrupt Command (Control-C)")
                    .accessibilityLabel("Interrupt command")
                } else {
                    Button {
                        store.runWithAdministratorPrivileges(store.commandText)
                        commandIsFocused = true
                    } label: {
                        if store.isRunningPrivilegedCommand {
                            ProgressView()
                                .controlSize(.mini)
                                .frame(width: 22, height: 22)
                        } else {
                            Image(systemName: "lock.shield")
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(
                        store.isRunningPrivilegedCommand
                            || store.commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .help("Run with Administrator Privileges")
                    .accessibilityLabel("Run command with administrator privileges")

                    Button {
                        store.togglePreset(store.commandText)
                        commandIsFocused = true
                    } label: {
                        Image(systemName: store.isPreset(store.commandText) ? "star.fill" : "star")
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(store.isPreset(store.commandText) ? Color.yellow : Color.secondary)
                    .disabled(store.commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(store.isPreset(store.commandText) ? "Remove from Presets" : "Add to Presets")
                    .accessibilityLabel(store.isPreset(store.commandText) ? "Remove command from presets" : "Add command to presets")
                }

                Button {
                    store.executeCommand()
                    commandIsFocused = true
                } label: {
                    Image(systemName: "arrow.turn.down.left")
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(
                    !store.isRunning
                        || (!store.isExecuting
                            && store.commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                )
                .help(store.isExecuting ? "Send Input (Return)" : "Run Command (Return)")
                .accessibilityLabel(store.isExecuting ? "Send input" : "Run command")
            }
            .frame(maxHeight: .infinity, alignment: .top)

            Text(commandHelpText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.bar)
    }

    @ViewBuilder
    private var commandInput: some View {
        if store.isAwaitingSecureInput {
            SecureField("Password (hidden)", text: $store.commandText)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .focused($commandIsFocused)
                .disabled(!store.isRunning)
                .onSubmit { submitInput() }
                .onKeyPress("c", phases: .down, action: handleControlC)
                .onKeyPress("l", phases: .down, action: handleControlL)
                .accessibilityLabel("Secure terminal input")
        } else {
            ZStack(alignment: .topLeading) {
                if store.commandText.isEmpty {
                    Text(store.isExecuting ? "Send input to the running command" : "Enter a command")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $store.commandText)
                    .scrollContentBackground(.hidden)
                    .font(.system(.body, design: .monospaced))
                    .focused($commandIsFocused)
                    .disabled(!store.isRunning)
                    .onKeyPress(.upArrow) {
                        guard !store.isExecuting,
                              !store.commandText.contains("\n") else { return .ignored }
                        store.previousCommand()
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard !store.isExecuting,
                              !store.commandText.contains("\n") else { return .ignored }
                        store.nextCommand()
                        return .handled
                    }
                    .onKeyPress("c", phases: .down, action: handleControlC)
                    .onKeyPress("l", phases: .down, action: handleControlL)
                    .onKeyPress("r", phases: .down, action: handleControlR)
                    .onKeyPress(.return, phases: .down, action: handleCommandReturn)
                    .accessibilityLabel(store.isExecuting ? "Terminal input" : "Shell command")
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var commandHelpText: String {
        if store.isAwaitingSecureInput {
            return "Password input is hidden and is never saved in Recent Commands."
        }
        if store.isExecuting {
            return "Send input · Control-C interrupt · Control-L clear output"
        }
        return "↑↓ history · Shift-Return new line · Control-R search · Control-L clear · Shift-Command-Return administrator · leading space keeps a command private"
    }

    private func submitInput() {
        store.executeCommand()
        commandIsFocused = true
    }

    private var activeFolderMatchesSession: Bool {
        appState.activePane.currentURL.standardizedFileURL
            == store.currentDirectory.standardizedFileURL
    }

    private var outputOptionsMenu: some View {
        Menu {
            Button("Copy All Output", systemImage: "doc.on.doc") {
                copyAllOutput()
            }
            .disabled(store.output.isEmpty)

            Divider()

            Button("Increase Text Size", systemImage: "plus") {
                outputFontSize = min(outputFontSize + 1, 24)
            }
            .disabled(outputFontSize >= 24)

            Button("Decrease Text Size", systemImage: "minus") {
                outputFontSize = max(outputFontSize - 1, 9)
            }
            .disabled(outputFontSize <= 9)

            Button("Reset Text Size") {
                outputFontSize = 12
            }
            .disabled(outputFontSize == 12)

            Divider()

            Toggle("Wrap Long Lines", isOn: $wrapsOutputLines)
        } label: {
            Image(systemName: "textformat.size")
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Output Options")
        .accessibilityLabel("Terminal output options")
    }

    private func copyAllOutput() {
        guard !store.output.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.output, forType: .string)
        commandIsFocused = true
    }

    private func handleControlC(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.control),
              !press.modifiers.contains(.command),
              !press.modifiers.contains(.option) else { return .ignored }
        if store.isExecuting {
            store.interruptCommand()
        } else if !store.commandText.isEmpty {
            store.commandText = ""
        } else {
            return .ignored
        }
        return .handled
    }

    private func handleControlL(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.control),
              !press.modifiers.contains(.command),
              !press.modifiers.contains(.option) else { return .ignored }
        store.clearOutput()
        return .handled
    }

    private func handleControlR(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.control),
              !press.modifiers.contains(.command),
              !press.modifiers.contains(.option),
              !store.isExecuting else { return .ignored }
        showsCommandLibrary = true
        return .handled
    }

    private func handleAdministratorReturn(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.command),
              press.modifiers.contains(.shift),
              !store.isExecuting,
              !store.commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .ignored
        }
        store.runWithAdministratorPrivileges(store.commandText)
        return .handled
    }

    private func handleCommandReturn(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command), press.modifiers.contains(.shift) {
            return handleAdministratorReturn(press)
        }
        guard !press.modifiers.contains(.shift),
              !press.modifiers.contains(.command),
              !press.modifiers.contains(.control),
              !press.modifiers.contains(.option) else {
            return .ignored
        }
        submitInput()
        return .handled
    }

    @MainActor
    private func focusCommandField() async {
        guard store.isRunning else { return }
        commandIsFocused = false
        await Task.yield()
        commandIsFocused = true
    }
}

private struct TerminalCommandInputResizeHandle: View {
    @Binding var height: Double
    @State private var startingHeight: Double?
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.secondary.opacity(isTargeted ? 0.18 : 0.08))

            Capsule()
                .fill(Color.secondary.opacity(isTargeted ? 0.65 : 0.3))
                .frame(width: 34, height: 3)
        }
        .frame(height: 8)
        .contentShape(Rectangle())
        .verticalResizeCursor()
        .onHover { isTargeted = $0 }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let initialHeight = startingHeight ?? height
                    if startingHeight == nil {
                        startingHeight = initialHeight
                    }
                    height = TerminalCommandInputLayout.resizedHeight(
                        from: initialHeight,
                        translation: value.translation.height
                    )
                }
                .onEnded { _ in
                    startingHeight = nil
                }
        )
        .onTapGesture(count: 2) {
            height = TerminalCommandInputLayout.defaultHeight
        }
        .help("Drag to resize the terminal input. Double-click to reset.")
        .accessibilityLabel("Resize terminal input")
        .accessibilityAdjustableAction { direction in
            let adjustment = direction == .increment ? 20.0 : -20.0
            height = TerminalCommandInputLayout.clampedHeight(height + adjustment)
        }
    }
}

private struct TerminalCommandLibraryView: View {
    let store: TerminalStore
    @Binding var isPresented: Bool
    @State private var searchText = ""
    @FocusState private var searchIsFocused: Bool

    private var filteredPresets: [String] {
        filtered(store.presetCommands)
    }

    private var filteredRecentCommands: [String] {
        filtered(store.recentCommands.filter { !store.presetCommands.contains($0) })
    }

    private var firstMatch: String? {
        filteredPresets.first ?? filteredRecentCommands.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Commands", systemImage: "list.star")
                    .font(.headline)
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close")
                .accessibilityLabel("Close command library")
            }
            .padding(12)

            Divider()

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search commands", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.body.monospaced())
                    .focused($searchIsFocused)
                    .onSubmit(loadFirstMatch)
                    .onKeyPress(.escape) {
                        isPresented = false
                        return .handled
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear Search")
                    .accessibilityLabel("Clear command search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            if store.presetCommands.isEmpty, store.recentCommands.isEmpty {
                ContentUnavailableView {
                    Label("No Saved Commands", systemImage: "terminal")
                } description: {
                    Text("Commands you run appear here. Select the star to save a preset.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredPresets.isEmpty, filteredRecentCommands.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if !filteredPresets.isEmpty {
                            commandSection(
                                title: "Presets",
                                systemImage: "star.fill",
                                commands: filteredPresets,
                                showsClearButton: false
                            )
                        }

                        if !filteredRecentCommands.isEmpty {
                            commandSection(
                                title: "Recent Commands",
                                systemImage: "clock.arrow.circlepath",
                                commands: filteredRecentCommands,
                                showsClearButton: true
                            )
                        }
                    }
                    .padding(12)
                }
            }

            Divider()
            Text("Return loads the first match · Escape closes · ▶ runs · lock requests administrator privileges")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
        }
        .frame(width: 390, height: 430)
        .onAppear { searchIsFocused = true }
    }

    @ViewBuilder
    private func commandSection(
        title: String,
        systemImage: String,
        commands: [String],
        showsClearButton: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if showsClearButton {
                    Button {
                        store.clearRecentCommands()
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear Recent Commands")
                    .accessibilityLabel("Clear recent commands")
                }
            }

            ForEach(commands, id: \.self) { command in
                commandRow(command)
            }
        }
    }

    private func commandRow(_ command: String) -> some View {
        HStack(spacing: 6) {
            Button {
                store.loadCommand(command)
                isPresented = false
            } label: {
                Text(command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.isExecuting)
            .help("Load Command")

            Button {
                store.togglePreset(command)
            } label: {
                Image(systemName: store.isPreset(command) ? "star.fill" : "star")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(store.isPreset(command) ? Color.yellow : Color.secondary)
            .help(store.isPreset(command) ? "Remove from Presets" : "Add to Presets")
            .accessibilityLabel(store.isPreset(command) ? "Remove command from presets" : "Add command to presets")

            Button {
                store.runWithAdministratorPrivileges(command)
                isPresented = false
            } label: {
                if store.isRunningPrivilegedCommand {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: "lock.shield")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(store.isRunningPrivilegedCommand)
            .help("Run with Administrator Privileges")
            .accessibilityLabel("Run command with administrator privileges")

            Button {
                store.runCommand(command)
                isPresented = false
            } label: {
                Image(systemName: "play.fill")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!store.isRunning || store.isExecuting)
            .help("Run Command")
            .accessibilityLabel("Run command")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
    }

    private func filtered(_ commands: [String]) -> [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return commands }
        return commands.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private func loadFirstMatch() {
        guard let firstMatch else { return }
        store.loadCommand(firstMatch)
        isPresented = false
    }
}

private struct TerminalOutputView: NSViewRepresentable {
    let text: String
    let fontSize: Double
    let wrapsLines: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wrapsLines
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: clampedFontSize, weight: .regular)
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.isVerticallyResizable = true
        configureLineWrapping(textView, in: scrollView)
        textView.textContainer?.lineFragmentPadding = 0
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.string = text

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        let visibleRect = scrollView.documentVisibleRect
        let wasNearBottom = textView.bounds.maxY - visibleRect.maxY < 44
        let wasEmpty = textView.string.isEmpty
        let textChanged = textView.string != text
        if textChanged { textView.string = text }
        textView.font = .monospacedSystemFont(ofSize: clampedFontSize, weight: .regular)
        textView.textColor = .textColor
        scrollView.hasHorizontalScroller = !wrapsLines
        configureLineWrapping(textView, in: scrollView)

        if textChanged && (wasNearBottom || wasEmpty) {
            textView.scrollToEndOfDocument(nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        weak var textView: NSTextView?
    }

    private var clampedFontSize: CGFloat {
        CGFloat(min(max(fontSize, 9), 24))
    }

    private func configureLineWrapping(_ textView: NSTextView, in scrollView: NSScrollView) {
        textView.isHorizontallyResizable = !wrapsLines
        textView.autoresizingMask = wrapsLines ? [.width] : []
        textView.textContainer?.widthTracksTextView = wrapsLines
        textView.textContainer?.containerSize = NSSize(
            width: wrapsLines ? max(scrollView.contentSize.width, 1) : .greatestFiniteMagnitude,
            height: .greatestFiniteMagnitude
        )
    }
}
