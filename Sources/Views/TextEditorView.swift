import SwiftUI

/// The built-in text/code editor. Loads a file, edits it with CodeTextView, and
/// saves back to disk. Presented as a non-outside-dismissable modal so unsaved
/// work isn't lost to a stray click — closing goes through a dirty-state guard.
struct TextEditorView: View {
    @Environment(AppState.self) private var appState
    let target: FileItem

    @State private var text = ""
    @State private var savedText = ""
    @State private var language: CodeLanguage = .plain
    @State private var wrapsLines = true
    @State private var fontSize: CGFloat = 13
    @State private var line = 1
    @State private var column = 1
    @State private var loadError: String?
    @State private var pendingGoToLine: Int?
    @State private var showGoToLine = false
    @State private var goToLineText = ""
    @State private var showDiscardConfirm = false

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
        .task(id: target.id) { load() }
        .alert("Go to Line", isPresented: $showGoToLine) {
            TextField("Line number", text: $goToLineText)
            Button("Go") {
                if let number = Int(goToLineText) { pendingGoToLine = number }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "You have unsaved changes.",
            isPresented: $showDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button("Save") { save(); close() }
            Button("Discard Changes", role: .destructive) { close() }
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
                pendingGoToLine: $pendingGoToLine,
                onSave: save,
                onCursorChange: { line = $0; column = $1 }
            )
            .clipped()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text(target.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if isDirty {
                Circle().fill(.orange).frame(width: 7, height: 7)
                    .help("Unsaved changes")
            }

            Spacer()

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
            Button { fontSize = min(28, fontSize + 1) } label: { Image(systemName: "textformat.size.larger") }
                .help("Zoom in")

            Button { wrapsLines.toggle() } label: {
                Image(systemName: wrapsLines ? "text.alignleft" : "text.append")
            }
            .help(wrapsLines ? "Word wrap on" : "Word wrap off")

            Button { showGoToLine = true } label: { Image(systemName: "arrow.right.to.line") }
                .help("Go to line")

            Button { save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .buttonStyle(.borderedProminent)
                .disabled(!isDirty || loadError != nil)
                .help("Save (⌘S)")

            Button { attemptClose() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .help("Close editor")
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
        language = CodeLanguage.detect(for: target.url)
        let url = target.url
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
            guard target.url == url else { return }
            if let failure = outcome.error {
                loadError = failure
            } else {
                text = outcome.text ?? ""
                savedText = text
            }
        }
    }

    private func save() {
        guard loadError == nil else { return }
        let url = target.url
        let contents = text
        do {
            try contents.data(using: .utf8)?.write(to: url, options: .atomic)
            savedText = contents
            appState.activePane.refresh()
        } catch {
            appState.lastError = error.localizedDescription
        }
    }

    private func attemptClose() {
        if isDirty {
            showDiscardConfirm = true
        } else {
            close()
        }
    }

    private func close() {
        appState.editingTextFile = nil
    }
}
