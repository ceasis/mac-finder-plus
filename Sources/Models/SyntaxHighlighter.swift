import AppKit

/// Languages the editor can syntax-highlight, detected from a file extension.
enum CodeLanguage: String, CaseIterable, Identifiable, Sendable {
    case plain, swift, javascript, python, cLike, json, markdown, shell, web, css, yaml

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plain: "Plain Text"
        case .swift: "Swift"
        case .javascript: "JavaScript"
        case .python: "Python"
        case .cLike: "C / C++ / Java"
        case .json: "JSON"
        case .markdown: "Markdown"
        case .shell: "Shell"
        case .web: "HTML / XML"
        case .css: "CSS"
        case .yaml: "YAML"
        }
    }

    static func detect(for url: URL) -> CodeLanguage {
        switch url.pathExtension.lowercased() {
        case "swift": return .swift
        case "js", "mjs", "jsx", "ts", "tsx": return .javascript
        case "py": return .python
        case "c", "h", "cc", "cpp", "hpp", "cxx", "m", "mm", "java", "kt", "cs", "go", "rs":
            return .cLike
        case "json", "ndjson": return .json
        case "md", "markdown": return .markdown
        case "sh", "bash", "zsh", "fish": return .shell
        case "html", "htm", "xml", "svg", "vue", "svelte": return .web
        case "css", "scss", "sass", "less": return .css
        case "yaml", "yml", "toml": return .yaml
        default: return .plain
        }
    }

    var lineComment: String? {
        switch self {
        case .python, .shell, .yaml: "#"
        case .swift, .javascript, .cLike, .css: "//"
        default: nil
        }
    }

    var blockComment: (open: String, close: String)? {
        switch self {
        case .swift, .javascript, .cLike, .css: ("/*", "*/")
        case .web: ("<!--", "-->")
        default: nil
        }
    }

    var keywords: Set<String> {
        switch self {
        case .swift:
            return ["func", "let", "var", "if", "else", "guard", "for", "while", "return",
                    "struct", "class", "enum", "protocol", "extension", "import", "switch",
                    "case", "default", "in", "self", "nil", "true", "false", "public",
                    "private", "internal", "static", "throws", "try", "await", "async",
                    "where", "init", "deinit", "some", "any", "override", "final", "weak"]
        case .javascript:
            return ["function", "let", "const", "var", "if", "else", "for", "while", "return",
                    "class", "extends", "import", "export", "from", "switch", "case", "default",
                    "new", "this", "null", "undefined", "true", "false", "async", "await",
                    "try", "catch", "throw", "typeof", "instanceof", "of", "in"]
        case .python:
            return ["def", "class", "if", "elif", "else", "for", "while", "return", "import",
                    "from", "as", "with", "try", "except", "finally", "raise", "lambda",
                    "None", "True", "False", "and", "or", "not", "in", "is", "pass", "break",
                    "continue", "yield", "global", "async", "await", "self"]
        case .cLike:
            return ["int", "char", "float", "double", "void", "long", "short", "unsigned",
                    "if", "else", "for", "while", "return", "struct", "class", "enum", "switch",
                    "case", "default", "break", "continue", "public", "private", "protected",
                    "static", "const", "new", "delete", "this", "null", "nullptr", "true",
                    "false", "namespace", "template", "typename", "using", "include", "import",
                    "func", "package", "type", "var", "let", "fn", "impl"]
        case .shell:
            return ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case",
                    "esac", "function", "return", "echo", "export", "local", "in"]
        case .web, .css, .json, .yaml, .markdown, .plain:
            return []
        }
    }
}

/// Applies syntax coloring to an NSTextStorage. Regex-based and re-run on edits,
/// so it skips very large documents to keep typing responsive.
enum SyntaxHighlighter {
    private static let sizeLimit = 400_000

    static func highlight(_ storage: NSTextStorage, language: CodeLanguage, fontSize: CGFloat) {
        let full = NSRange(location: 0, length: storage.length)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor], range: full)

        if language != .plain, storage.length <= sizeLimit {
            let text = storage.string
            apply(pattern: numberPattern, color: .systemPurple, to: storage, text: text)
            colorKeywords(language.keywords, color: .systemPink, storage: storage, text: text)
            colorStrings(storage: storage, text: text)
            colorComments(language: language, storage: storage, text: text)
        }
        storage.endEditing()
    }

    private static let numberPattern = "\\b[0-9]+(\\.[0-9]+)?\\b"

    private static func apply(pattern: String, color: NSColor, to storage: NSTextStorage, text: String) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(location: 0, length: (text as NSString).length)
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: color, range: r)
            }
        }
    }

    private static func colorKeywords(_ keywords: Set<String>, color: NSColor, storage: NSTextStorage, text: String) {
        guard !keywords.isEmpty else { return }
        let escaped = keywords.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        apply(pattern: "\\b(\(escaped))\\b", color: color, to: storage, text: text)
    }

    private static func colorStrings(storage: NSTextStorage, text: String) {
        // Double- and single-quoted strings (no multiline).
        apply(pattern: "\"(\\\\.|[^\"\\\\\\n])*\"", color: .systemRed, to: storage, text: text)
        apply(pattern: "'(\\\\.|[^'\\\\\\n])*'", color: .systemRed, to: storage, text: text)
    }

    private static func colorComments(language: CodeLanguage, storage: NSTextStorage, text: String) {
        let commentColor = NSColor.systemGreen
        if let line = language.lineComment {
            let escaped = NSRegularExpression.escapedPattern(for: line)
            apply(pattern: "\(escaped).*", color: commentColor, to: storage, text: text)
        }
        if let block = language.blockComment {
            let open = NSRegularExpression.escapedPattern(for: block.open)
            let close = NSRegularExpression.escapedPattern(for: block.close)
            apply(
                pattern: "\(open)[\\s\\S]*?\(close)",
                color: commentColor, to: storage, text: text
            )
        }
    }
}
