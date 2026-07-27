import AppKit
import SwiftUI

struct TerminalPanelView: View {
    @Environment(AppState.self) private var appState
    @State private var store = TerminalStore.shared
    @State private var showsCommandLibrary = false
    @FocusState private var commandIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            sessionBar
            Divider()
            output
            Divider()
            commandBar
        }
        .frame(minWidth: 340, idealWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
        .task {
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
                help: "Recent Commands and Presets"
            ) {
                showsCommandLibrary.toggle()
            }
            .popover(isPresented: $showsCommandLibrary, arrowEdge: .bottom) {
                TerminalCommandLibraryView(
                    store: store,
                    isPresented: $showsCommandLibrary
                )
            }

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

            Spacer(minLength: 8)

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
        TerminalOutputView(text: store.output)
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

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: store.isAwaitingSecureInput ? "lock.fill" : "chevron.right")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(store.isRunning ? Color.green : Color.secondary)
                    .accessibilityHidden(true)

                commandInput

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
                .accessibilityLabel("Secure terminal input")
        } else {
            TextField(store.isExecuting ? "Send input to the running command" : "Enter a command", text: $store.commandText)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .focused($commandIsFocused)
                .disabled(!store.isRunning)
                .onSubmit { submitInput() }
                .onKeyPress(.upArrow) {
                    guard !store.isExecuting else { return .ignored }
                    store.previousCommand()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    guard !store.isExecuting else { return .ignored }
                    store.nextCommand()
                    return .handled
                }
                .accessibilityLabel(store.isExecuting ? "Terminal input" : "Shell command")
        }
    }

    private var commandHelpText: String {
        if store.isAwaitingSecureInput {
            return "Password input is hidden and is never saved in Recent Commands."
        }
        if store.isExecuting {
            return "Send input to the running command, or use × to interrupt it."
        }
        return "Use ↑ and ↓ for command history. The session stays open when this panel is hidden."
    }

    private func submitInput() {
        store.executeCommand()
        commandIsFocused = true
    }

    @MainActor
    private func focusCommandField() async {
        guard store.isRunning else { return }
        commandIsFocused = false
        await Task.yield()
        commandIsFocused = true
    }
}

private struct TerminalCommandLibraryView: View {
    let store: TerminalStore
    @Binding var isPresented: Bool

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

            if store.presetCommands.isEmpty, store.recentCommands.isEmpty {
                ContentUnavailableView {
                    Label("No Saved Commands", systemImage: "terminal")
                } description: {
                    Text("Commands you run appear here. Select the star to save a preset.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if !store.presetCommands.isEmpty {
                            commandSection(
                                title: "Presets",
                                systemImage: "star.fill",
                                commands: store.presetCommands,
                                showsClearButton: false
                            )
                        }

                        if !store.recentCommands.isEmpty {
                            commandSection(
                                title: "Recent Commands",
                                systemImage: "clock.arrow.circlepath",
                                commands: store.recentCommands,
                                showsClearButton: true
                            )
                        }
                    }
                    .padding(12)
                }
            }

            Divider()
            Text("Use ▶ to run normally or the lock to request administrator privileges.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
        }
        .frame(width: 390, height: 430)
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
}

private struct TerminalOutputView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
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
        guard let textView = context.coordinator.textView,
              textView.string != text else { return }

        let visibleRect = scrollView.documentVisibleRect
        let wasNearBottom = textView.bounds.maxY - visibleRect.maxY < 44
        let wasEmpty = textView.string.isEmpty
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .textColor

        if wasNearBottom || wasEmpty {
            textView.scrollToEndOfDocument(nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        weak var textView: NSTextView?
    }
}
