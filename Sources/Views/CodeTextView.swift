import AppKit
import Combine
import SwiftUI

/// A narrow bridge to the native text system's undo manager. Toolbar buttons
/// use this controller instead of relying on whichever control becomes first
/// responder after the click.
@MainActor
final class CodeTextViewUndoController: ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private weak var textView: NSTextView?

    func attach(_ textView: NSTextView) {
        guard self.textView !== textView else { return }
        self.textView = textView
        // NSViewRepresentable calls this while SwiftUI is updating the native
        // view. Publishing synchronously from that cycle causes a render loop.
        refreshAfterCurrentEvent()
    }

    func undo() {
        guard let undoManager = textView?.undoManager, undoManager.canUndo else { return }
        undoManager.undo()
        refresh()
        refreshAfterCurrentEvent()
    }

    func redo() {
        guard let undoManager = textView?.undoManager, undoManager.canRedo else { return }
        undoManager.redo()
        refresh()
        refreshAfterCurrentEvent()
    }

    func refreshAfterCurrentEvent() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.refresh()
        }
    }

    private func refresh() {
        let nextCanUndo = textView?.undoManager?.canUndo == true
        let nextCanRedo = textView?.undoManager?.canRedo == true
        if canUndo != nextCanUndo { canUndo = nextCanUndo }
        if canRedo != nextCanRedo { canRedo = nextCanRedo }
    }
}

/// A full NSTextView-backed code editor: line-number ruler, native find/replace
/// (⌘F / ⌥⌘F, regex-capable), syntax highlighting, auto-indent, and Notepad++-
/// style line commands. Editor commands are caught in performKeyEquivalent so
/// they win over the app's menu shortcuts while the editor is focused.
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    var language: CodeLanguage
    var fontSize: CGFloat
    var wrapsLines: Bool
    var isEditable = true
    var requestsInitialFocus = false
    var undoController: CodeTextViewUndoController? = nil
    @Binding var pendingGoToLine: Int?
    var onSave: () -> Void
    var onCursorChange: (_ line: Int, _ column: Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = EditorTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? EditorTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = isEditable
        textView.requestsFocusWhenAttached = requestsInitialFocus
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.allowsDocumentBackgroundColorChange = false
        textView.usesFontPanel = false
        textView.string = text
        textView.undoManager?.removeAllActions()
        textView.onSave = onSave

        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = .textBackgroundColor

        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        undoController?.attach(textView)
        context.coordinator.configure(textView)
        textView.resetDocumentPosition(requestFocus: requestsInitialFocus)
        textView.requestInitialFocusIfNeeded()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.parent = self
        textView.onSave = onSave
        textView.isEditable = isEditable
        textView.requestsFocusWhenAttached = requestsInitialFocus
        undoController?.attach(textView)
        let didReplaceDocumentText = textView.string != text
        if didReplaceDocumentText {
            textView.string = text
            textView.undoManager?.removeAllActions()
        }
        context.coordinator.configure(textView)
        if didReplaceDocumentText {
            textView.resetDocumentPosition(requestFocus: requestsInitialFocus)
        }
        textView.requestInitialFocusIfNeeded()
        if let targetLine = pendingGoToLine {
            textView.goToLine(targetLine)
            DispatchQueue.main.async { pendingGoToLine = nil }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextView
        weak var textView: EditorTextView?
        weak var ruler: LineNumberRulerView?

        init(_ parent: CodeTextView) { self.parent = parent }

        func configure(_ textView: EditorTextView) {
            let font = NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)
            textView.font = font
            ruler?.font = font

            if let container = textView.textContainer {
                if parent.wrapsLines {
                    container.widthTracksTextView = true
                    let width = textView.enclosingScrollView?.contentSize.width ?? textView.bounds.width
                    container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
                    textView.isHorizontallyResizable = false
                } else {
                    container.widthTracksTextView = false
                    container.containerSize = NSSize(
                        width: CGFloat.greatestFiniteMagnitude,
                        height: CGFloat.greatestFiniteMagnitude)
                    textView.isHorizontallyResizable = true
                    textView.maxSize = NSSize(
                        width: CGFloat.greatestFiniteMagnitude,
                        height: CGFloat.greatestFiniteMagnitude)
                }
            }
            highlight()
            ruler?.needsDisplay = true
        }

        func highlight() {
            guard let storage = textView?.textStorage else { return }
            SyntaxHighlighter.highlight(storage, language: parent.language, fontSize: parent.fontSize)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            highlight()
            ruler?.needsDisplay = true
            parent.undoController?.refreshAfterCurrentEvent()
            reportCursor()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            reportCursor()
            ruler?.needsDisplay = true
        }

        private func reportCursor() {
            guard let textView else { return }
            let ns = textView.string as NSString
            let location = min(textView.selectedRange().location, ns.length)
            let prefix = ns.substring(to: location)
            let line = prefix.components(separatedBy: "\n").count
            let lastNewline = (prefix as NSString).range(of: "\n", options: .backwards).location
            let column = lastNewline == NSNotFound ? location + 1 : location - lastNewline
            parent.onCursorChange(line, column)
        }
    }
}

/// NSTextView subclass adding auto-indent, line commands, and save/find key
/// handling that pre-empts the app menu.
final class EditorTextView: NSTextView {
    var onSave: (() -> Void)?
    var requestsFocusWhenAttached = false
    private var didRequestInitialFocus = false
    private var documentPositionResetGeneration = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestInitialFocusIfNeeded()
    }

    func requestInitialFocusIfNeeded() {
        guard requestsFocusWhenAttached,
              !didRequestInitialFocus,
              let window else { return }
        didRequestInitialFocus = true
        window.makeFirstResponder(self)
    }

    /// NSTextView moves its insertion point to the end when `string` is
    /// replaced. Reset both the caret and viewport so a newly opened document
    /// always starts at its top-left edge.
    func resetDocumentPosition(requestFocus: Bool = false) {
        documentPositionResetGeneration += 1
        let generation = documentPositionResetGeneration
        resetDocumentPositionImmediately(requestFocus: requestFocus)

        DispatchQueue.main.async { [weak self] in
            guard let self, self.documentPositionResetGeneration == generation else { return }
            self.resetDocumentPositionImmediately(requestFocus: requestFocus)
        }
    }

    private func resetDocumentPositionImmediately(requestFocus: Bool) {
        let documentStart = NSRange(location: 0, length: 0)
        setSelectedRange(documentStart)
        if requestFocus {
            requestFocusIfPossible()
        }
        if let layoutManager, let textContainer {
            layoutManager.ensureLayout(for: textContainer)
        }
        scrollRangeToVisible(documentStart)
        guard let scrollView = enclosingScrollView else { return }
        scrollView.contentView.scroll(to: topLeftClipOrigin(in: scrollView))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func requestFocusIfPossible() {
        guard let window else { return }
        didRequestInitialFocus = true
        window.makeFirstResponder(self)
    }

    private func topLeftClipOrigin(in scrollView: NSScrollView) -> NSPoint {
        let clipView = scrollView.contentView
        guard let documentView = scrollView.documentView else { return .zero }
        let documentBounds = documentView.bounds
        let visibleSize = clipView.bounds.size
        let topY = documentView.isFlipped
            ? documentBounds.minY
            : max(documentBounds.minY, documentBounds.maxY - visibleSize.height)
        let proposedBounds = NSRect(
            x: documentBounds.minX,
            y: topY,
            width: visibleSize.width,
            height: visibleSize.height
        )
        return clipView.constrainBoundsRect(proposedBounds).origin
    }

    override func insertNewline(_ sender: Any?) {
        let indent = TextLineOperations.leadingWhitespace(string, at: selectedRange().location)
        super.insertNewline(sender)
        if !indent.isEmpty {
            insertText(indent, replacementRange: selectedRange())
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()

        if flags == .command {
            switch key {
            case "s": onSave?(); return true
            case "f": runFinder(.showFindInterface); return true
            case "d": apply(TextLineOperations.duplicate(string, selection: selectedRange())); return true
            default: break
            }
        }
        if flags == [.command, .option], key == "f" {
            runFinder(.showReplaceInterface); return true
        }
        if flags == [.command, .shift], key == "k" {
            apply(TextLineOperations.delete(string, selection: selectedRange())); return true
        }
        if flags == [.command, .option] {
            if event.keyCode == 126, let edit = TextLineOperations.moveUp(string, selection: selectedRange()) {
                apply(edit); return true
            }
            if event.keyCode == 125, let edit = TextLineOperations.moveDown(string, selection: selectedRange()) {
                apply(edit); return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    func goToLine(_ oneBasedLine: Int) {
        let ns = string as NSString
        var current = 1
        var lineStart = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, lineRange, _, stop in
            if current == oneBasedLine {
                lineStart = lineRange.location
                stop.pointee = true
            }
            current += 1
        }
        let target = NSRange(location: min(lineStart, ns.length), length: 0)
        setSelectedRange(target)
        scrollRangeToVisible(target)
    }

    private func apply(_ edit: TextLineOperations.Edit) {
        let full = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: full, replacementString: edit.text) else { return }
        textStorage?.replaceCharacters(in: full, with: edit.text)
        didChangeText()
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
    }

    private func runFinder(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        performTextFinderAction(item)
    }
}

/// Draws line numbers in the scroll view's left margin.
final class LineNumberRulerView: NSRulerView {
    var font: NSFont = .monospacedSystemFont(ofSize: 11, weight: .regular) {
        didSet { needsDisplay = true }
    }

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        separator.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        separator.lineWidth = 1
        separator.stroke()

        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let content = textView.string as NSString
        let visibleRect = textView.visibleRect
        let textOrigin = textView.textContainerOrigin
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor,
        ]

        layoutManager.ensureLayout(for: container)
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let visibleChars = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)

        // Line number of the first visible line.
        var lineNumber = 1
        content.enumerateSubstrings(
            in: NSRange(location: 0, length: visibleChars.location),
            options: [.byLines, .substringNotRequired]
        ) { _, _, _, _ in lineNumber += 1 }

        var index = visibleChars.location
        while index <= NSMaxRange(visibleChars) {
            let lineRange = content.lineRange(for: NSRange(location: index, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let lineRect = glyphRange.length > 0
                ? layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
                : layoutManager.extraLineFragmentRect
            let y = lineRect.minY + textOrigin.y - visibleRect.minY

            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attributes)
            if y + size.height >= bounds.minY, y <= bounds.maxY {
                label.draw(at: NSPoint(x: ruleThickness - size.width - 5, y: y), withAttributes: attributes)
            }

            lineNumber += 1
            let next = NSMaxRange(lineRange)
            if next <= index { break }
            index = next
        }
    }
}
