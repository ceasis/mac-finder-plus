import AppKit
import SwiftUI

/// A full NSTextView-backed code editor: line-number ruler, native find/replace
/// (⌘F / ⌥⌘F, regex-capable), syntax highlighting, auto-indent, and Notepad++-
/// style line commands. Editor commands are caught in performKeyEquivalent so
/// they win over the app's menu shortcuts while the editor is focused.
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    var language: CodeLanguage
    var fontSize: CGFloat
    var wrapsLines: Bool
    @Binding var pendingGoToLine: Int?
    var onSave: () -> Void
    var onCursorChange: (_ line: Int, _ column: Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = EditorTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? EditorTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.isRichText = false
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
        context.coordinator.configure(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.parent = self
        textView.onSave = onSave
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.configure(textView)
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
