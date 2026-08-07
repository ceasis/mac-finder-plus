import Foundation

enum TextEditorSession: Identifiable, Sendable {
    case file(FileItem)
    case untitled(UUID)

    var id: String {
        switch self {
        case .file(let item): "file:\(item.id)"
        case .untitled(let id): "untitled:\(id.uuidString)"
        }
    }

    var file: FileItem? {
        guard case .file(let item) = self else { return nil }
        return item
    }

    var isUntitled: Bool { file == nil }

    static func launch(from items: [FileItem], untitledID: UUID = UUID()) -> TextEditorSession {
        if let target = items.first(where: \.isText)
            ?? items.first(where: { !$0.isDirectory }) {
            return .file(target)
        }
        return .untitled(untitledID)
    }
}

enum TextDocumentViewerKind: String, Equatable, Sendable {
    case markdown
    case json
    case xml
    case html
    case yaml

    static func detect(for url: URL) -> TextDocumentViewerKind? {
        switch url.pathExtension.lowercased() {
        case "md", "markdown": .markdown
        case "json": .json
        case "xml": .xml
        case "html", "htm": .html
        case "yaml", "yml": .yaml
        default: nil
        }
    }

    var tabTitle: String {
        switch self {
        case .markdown: "MD"
        case .json: "JSON"
        case .xml: "XML"
        case .html: "HTML"
        case .yaml: "YAML"
        }
    }
}

enum TextDocumentEncoding: Equatable, Sendable {
    case utf8
    case utf8WithBOM
    case utf16LittleEndian
    case utf16BigEndian
    case isoLatin1

    var title: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf8WithBOM: "UTF-8 BOM"
        case .utf16LittleEndian: "UTF-16 LE"
        case .utf16BigEndian: "UTF-16 BE"
        case .isoLatin1: "Latin-1"
        }
    }
}

enum TextDocumentLineEnding: Equatable, Sendable {
    case lf
    case crlf
    case cr

    var title: String {
        switch self {
        case .lf: "LF"
        case .crlf: "CRLF"
        case .cr: "CR"
        }
    }
}

struct EditableTextDocument: Equatable, Sendable {
    let text: String
    let encoding: TextDocumentEncoding
    let lineEnding: TextDocumentLineEnding
    let modificationDate: Date?
    let byteCount: Int
}

enum TextDocumentError: LocalizedError, Equatable, Sendable {
    case fileTooLarge(actualBytes: Int, maximumBytes: Int)
    case unsupportedEncoding
    case cannotEncode(TextDocumentEncoding)

    var errorDescription: String? {
        switch self {
        case let .fileTooLarge(actualBytes, maximumBytes):
            let actual = ByteCountFormatter.string(fromByteCount: Int64(actualBytes), countStyle: .file)
            let maximum = ByteCountFormatter.string(fromByteCount: Int64(maximumBytes), countStyle: .file)
            return "This file is \(actual). The built-in editor supports files up to \(maximum) to keep Workbench responsive."
        case .unsupportedEncoding:
            return "This file’s text encoding isn’t supported."
        case let .cannotEncode(encoding):
            return "The edited text contains characters that can’t be saved as \(encoding.title)."
        }
    }
}

enum TextDocumentCodec {
    static let maximumEditableBytes = 10 * 1_024 * 1_024

    static func load(
        from url: URL,
        maximumBytes: Int = maximumEditableBytes
    ) throws -> EditableTextDocument {
        let safeMaximum = max(maximumBytes, 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let reportedSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard reportedSize <= safeMaximum else {
            throw TextDocumentError.fileTooLarge(
                actualBytes: reportedSize,
                maximumBytes: safeMaximum
            )
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: safeMaximum + 1) ?? Data()
        guard data.count <= safeMaximum else {
            throw TextDocumentError.fileTooLarge(
                actualBytes: data.count,
                maximumBytes: safeMaximum
            )
        }

        let decoded = try decode(data)
        return EditableTextDocument(
            text: decoded.text,
            encoding: decoded.encoding,
            lineEnding: detectLineEnding(in: decoded.text),
            modificationDate: attributes[.modificationDate] as? Date,
            byteCount: data.count
        )
    }

    @discardableResult
    static func save(
        _ text: String,
        to url: URL,
        encoding: TextDocumentEncoding,
        lineEnding: TextDocumentLineEnding
    ) throws -> Date? {
        let normalizedText = normalize(text, to: lineEnding)
        let data = try encode(normalizedText, as: encoding)
        try data.write(to: url, options: .atomic)
        return try modificationDate(for: url)
    }

    static func modificationDate(for url: URL) throws -> Date? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.modificationDate] as? Date
    }

    static func wasModifiedExternally(
        at url: URL,
        since loadedModificationDate: Date?
    ) throws -> Bool {
        guard let loadedModificationDate,
              let current = try modificationDate(for: url) else { return false }
        return abs(current.timeIntervalSince(loadedModificationDate)) > 0.001
    }

    private static func decode(_ data: Data) throws -> (text: String, encoding: TextDocumentEncoding) {
        let utf8BOM = Data([0xEF, 0xBB, 0xBF])
        if data.starts(with: utf8BOM),
           let text = String(data: data.dropFirst(utf8BOM.count), encoding: .utf8) {
            return (text, .utf8WithBOM)
        }

        let utf16LEBOM = Data([0xFF, 0xFE])
        if data.starts(with: utf16LEBOM),
           let text = String(data: data.dropFirst(utf16LEBOM.count), encoding: .utf16LittleEndian) {
            return (text, .utf16LittleEndian)
        }

        let utf16BEBOM = Data([0xFE, 0xFF])
        if data.starts(with: utf16BEBOM),
           let text = String(data: data.dropFirst(utf16BEBOM.count), encoding: .utf16BigEndian) {
            return (text, .utf16BigEndian)
        }

        if let text = String(data: data, encoding: .utf8) {
            return (text, .utf8)
        }
        if let text = String(data: data, encoding: .isoLatin1) {
            return (text, .isoLatin1)
        }
        throw TextDocumentError.unsupportedEncoding
    }

    private static func encode(
        _ text: String,
        as encoding: TextDocumentEncoding
    ) throws -> Data {
        let data: Data?
        switch encoding {
        case .utf8:
            data = text.data(using: .utf8)
        case .utf8WithBOM:
            guard let body = text.data(using: .utf8) else { data = nil; break }
            data = Data([0xEF, 0xBB, 0xBF]) + body
        case .utf16LittleEndian:
            guard let body = text.data(using: .utf16LittleEndian) else { data = nil; break }
            data = Data([0xFF, 0xFE]) + body
        case .utf16BigEndian:
            guard let body = text.data(using: .utf16BigEndian) else { data = nil; break }
            data = Data([0xFE, 0xFF]) + body
        case .isoLatin1:
            data = text.data(using: .isoLatin1, allowLossyConversion: false)
        }
        guard let data else { throw TextDocumentError.cannotEncode(encoding) }
        return data
    }

    private static func detectLineEnding(in text: String) -> TextDocumentLineEnding {
        if text.contains("\r\n") { return .crlf }
        if text.contains("\r") { return .cr }
        return .lf
    }

    private static func normalize(
        _ text: String,
        to lineEnding: TextDocumentLineEnding
    ) -> String {
        let lineFeedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        switch lineEnding {
        case .lf: return lineFeedText
        case .crlf: return lineFeedText.replacingOccurrences(of: "\n", with: "\r\n")
        case .cr: return lineFeedText.replacingOccurrences(of: "\n", with: "\r")
        }
    }
}

struct TextDocumentViewerResult: Equatable, Sendable {
    let text: String
    let errorMessage: String?
}

enum TextDocumentViewerFormatter {
    static func format(_ source: String, as kind: TextDocumentViewerKind) -> TextDocumentViewerResult {
        switch kind {
        case .json:
            return formatJSON(source)
        case .xml:
            return formatXML(source)
        case .markdown, .html, .yaml:
            return TextDocumentViewerResult(text: source, errorMessage: nil)
        }
    }

    private static func formatJSON(_ source: String) -> TextDocumentViewerResult {
        do {
            let data = Data(source.utf8)
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let formatted = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
            )
            return TextDocumentViewerResult(
                text: String(decoding: formatted, as: UTF8.self),
                errorMessage: nil
            )
        } catch {
            return TextDocumentViewerResult(
                text: source,
                errorMessage: "Invalid JSON: \(error.localizedDescription)"
            )
        }
    }

    private static func formatXML(_ source: String) -> TextDocumentViewerResult {
        do {
            let document = try XMLDocument(data: Data(source.utf8), options: [])
            return TextDocumentViewerResult(
                text: document.xmlString(options: [.nodePrettyPrint]),
                errorMessage: nil
            )
        } catch {
            return TextDocumentViewerResult(
                text: source,
                errorMessage: "Invalid XML: \(error.localizedDescription)"
            )
        }
    }
}
