import SwiftUI
@preconcurrency import WebKit

private enum TextDocumentEditorTab: Hashable {
    case text
    case viewer
}

/// Inline, file-backed editor used by Preview. Text is always the first tab;
/// Markdown and structured formats get a second, type-aware view of the current
/// (including unsaved) editor contents.
struct TextDocumentEditorView: View {
    @Environment(AppState.self) private var appState
    let item: FileItem

    @State private var selectedTab = TextDocumentEditorTab.text
    @State private var text = ""
    @State private var savedText = ""
    @State private var encoding = TextDocumentEncoding.utf8
    @State private var lineEnding = TextDocumentLineEnding.lf
    @State private var loadedModificationDate: Date?
    @State private var language = CodeLanguage.plain
    @State private var wrapsLines = true
    @State private var fontSize: CGFloat = 13
    @State private var line = 1
    @State private var column = 1
    @State private var pendingGoToLine: Int?
    @State private var showsGoToLine = false
    @State private var goToLineText = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var showsExternalChangeAlert = false
    @State private var viewerResult: TextDocumentViewerResult?
    @State private var viewerGeneration = UUID()
    @State private var isRenderingViewer = false
    @State private var autosaveTask: Task<Void, Never>?
    @StateObject private var undoController = CodeTextViewUndoController()

    private var viewerKind: TextDocumentViewerKind? {
        TextDocumentViewerKind.detect(for: item.url)
    }

    private var isDirty: Bool { text != savedText }

    var body: some View {
        VStack(spacing: 0) {
            editorToolbar
            Divider()
            editorContent
            Divider()
            statusBar
        }
        .background(.background)
        .task(id: item.id) { await loadDocument() }
        .onChange(of: text) { _, _ in scheduleAutosave() }
        .onChange(of: selectedTab) { _, newTab in
            if newTab == .viewer { renderViewer() }
        }
        .onDisappear { commitPendingAutosave() }
        .alert("File Changed on Disk", isPresented: $showsExternalChangeAlert) {
            Button("Reload from Disk") {
                Task { await loadDocument() }
            }
            Button("Replace File", role: .destructive) {
                save(force: true)
            }
        } message: {
            Text("Another app changed this file after Workbench opened it. Reload their version, or replace it with your current edits.")
        }
    }

    private var editorToolbar: some View {
        HStack(spacing: 8) {
            Picker("View", selection: $selectedTab) {
                Text("Text").tag(TextDocumentEditorTab.text)
                if let viewerKind {
                    Text(viewerKind.tabTitle).tag(TextDocumentEditorTab.viewer)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()

            Spacer(minLength: 4)

            if selectedTab == .text, !isLoading, loadError == nil {
                Menu {
                    Picker("Syntax", selection: $language) {
                        ForEach(CodeLanguage.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                } label: {
                    Label(language.title, systemImage: "curlybraces")
                        .lineLimit(1)
                }
                .help("Syntax highlighting")

                Button {
                    fontSize = max(9, fontSize - 1)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .help("Smaller text")

                Button {
                    fontSize = min(28, fontSize + 1)
                } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .help("Larger text")

                Button {
                    wrapsLines.toggle()
                } label: {
                    Image(systemName: wrapsLines ? "text.alignleft" : "text.append")
                }
                .help(wrapsLines ? "Turn word wrap off" : "Turn word wrap on")

                Button {
                    goToLineText = ""
                    showsGoToLine = true
                } label: {
                    Image(systemName: "arrow.right.to.line")
                }
                .help("Go to line")
                .popover(isPresented: $showsGoToLine, arrowEdge: .top) {
                    goToLinePopover
                }

                Button {
                    undoController.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!undoController.canUndo)
                .help("Undo (⌘Z)")

                Button {
                    undoController.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!undoController.canRedo)
                .help("Redo (⇧⌘Z)")
            }

            Button {
                save()
            } label: {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isDirty || isSaving || isLoading || loadError != nil)
            .help("Save now (⌘S) · Changes also save automatically")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.bar)
    }

    @ViewBuilder
    private var editorContent: some View {
        if isLoading {
            ProgressView("Opening text file…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            ContentUnavailableView(
                "Can’t Open File",
                systemImage: "doc.questionmark",
                description: Text(loadError)
            )
        } else if selectedTab == .text {
            CodeTextView(
                text: $text,
                language: language,
                fontSize: fontSize,
                wrapsLines: wrapsLines,
                requestsInitialFocus: true,
                undoController: undoController,
                pendingGoToLine: $pendingGoToLine,
                onSave: { save() },
                onCursorChange: { line = $0; column = $1 }
            )
            .clipped()
        } else {
            viewerContent
        }
    }

    @ViewBuilder
    private var viewerContent: some View {
        if isRenderingViewer {
            ProgressView("Preparing \(viewerKind?.tabTitle ?? "preview")…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let viewerKind, let viewerResult {
            VStack(spacing: 0) {
                if let error = viewerResult.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.orange.opacity(0.08))
                    Divider()
                }

                switch viewerKind {
                case .markdown:
                    MarkdownDocumentPreview(source: viewerResult.text)
                case .html:
                    HTMLDocumentPreview(
                        source: viewerResult.text,
                        baseURL: item.url.deletingLastPathComponent()
                    )
                case .json:
                    ReadOnlyCodePreview(
                        text: viewerResult.text,
                        language: .json,
                        fontSize: fontSize,
                        wrapsLines: wrapsLines,
                        onSave: { save() }
                    )
                case .xml:
                    ReadOnlyCodePreview(
                        text: viewerResult.text,
                        language: .web,
                        fontSize: fontSize,
                        wrapsLines: wrapsLines,
                        onSave: { save() }
                    )
                case .yaml:
                    ReadOnlyCodePreview(
                        text: viewerResult.text,
                        language: .yaml,
                        fontSize: fontSize,
                        wrapsLines: wrapsLines,
                        onSave: { save() }
                    )
                }
            }
        } else {
            ContentUnavailableView("No Viewer", systemImage: "doc.text")
        }
    }

    private var statusBar: some View {
        ZStack {
            HStack(spacing: 10) {
                if selectedTab == .text, !isLoading, loadError == nil {
                    Text("Ln \(line), Col \(column)")
                }
                Text(encoding.title)
                Text(lineEnding.title)
                Spacer()
            }

            Group {
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .help(saveError)
                } else if isSaving {
                    Label("Saving…", systemImage: "arrow.triangle.2.circlepath")
                } else if isDirty {
                    Label("Autosaving…", systemImage: "clock")
                } else if !isLoading, loadError == nil {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var goToLinePopover: some View {
        HStack(spacing: 8) {
            TextField("Line", text: $goToLineText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 84)
                .onSubmit { goToLine() }
            Button(action: goToLine) {
                Image(systemName: "arrow.right")
            }
            .buttonStyle(.borderedProminent)
            .help("Go")
            Button {
                showsGoToLine = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close")
        }
        .padding(10)
    }

    private func goToLine() {
        guard let value = Int(goToLineText), value > 0 else { return }
        pendingGoToLine = value
        showsGoToLine = false
    }

    @MainActor
    private func loadDocument() async {
        autosaveTask?.cancel()
        autosaveTask = nil
        let url = item.url
        selectedTab = .text
        language = CodeLanguage.detect(for: url)
        isLoading = true
        loadError = nil
        saveError = nil
        viewerResult = nil
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try TextDocumentCodec.load(from: url)
            }.value
            try Task.checkCancellation()
            guard item.url == url else { return }
            text = loaded.text
            savedText = loaded.text
            encoding = loaded.encoding
            lineEnding = loaded.lineEnding
            loadedModificationDate = loaded.modificationDate
            line = 1
            column = 1
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard item.url == url else { return }
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    private func save(force: Bool = false) {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard !isLoading, loadError == nil, !isSaving, isDirty else { return }
        let url = item.url
        let contents = text
        let documentEncoding = encoding
        let documentLineEnding = lineEnding
        let originalModificationDate = loadedModificationDate
        isSaving = true
        saveError = nil

        Task {
            do {
                if !force {
                    let changedExternally = try await Task.detached(priority: .userInitiated) {
                        try TextDocumentCodec.wasModifiedExternally(
                            at: url,
                            since: originalModificationDate
                        )
                    }.value
                    guard item.url == url else { return }
                    if changedExternally {
                        isSaving = false
                        showsExternalChangeAlert = true
                        return
                    }
                }

                let modificationDate = try await Task.detached(priority: .userInitiated) {
                    try TextDocumentCodec.save(
                        contents,
                        to: url,
                        encoding: documentEncoding,
                        lineEnding: documentLineEnding
                    )
                }.value
                guard item.url == url else { return }
                savedText = contents
                loadedModificationDate = modificationDate
                isSaving = false
                appState.activePane.refresh()
                if isDirty {
                    scheduleAutosave()
                }
            } catch {
                guard item.url == url else { return }
                isSaving = false
                saveError = error.localizedDescription
                appState.lastError = error.localizedDescription
            }
        }
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard !isLoading, loadError == nil, isDirty else {
            autosaveTask = nil
            return
        }
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, isDirty else { return }
            save()
        }
    }

    private func commitPendingAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
        if isDirty {
            save()
        }
    }

    private func renderViewer() {
        guard let viewerKind else { return }
        let source = text
        let generation = UUID()
        viewerGeneration = generation
        isRenderingViewer = true
        viewerResult = nil

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                TextDocumentViewerFormatter.format(source, as: viewerKind)
            }.value
            guard viewerGeneration == generation else { return }
            viewerResult = result
            isRenderingViewer = false
        }
    }
}

private struct ReadOnlyCodePreview: View {
    let text: String
    let language: CodeLanguage
    let fontSize: CGFloat
    let wrapsLines: Bool
    let onSave: () -> Void

    var body: some View {
        CodeTextView(
            text: .constant(text),
            language: language,
            fontSize: fontSize,
            wrapsLines: wrapsLines,
            isEditable: false,
            pendingGoToLine: .constant(nil),
            onSave: onSave,
            onCursorChange: { _, _ in }
        )
        .clipped()
    }
}

private struct MarkdownDocumentPreview: View {
    let source: String

    private var blocks: [MarkdownPreviewBlock] {
        MarkdownPreviewParser.blocks(from: source)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if blocks.isEmpty {
                    Text("Empty Markdown document")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        MarkdownBlockView(block: block)
                    }
                }
            }
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownPreviewBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(inlineMarkdown(text))
                .font(headingFont(level))
                .fontWeight(level <= 2 ? .bold : .semibold)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? 8 : 4)

        case .paragraph(let text):
            Text(inlineMarkdown(text))
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.body)
                            .frame(width: 18, alignment: .trailing)
                        Text(inlineMarkdown(item))
                            .font(.body)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 2)

        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(offset + 1).")
                            .font(.body.monospacedDigit())
                            .frame(width: 28, alignment: .trailing)
                        Text(inlineMarkdown(item))
                            .font(.body)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 2)

        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 6) {
                if let language {
                    Text(language)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(text.isEmpty ? " " : text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
            )

        case .blockquote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: 4)
                Text(inlineMarkdown(text))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)

        case .divider:
            Divider()
                .padding(.vertical, 6)
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:
            return .title2
        case 2:
            return .title3
        case 3:
            return .headline
        default:
            return .subheadline
        }
    }
}

private struct HTMLDocumentPreview: NSViewRepresentable {
    let source: String
    let baseURL: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .textBackgroundColor
        load(webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        load(webView, coordinator: context.coordinator)
    }

    private func load(_ webView: WKWebView, coordinator: Coordinator) {
        let key = "\(baseURL.path)\u{0}\(source)"
        guard coordinator.lastContentKey != key else { return }
        coordinator.lastContentKey = key
        webView.loadHTMLString(source, baseURL: baseURL)
    }

    final class Coordinator {
        var lastContentKey = ""
    }
}
