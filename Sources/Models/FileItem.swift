import AppKit
import Foundation
import UniformTypeIdentifiers

/// Value-type row model for one entry in a directory listing.
struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isHidden: Bool
    /// Bytes. -1 means unknown (folders, until "Calculate Size" runs).
    var size: Int64
    let created: Date
    let modified: Date
    let kind: String
    let contentType: UTType?
    var rating: Int

    var id: String { url.path }

    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey,
        .localizedTypeDescriptionKey, .isHiddenKey, .contentTypeKey,
        .tagNamesKey,
    ]

    static func make(url: URL) -> FileItem {
        let values = try? url.resourceValues(forKeys: Set(resourceKeys))
        let isDirectory = values?.isDirectory ?? false
        return FileItem(
            url: url,
            name: url.lastPathComponent,
            isDirectory: isDirectory,
            isHidden: values?.isHidden ?? false,
            size: isDirectory ? -1 : Int64(values?.fileSize ?? 0),
            created: values?.creationDate ?? values?.contentModificationDate ?? .distantPast,
            modified: values?.contentModificationDate ?? .distantPast,
            kind: values?.localizedTypeDescription ?? (isDirectory ? "Folder" : "Document"),
            contentType: values?.contentType,
            rating: isDirectory ? 0 : FileRatingStore.rating(for: url, finderTags: values?.tagNames)
        )
    }

    var isImage: Bool {
        contentType?.conforms(to: .image) == true
    }

    var isPlayableMedia: Bool {
        guard let contentType else { return false }
        return contentType.conforms(to: .movie)
            || contentType.conforms(to: .video)
            || contentType.conforms(to: .audio)
    }

    var isVideoMedia: Bool {
        guard let contentType else { return false }
        return contentType.conforms(to: .movie)
            || contentType.conforms(to: .video)
    }

    var isAudioMedia: Bool {
        contentType?.conforms(to: .audio) == true
    }

    var isSpreadsheet: Bool {
        let fileExtension = url.pathExtension.lowercased()
        if Self.spreadsheetExtensions.contains(fileExtension) { return true }
        return contentType?.conforms(to: .spreadsheet) == true
    }

    var isDelimitedSpreadsheet: Bool {
        Self.delimitedSpreadsheetExtensions.contains(url.pathExtension.lowercased())
    }

    var isJSONFile: Bool {
        !isDirectory && Self.jsonExtensions.contains(url.pathExtension.lowercased())
    }

    var isApplicationBundle: Bool {
        isDirectory && url.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame
    }

    var isDiskImage: Bool {
        !isDirectory && Self.diskImageExtensions.contains(url.pathExtension.lowercased())
    }

    var isInstallerPackage: Bool {
        Self.installerExtensions.contains(url.pathExtension.lowercased())
    }

    var isPresentation: Bool {
        let fileExtension = url.pathExtension.lowercased()
        if Self.presentationExtensions.contains(fileExtension) { return true }
        return contentType?.conforms(to: .presentation) == true
    }

    var isFontFile: Bool {
        !isDirectory && Self.fontExtensions.contains(url.pathExtension.lowercased())
    }

    var isEPUB: Bool {
        !isDirectory && (url.pathExtension.localizedCaseInsensitiveCompare("epub") == .orderedSame
            || contentType?.conforms(to: .epub) == true)
    }

    var isArchive: Bool {
        isZipArchive || Self.archiveExtensions.contains(url.pathExtension.lowercased())
    }

    var isContactCard: Bool {
        !isDirectory && Self.contactCardExtensions.contains(url.pathExtension.lowercased())
    }

    var isToolPackage: Bool {
        isApplicationBundle || isSpreadsheet || isPresentation || isInstallerPackage
    }

    var isPreviewable: Bool {
        isImage || isPlayableMedia
    }

    /// Text, source code, and common config/data formats — shown in the custom
    /// monospaced text preview. Combines UTType conformance (which covers most
    /// source code, JSON, XML, CSV) with an extension whitelist for formats that
    /// don't carry a text-conforming type (logs, markdown, dotfiles, subtitles).
    var isText: Bool {
        if isDirectory { return false }
        // RTF conforms to .text but should be rendered by Quick Look, not shown
        // as raw markup — let rich documents win.
        if isRichDocument { return false }
        if let contentType, contentType.conforms(to: .text) { return true }
        return Self.textExtensions.contains(url.pathExtension.lowercased())
    }

    private static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "rst", "log", "csv", "tsv", "json", "ndjson",
        "xml", "yaml", "yml", "toml", "ini", "conf", "cfg", "env", "properties",
        "swift", "js", "mjs", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "php",
        "c", "h", "cc", "cpp", "hpp", "cxx", "m", "mm", "java", "kt", "kts", "scala",
        "cs", "sh", "bash", "zsh", "fish", "pl", "lua", "r", "sql", "html", "htm",
        "css", "scss", "sass", "less", "vue", "svelte", "gradle", "dockerfile",
        "gitignore", "gitattributes", "editorconfig", "srt", "vtt", "tex", "bib",
    ]

    private static let spreadsheetExtensions: Set<String> = [
        "csv", "numbers", "tsv", "xls", "xlsx",
    ]

    private static let delimitedSpreadsheetExtensions: Set<String> = ["csv", "tsv"]
    private static let jsonExtensions: Set<String> = ["json", "ndjson"]
    private static let diskImageExtensions: Set<String> = ["dmg", "iso"]
    private static let installerExtensions: Set<String> = ["mpkg", "pkg"]
    private static let presentationExtensions: Set<String> = ["key", "ppt", "pptx"]
    private static let fontExtensions: Set<String> = ["otf", "ttc", "ttf"]
    private static let archiveExtensions: Set<String> = ["bz2", "gz", "tar", "tbz", "tgz", "txz", "xz"]
    private static let contactCardExtensions: Set<String> = ["vcard", "vcf"]

    /// Document types Quick Look renders well (PDF, RTF, Office, ePub). Routed
    /// to the QLPreviewView fallback rather than the icon-only generic preview.
    var isRichDocument: Bool {
        if isDirectory { return false }
        if let contentType {
            let types: [UTType] = [.pdf, .rtf, .rtfd, .presentation, .spreadsheet, .epub]
            if types.contains(where: { contentType.conforms(to: $0) }) { return true }
        }
        return Self.richDocumentExtensions.contains(url.pathExtension.lowercased())
    }

    private static let richDocumentExtensions: Set<String> = [
        "pdf", "rtf", "rtfd", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "pages", "numbers", "key", "epub",
    ]

    var isZipArchive: Bool {
        if url.pathExtension.localizedCaseInsensitiveCompare("zip") == .orderedSame {
            return true
        }
        guard let contentType, let zipType = UTType(filenameExtension: "zip") else {
            return false
        }
        return contentType.conforms(to: zipType)
    }

    var sizeText: String {
        size < 0 ? "—" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var ratingText: String {
        rating == 0 ? "Unrated" : "\(rating) star\(rating == 1 ? "" : "s")"
    }

    /// NSWorkspace icon lookups hit the disk and are far too slow to run per
    /// row per render, so cache by file type. Only .app bundles (which carry
    /// unique icons) are cached per path.
    // NSCache is internally thread-safe; the annotation satisfies strict
    // concurrency checking for this shared read-through cache.
    nonisolated(unsafe) private static let iconCache = NSCache<NSString, NSImage>()

    var icon: NSImage {
        let ext = url.pathExtension.lowercased()
        let key: String
        if isDirectory {
            key = ext.isEmpty ? "__folder__" : (ext == "app" ? url.path : "__dir__.\(ext)")
        } else {
            key = ext.isEmpty ? url.path : "file.\(ext)"
        }
        if let cached = Self.iconCache.object(forKey: key as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        Self.iconCache.setObject(image, forKey: key as NSString)
        return image
    }
}
