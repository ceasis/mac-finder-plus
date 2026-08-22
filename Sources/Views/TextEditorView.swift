import AppKit
import SwiftUI

/// The built-in text/code editor. Edits auto-save after a short pause while the
/// native text view retains its full undo and redo history.
struct TextEditorView: View {
    @Environment(AppState.self) private var appState
    let session: TextEditorSession

    @State private var text = ""
    @State private var savedText = ""
    @State private var documentURL: URL?
    @State private var language: CodeLanguage = .plain
    @State private var wrapsLines = true
    @State private var fontSize: CGFloat = 13
    @State private var line = 1
    @State private var column = 1
    @State private var loadError: String?
    @State private var pendingGoToLine: Int?
    @State private var showGoToLine = false
    @State private var goToLineText = ""
    @State private var autosaveTask: Task<Void, Never>?
    @State private var saveError: String?
    @StateObject private var undoController = CodeTextViewUndoController()

    private var target: FileItem? { session.file }
    private var currentURL: URL? { documentURL ?? target?.url }
    private var displayName: String { currentURL?.lastPathComponent ?? "Untitled" }
    private var isDirty: Bool { text != savedText }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            editorBody
            Divider()
            statusBar
        }
        .frame(minWidth: 560, minHeight: 400)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .task(id: session.id) { load() }
        .onChange(of: text) { _, _ in scheduleAutosave() }
        .onDisappear { commitPendingAutosave() }
        .alert("Go to Line", isPresented: $showGoToLine) {
            TextField("Line number", text: $goToLineText)
            Button("Go") {
                if let number = Int(goToLineText) { pendingGoToLine = number }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var editorBody: some View {
        if let loadError {
            ContentUnavailableView(
                "Can’t Open File",
                systemImage: "doc.questionmark",
                description: Text(loadError)
            )
        } else {
            CodeTextView(
                text: $text,
                language: language,
                fontSize: fontSize,
                wrapsLines: wrapsLines,
                requestsInitialFocus: true,
                undoController: undoController,
                pendingGoToLine: $pendingGoToLine,
                onSave: { _ = save() },
                onCursorChange: { line = $0; column = $1 }
            )
            .clipped()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: currentURL == nil ? "doc.badge.plus" : "doc.text")
                .foregroundStyle(.secondary)
            Text(displayName)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if isDirty {
                Circle().fill(.orange).frame(width: 7, height: 7)
                    .help("Unsaved changes")
            }

            Spacer()

            Button { undoController.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!undoController.canUndo)
            .help("Undo (⌘Z)")
            .frame(minWidth: 30, minHeight: 28)

            Button { undoController.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!undoController.canRedo)
            .help("Redo (⇧⌘Z)")
            .frame(minWidth: 30, minHeight: 28)

            Picker("Language", selection: $language) {
                ForEach(CodeLanguage.allCases) { lang in
                    Text(lang.title).tag(lang)
                }
            }
            .labelsHidden()
            .frame(width: 140)
            .help("Syntax highlighting language")

            Button { fontSize = max(9, fontSize - 1) } label: { Image(systemName: "textformat.size.smaller") }
                .help("Zoom out")
                .frame(minWidth: 30, minHeight: 28)
            Button { fontSize = min(28, fontSize + 1) } label: { Image(systemName: "textformat.size.larger") }
                .help("Zoom in")
                .frame(minWidth: 30, minHeight: 28)

            Button { wrapsLines.toggle() } label: {
                Image(systemName: wrapsLines ? "text.alignleft" : "text.append")
            }
            .help(wrapsLines ? "Word wrap on" : "Word wrap off")
            .frame(minWidth: 30, minHeight: 28)

            Button { showGoToLine = true } label: { Image(systemName: "arrow.right.to.line") }
                .help("Go to line")
                .frame(minWidth: 30, minHeight: 28)

            Button { _ = save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .buttonStyle(.borderedProminent)
                .disabled((!isDirty && currentURL != nil) || loadError != nil)
                .help("Save now (⌘S) · Changes also save automatically")

            Button { attemptClose() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .help("Close editor")
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text("Ln \(line), Col \(column)")
            Text("\(text.count) chars")
            Spacer()
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(saveError)
            } else if isDirty {
                Label("Autosaving…", systemImage: "clock")
            } else if currentURL != nil {
                Label("Saved", systemImage: "checkmark.circle.fill")
            }
            Text(language.title)
            Text(wrapsLines ? "Wrap" : "No Wrap")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func load() {
        guard let target else {
            documentURL = nil
            text = ""
            savedText = ""
            language = .plain
            loadError = nil
            saveError = nil
            return
        }

        language = CodeLanguage.detect(for: target.url)
        let url = target.url
        documentURL = url
        Task {
            let outcome: (text: String?, error: String?) = await Task.detached(priority: .userInitiated) {
                do {
                    let data = try Data(contentsOf: url)
                    let string = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1)
                        ?? ""
                    return (string, nil)
                } catch {
                    return (nil, error.localizedDescription)
                }
            }.value
            guard self.target?.url == url else { return }
            if let failure = outcome.error {
                loadError = failure
            } else {
                text = outcome.text ?? ""
                savedText = text
                saveError = nil
            }
        }
    }

    @discardableResult
    private func save(automatically: Bool = false) -> Bool {
        autosaveTask?.cancel()
        autosaveTask = nil
        let destination = automatically ? destinationURLForAutosave() : destinationURLForSave()
        guard loadError == nil, let url = destination else { return false }
        let contents = text
        do {
            guard let data = contents.data(using: .utf8) else {
                throw TextDocumentError.cannotEncode(.utf8)
            }
            try data.write(to: url, options: .atomic)
            documentURL = url
            language = CodeLanguage.detect(for: url)
            savedText = contents
            saveError = nil
            appState.activePane.refresh()
            if url.deletingLastPathComponent().standardizedFileURL
                == appState.activePane.currentURL.standardizedFileURL {
                appState.activePane.selection = [url.path]
            }
            return true
        } catch {
            saveError = error.localizedDescription
            appState.lastError = error.localizedDescription
            return false
        }
    }

    private func destinationURLForAutosave() -> URL? {
        if let currentURL { return currentURL }
        return FileOperations.uniqueDestination(
            for: appState.activePane.currentURL.appendingPathComponent("Untitled.txt")
        )
    }

    private func destinationURLForSave() -> URL? {
        if let currentURL { return currentURL }

        let panel = NSSavePanel()
        panel.title = "Save Text Document"
        panel.prompt = "Save"
        panel.nameFieldStringValue = "Untitled.txt"
        panel.directoryURL = appState.activePane.currentURL
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func attemptClose() {
        commitPendingAutosave()
        guard !isDirty else { return }
        close()
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard loadError == nil, isDirty else {
            autosaveTask = nil
            return
        }
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, isDirty else { return }
            _ = save(automatically: true)
        }
    }

    private func commitPendingAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
        if isDirty {
            _ = save(automatically: true)
        }
    }

    private func close() {
        appState.textEditorSession = nil
    }
}
