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
        .onChange(of: selectedTab) { _, newTab in
            if newTab == .viewer { renderViewer() }
        }
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
            .help("Save (⌘S)")
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
                } else if isDirty {
                    Label("Modified", systemImage: "circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.orange)
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
            } catch {
                guard item.url == url else { return }
                isSaving = false
                saveError = error.localizedDescription
                appState.lastError = error.localizedDescription
            }
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

    private var rendered: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    }

    var body: some View {
        ScrollView {
            Text(rendered)
                .textSelection(.enabled)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
        }
        .background(Color(nsColor: .textBackgroundColor))
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
