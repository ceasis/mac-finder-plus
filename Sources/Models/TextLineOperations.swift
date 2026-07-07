import Foundation

/// Pure text transforms behind the editor's Notepad++-style line commands.
/// Each takes the document text and the current selection (UTF-16 NSRange) and
/// returns the new text plus where the selection should land, so they can be
/// unit-tested independently of the NSTextView that applies them.
enum TextLineOperations {
    struct Edit: Equatable {
        let text: String
        let selection: NSRange
    }

    /// Duplicates the line(s) touched by the selection, placing the copy below.
    static func duplicate(_ text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: clamp(selection, length: ns.length))
        let lineText = ns.substring(with: lineRange)
        let insert = lineText.hasSuffix("\n") ? lineText : "\n" + lineText
        let out = ns.replacingCharacters(
            in: NSRange(location: NSMaxRange(lineRange), length: 0), with: insert)
        let shift = (insert as NSString).length
        return Edit(text: out, selection: NSRange(location: selection.location + shift,
                                                  length: selection.length))
    }

    /// Deletes the line(s) touched by the selection.
    static func delete(_ text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: clamp(selection, length: ns.length))
        let out = ns.replacingCharacters(in: lineRange, with: "")
        let location = min(lineRange.location, (out as NSString).length)
        return Edit(text: out, selection: NSRange(location: location, length: 0))
    }

    /// Moves the selected line(s) up one line. Returns nil at the top.
    static func moveUp(_ text: String, selection: NSRange) -> Edit? {
        let (start, end) = lineSpan(text: text, selection: selection)
        guard start > 0 else { return nil }
        var lines = text.components(separatedBy: "\n")
        let block = Array(lines[start...end])
        lines.removeSubrange(start...end)
        lines.insert(contentsOf: block, at: start - 1)
        return rebuilt(lines, movedLineStart: start - 1, count: end - start + 1)
    }

    /// Moves the selected line(s) down one line. Returns nil at the bottom.
    static func moveDown(_ text: String, selection: NSRange) -> Edit? {
        let (start, end) = lineSpan(text: text, selection: selection)
        var lines = text.components(separatedBy: "\n")
        guard end < lines.count - 1 else { return nil }
        let block = Array(lines[start...end])
        lines.removeSubrange(start...end)
        lines.insert(contentsOf: block, at: start + 1)
        return rebuilt(lines, movedLineStart: start + 1, count: end - start + 1)
    }

    /// The leading whitespace of the line containing `location` — used to keep
    /// indentation when the editor inserts a newline.
    static func leadingWhitespace(_ text: String, at location: Int) -> String {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
        let line = ns.substring(with: lineRange)
        return String(line.prefix { $0 == " " || $0 == "\t" })
    }

    // MARK: - Helpers

    private static func clamp(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        let len = min(range.length, length - location)
        return NSRange(location: location, length: max(len, 0))
    }

    /// 0-based indices of the first and last lines the selection touches.
    static func lineSpan(text: String, selection: NSRange) -> (start: Int, end: Int) {
        let ns = text as NSString
        let sel = clamp(selection, length: ns.length)
        let start = ns.substring(to: sel.location).components(separatedBy: "\n").count - 1
        let lastCharIndex = sel.length > 0 ? NSMaxRange(sel) - 1 : sel.location
        let end = ns.substring(to: min(lastCharIndex, ns.length))
            .components(separatedBy: "\n").count - 1
        return (start, max(end, start))
    }

    private static func rebuilt(_ lines: [String], movedLineStart: Int, count: Int) -> Edit {
        let text = lines.joined(separator: "\n")
        let ns = text as NSString
        // Character offset of the first moved line.
        let prefix = lines[..<movedLineStart].joined(separator: "\n")
        let location = movedLineStart == 0 ? 0 : (prefix as NSString).length + 1
        let movedText = lines[movedLineStart..<(movedLineStart + count)].joined(separator: "\n")
        let selection = NSRange(location: min(location, ns.length),
                                length: min((movedText as NSString).length, ns.length - location))
        return Edit(text: text, selection: selection)
    }
}
