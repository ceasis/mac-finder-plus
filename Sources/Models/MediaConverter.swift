import AppKit
import AVFoundation
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

struct MediaConversionOptions: Equatable {
    var imageFormat: MediaImageOutputFormat = .jpeg
    var videoCodec: MediaVideoOutputCodec = .h264
}

enum MediaImageOutputFormat: String, CaseIterable, Identifiable {
    case jpeg = "JPEG"

    var id: String { rawValue }
    var type: UTType { .jpeg }
    var filenameExtension: String { "jpg" }
}

enum MediaVideoOutputCodec: String, CaseIterable, Identifiable {
    case h264 = "H.264"
    case hevc = "HEVC"

    var id: String { rawValue }
    var filenameExtension: String { "mp4" }

    var preferredPreset: String {
        switch self {
        case .h264: AVAssetExportPresetHighestQuality
        case .hevc: AVAssetExportPresetHEVCHighestQuality
        }
    }
}

enum MediaConverter {
    static func canConvert(_ item: FileItem) -> Bool {
        item.isImage || item.isVideoMedia
    }

    @discardableResult
    static func convert(
        _ item: FileItem,
        options: MediaConversionOptions,
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> URL {
        if item.isImage {
            let output = try convertImage(item.url, format: options.imageFormat)
            await progress(1)
            return output
        }
        if item.isPlayableMedia {
            return try await convertVideo(item.url, codec: options.videoCodec, progress: progress)
        }
        throw ImageProcessing.ProcessingError(
            message: "“\(item.name)” is not an image or video file Workbench can convert."
        )
    }

    private static func convertImage(
        _ url: URL,
        format: MediaImageOutputFormat
    ) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageProcessing.ProcessingError(
                message: "“\(url.lastPathComponent)” is not a readable image."
            )
        }

        let baseName = url.deletingPathExtension().lastPathComponent
        let candidate = url.deletingLastPathComponent()
            .appendingPathComponent("\(baseName)-converted.\(format.filenameExtension)")
        let destination = FileOperations.uniqueDestination(for: candidate)
        guard let writer = CGImageDestinationCreateWithURL(
            destination as CFURL,
            format.type.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageProcessing.ProcessingError(
                message: "Couldn’t create “\(destination.lastPathComponent)”."
            )
        }

        var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        properties[kCGImageDestinationLossyCompressionQuality] = 0.9
        CGImageDestinationAddImage(writer, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(writer) else {
            try? FileManager.default.removeItem(at: destination)
            throw ImageProcessing.ProcessingError(
                message: "Couldn’t save “\(destination.lastPathComponent)”."
            )
        }
        return destination
    }

    private static func convertVideo(
        _ url: URL,
        codec: MediaVideoOutputCodec,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let export = exportSession(for: asset, codec: codec) else {
            throw ImageProcessing.ProcessingError(
                message: "“\(url.lastPathComponent)” can’t be exported with \(codec.rawValue)."
            )
        }
        let exportBox = ExportSessionBox(export)

        let baseName = url.deletingPathExtension().lastPathComponent
        let candidate = url.deletingLastPathComponent()
            .appendingPathComponent("\(baseName)-\(codec.rawValue)-converted.\(codec.filenameExtension)")
        let destination = FileOperations.uniqueDestination(for: candidate)
        export.outputURL = destination
        export.outputFileType = supportedOutputType(for: export) ?? .mp4
        export.shouldOptimizeForNetworkUse = true

        let progressTask = Task {
            while !Task.isCancelled {
                await progress(Double(exportBox.progress))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { progressTask.cancel() }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    exportBox.export {
                        continuation.resume(with: $0)
                    }
                }
            } onCancel: {
                exportBox.cancel()
            }
            await progress(1)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func exportSession(
        for asset: AVAsset,
        codec: MediaVideoOutputCodec
    ) -> AVAssetExportSession? {
        let presets = [
            codec.preferredPreset,
            AVAssetExportPresetHighestQuality,
            AVAssetExportPresetMediumQuality,
            AVAssetExportPresetPassthrough,
        ]
        for preset in presets {
            if let session = AVAssetExportSession(asset: asset, presetName: preset) {
                return session
            }
        }
        return nil
    }

    private static func supportedOutputType(for export: AVAssetExportSession) -> AVFileType? {
        if export.supportedFileTypes.contains(.mp4) {
            return .mp4
        }
        return export.supportedFileTypes.first
    }
}

enum AudioConverter {
    @discardableResult
    static func convertToM4A(
        _ item: FileItem,
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> URL {
        guard item.isAudioMedia else {
            throw ImageProcessing.ProcessingError(
                message: "“\(item.name)” is not an audio file."
            )
        }

        let asset = AVURLAsset(url: item.url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty,
              let export = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetAppleM4A
              ),
              export.supportedFileTypes.contains(.m4a) else {
            throw ImageProcessing.ProcessingError(
                message: "“\(item.name)” can’t be converted to M4A."
            )
        }

        let baseName = item.url.deletingPathExtension().lastPathComponent
        let destination = FileOperations.uniqueDestination(
            for: item.url.deletingLastPathComponent().appendingPathComponent("\(baseName)-converted.m4a")
        )
        export.outputURL = destination
        export.outputFileType = .m4a
        export.shouldOptimizeForNetworkUse = true

        let exportBox = ExportSessionBox(export)
        let progressTask = Task {
            while !Task.isCancelled {
                await progress(Double(exportBox.progress))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { progressTask.cancel() }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    exportBox.export {
                        continuation.resume(with: $0)
                    }
                }
            } onCancel: {
                exportBox.cancel()
            }
            await progress(1)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

private final class ExportSessionBox: @unchecked Sendable {
    private let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }

    var progress: Float {
        session.progress
    }

    func cancel() {
        session.cancelExport()
    }

    func export(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        session.exportAsynchronously {
            switch self.session.status {
            case .completed:
                completion(.success(()))
            case .cancelled:
                completion(.failure(CancellationError()))
            case .failed:
                completion(.failure(
                    self.session.error ?? ImageProcessing.ProcessingError(
                        message: "Couldn’t export this file."
                    )
                ))
            default:
                completion(.failure(ImageProcessing.ProcessingError(
                    message: "Couldn’t export this file."
                )))
            }
        }
    }
}

enum DocumentPDFConverter {
    private static let supportedExtensions: Set<String> = [
        "doc", "docx", "html", "htm", "odt", "pages", "rtf", "rtfd",
    ]

    static func canConvert(_ item: FileItem) -> Bool {
        guard !item.isDirectory,
              item.contentType?.conforms(to: .pdf) != true else {
            return false
        }
        return item.isText || supportedExtensions.contains(item.url.pathExtension.lowercased())
    }

    @discardableResult
    static func convert(_ item: FileItem) async throws -> URL {
        if item.url.pathExtension.localizedCaseInsensitiveCompare("pages") == .orderedSame {
            return try await MainActor.run {
                try convertPagesDocument(at: item.url)
            }
        }

        return try await MainActor.run {
            try convertDocument(at: item.url)
        }
    }

    @MainActor
    private static func convertPagesDocument(at url: URL) throws -> URL {
        guard NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.iWork.Pages"
        ) != nil else {
            throw ImageProcessing.ProcessingError(
                message: "Pages is required to convert “\(url.lastPathComponent)” to PDF."
            )
        }

        let baseName = url.deletingPathExtension().lastPathComponent
        let destination = FileOperations.uniqueDestination(
            for: url.deletingLastPathComponent().appendingPathComponent("\(baseName)-converted.pdf")
        )
        let sourcePath = escapedAppleScriptPath(url.path)
        let destinationPath = escapedAppleScriptPath(destination.path)
        let scriptSource = """
        set sourceFile to POSIX file "\(sourcePath)"
        set destinationFile to POSIX file "\(destinationPath)"
        tell application id "com.apple.iWork.Pages"
            set sourceDocument to open sourceFile
            export sourceDocument to destinationFile as PDF
            close sourceDocument saving no
        end tell
        """

        var error: NSDictionary?
        let result = NSAppleScript(source: scriptSource)?.executeAndReturnError(&error)
        guard result != nil,
              FileManager.default.fileExists(atPath: destination.path) else {
            let message = error?[NSAppleScript.errorMessage] as? String
            throw ImageProcessing.ProcessingError(
                message: message ?? "Pages couldn’t convert “\(url.lastPathComponent)” to PDF."
            )
        }
        return destination
    }

    private static func escapedAppleScriptPath(_ path: String) -> String {
        path
            .replacing("\\", with: "\\\\")
            .replacing("\"", with: "\\\"")
    }

    @MainActor
    private static func convertDocument(at url: URL) throws -> URL {
        let attributedText: NSAttributedString
        do {
            attributedText = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        } catch {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw ImageProcessing.ProcessingError(
                    message: "“\(url.lastPathComponent)” can’t be read as a printable document."
                )
            }
            attributedText = NSAttributedString(
                string: text,
                attributes: [.font: NSFont.systemFont(ofSize: 12)]
            )
        }

        let pageSize = NSSize(width: 612, height: 792)
        let margin: CGFloat = 54
        let printableWidth = pageSize.width - margin * 2
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: printableWidth, height: pageSize.height))
        textView.isEditable = false
        textView.isSelectable = false
        textView.textStorage?.setAttributedString(attributedText)
        textView.textContainer?.containerSize = NSSize(
            width: printableWidth,
            height: .greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        if let textContainer = textView.textContainer,
           let layoutManager = textView.layoutManager {
            layoutManager.ensureLayout(for: textContainer)
            let contentHeight = max(pageSize.height, layoutManager.usedRect(for: textContainer).height)
            textView.frame.size.height = ceil(contentHeight)
        }

        let printInfo = NSPrintInfo()
        printInfo.paperSize = pageSize
        printInfo.leftMargin = margin
        printInfo.rightMargin = margin
        printInfo.topMargin = margin
        printInfo.bottomMargin = margin
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic

        let baseName = url.deletingPathExtension().lastPathComponent
        let destination = FileOperations.uniqueDestination(
            for: url.deletingLastPathComponent().appendingPathComponent("\(baseName)-converted.pdf")
        )
        let pdfData = NSMutableData()
        let operation = NSPrintOperation.pdfOperation(
            with: textView,
            inside: textView.bounds,
            to: pdfData,
            printInfo: printInfo
        )
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else {
            try? FileManager.default.removeItem(at: destination)
            throw ImageProcessing.ProcessingError(
                message: "Couldn’t create “\(destination.lastPathComponent)”."
            )
        }
        do {
            try pdfData.write(to: destination, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw ImageProcessing.ProcessingError(
                message: "Couldn’t save “\(destination.lastPathComponent)”."
            )
        }
        return destination
    }
}

@MainActor
enum PDFTools {
    struct PDFToolsError: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    static func isPDF(_ item: FileItem) -> Bool {
        !item.isDirectory && (
            item.contentType?.conforms(to: .pdf) == true
                || item.url.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame
        )
    }

    static func pageCount(at url: URL) throws -> Int {
        try document(at: url).pageCount
    }

    static func details(at url: URL) throws -> String {
        let document = try document(at: url, allowLocked: true)
        let encrypted = document.isEncrypted ? "Password protected" : "Not password protected"
        let pageDescription: String
        if document.isLocked {
            pageDescription = "Pages unavailable until unlocked"
        } else {
            pageDescription = "\(document.pageCount) page\(document.pageCount == 1 ? "" : "s")"
        }
        return [
            url.lastPathComponent,
            pageDescription,
            encrypted,
            url.path,
        ].joined(separator: "\n")
    }

    static func merge(_ urls: [URL], toFolder folder: URL) async throws -> URL {
        guard urls.count >= 2 else {
            throw PDFToolsError(message: "Select at least two PDFs to merge.")
        }

        let merged = PDFDocument()
        var insertionIndex = 0
        for url in urls {
            let source = try document(at: url)
            for pageIndex in 0..<source.pageCount {
                try Task.checkCancellation()
                guard let page = source.page(at: pageIndex)?.copy() as? PDFPage else { continue }
                merged.insert(page, at: insertionIndex)
                insertionIndex += 1
                await Task.yield()
            }
        }

        let destination = FileOperations.uniqueDestination(
            for: folder.appendingPathComponent("Merged PDF.pdf")
        )
        try write(merged, to: destination)
        return destination
    }

    static func split(_ url: URL) async throws -> URL {
        let source = try document(at: url)
        guard source.pageCount > 0 else {
            throw PDFToolsError(message: "“\(url.lastPathComponent)” has no pages to split.")
        }

        let baseName = url.deletingPathExtension().lastPathComponent
        let folder = FileOperations.uniqueDestination(
            for: url.deletingLastPathComponent()
                .appendingPathComponent("\(baseName) Pages", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)

        do {
            for pageIndex in 0..<source.pageCount {
                try Task.checkCancellation()
                guard let page = source.page(at: pageIndex)?.copy() as? PDFPage else { continue }
                let document = PDFDocument()
                document.insert(page, at: 0)
                let name = String(format: "Page %03d.pdf", pageIndex + 1)
                try write(document, to: folder.appendingPathComponent(name))
                await Task.yield()
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }

        return folder
    }

    static func extract(_ pages: [Int], from url: URL) async throws -> URL {
        let source = try document(at: url)
        let selectedPages = try normalizedPages(pages, pageCount: source.pageCount)
        let extracted = PDFDocument()

        for (destinationIndex, pageNumber) in selectedPages.enumerated() {
            try Task.checkCancellation()
            guard let page = source.page(at: pageNumber - 1)?.copy() as? PDFPage else { continue }
            extracted.insert(page, at: destinationIndex)
            await Task.yield()
        }

        let destination = outputURL(for: url, suffix: "extracted")
        try write(extracted, to: destination)
        return destination
    }

    static func rotate(_ url: URL, degrees: Int) async throws -> URL {
        let copy = try editableCopy(of: url)
        for pageIndex in 0..<copy.pageCount {
            try Task.checkCancellation()
            guard let page = copy.page(at: pageIndex) else { continue }
            page.rotation = normalizedRotation(page.rotation + degrees)
            await Task.yield()
        }

        let direction = degrees < 0 ? "rotated-left" : "rotated-right"
        let destination = outputURL(for: url, suffix: direction)
        try write(copy, to: destination)
        return destination
    }

    static func exportPagesAsPNGs(_ url: URL) async throws -> URL {
        let source = try document(at: url)
        guard source.pageCount > 0 else {
            throw PDFToolsError(message: "“\(url.lastPathComponent)” has no pages to export.")
        }

        let baseName = url.deletingPathExtension().lastPathComponent
        let folder = FileOperations.uniqueDestination(
            for: url.deletingLastPathComponent()
                .appendingPathComponent("\(baseName) PNG Pages", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)

        do {
            for pageIndex in 0..<source.pageCount {
                try Task.checkCancellation()
                guard let page = source.page(at: pageIndex) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                let renderSize = CGSize(
                    width: max(bounds.width * 2, 1),
                    height: max(bounds.height * 2, 1)
                )
                let image = page.thumbnail(of: renderSize, for: .mediaBox)
                guard let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw PDFToolsError(message: "Couldn’t render page \(pageIndex + 1).")
                }
                let name = String(format: "Page %03d.png", pageIndex + 1)
                try png.write(to: folder.appendingPathComponent(name), options: .atomic)
                await Task.yield()
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }

        return folder
    }

    static func optimize(_ url: URL) throws -> URL {
        let source = try document(at: url)
        let destination = outputURL(for: url, suffix: "optimized")
        let options: [PDFDocumentWriteOption: Any] = [
            .saveImagesAsJPEGOption: true,
        ]
        try write(source, to: destination, options: options)
        return destination
    }

    static func addWatermark(_ text: String, to url: URL) async throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PDFToolsError(message: "Enter text for the watermark.")
        }

        let copy = try editableCopy(of: url)
        for pageIndex in 0..<copy.pageCount {
            try Task.checkCancellation()
            guard let page = copy.page(at: pageIndex) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let annotationBounds = CGRect(
                x: bounds.midX - min(bounds.width * 0.35, 180),
                y: bounds.midY - 22,
                width: min(bounds.width * 0.7, 360),
                height: 44
            )
            let annotation = PDFAnnotation(
                bounds: annotationBounds,
                forType: .freeText,
                withProperties: nil
            )
            annotation.contents = trimmed
            annotation.font = .boldSystemFont(ofSize: 28)
            annotation.fontColor = NSColor.systemGray.withAlphaComponent(0.42)
            annotation.color = .clear
            annotation.alignment = .center
            annotation.shouldDisplay = true
            annotation.shouldPrint = true
            page.addAnnotation(annotation)
            await Task.yield()
        }

        let destination = outputURL(for: url, suffix: "watermarked")
        try write(copy, to: destination)
        return destination
    }

    static func protect(_ url: URL, password: String) throws -> URL {
        guard !password.isEmpty else {
            throw PDFToolsError(message: "Enter a password to protect this PDF.")
        }

        let source = try document(at: url)
        let destination = outputURL(for: url, suffix: "protected")
        let options: [PDFDocumentWriteOption: Any] = [
            .userPasswordOption: password,
            .ownerPasswordOption: password,
        ]
        try write(source, to: destination, options: options)
        return destination
    }

    static func removePassword(_ password: String, from url: URL) throws -> URL {
        guard let source = PDFDocument(url: url) else {
            throw PDFToolsError(message: "Couldn’t open “\(url.lastPathComponent)”.")
        }
        guard source.isEncrypted else {
            throw PDFToolsError(message: "“\(url.lastPathComponent)” is not password protected.")
        }
        guard source.unlock(withPassword: password) else {
            throw PDFToolsError(message: "The PDF password is incorrect.")
        }

        let unlocked = PDFDocument()
        for pageIndex in 0..<source.pageCount {
            guard let page = source.page(at: pageIndex)?.copy() as? PDFPage else { continue }
            unlocked.insert(page, at: pageIndex)
        }
        let destination = outputURL(for: url, suffix: "unlocked")
        try write(unlocked, to: destination)
        return destination
    }

    static func parsePageRange(_ range: String, pageCount: Int) throws -> [Int] {
        guard pageCount > 0 else {
            throw PDFToolsError(message: "This PDF has no pages.")
        }

        var pages = Set<Int>()
        for component in range.split(separator: ",") {
            let value = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let parts = value.split(separator: "-", maxSplits: 1)
            if parts.count == 1 {
                guard let page = Int(parts[0]), (1...pageCount).contains(page) else {
                    throw PDFToolsError(message: "“\(value)” is not a valid page number.")
                }
                pages.insert(page)
            } else {
                guard let start = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                      let end = Int(parts[1].trimmingCharacters(in: .whitespaces)),
                      start <= end,
                      (1...pageCount).contains(start),
                      (1...pageCount).contains(end) else {
                    throw PDFToolsError(message: "“\(value)” is not a valid page range.")
                }
                pages.formUnion(start...end)
            }
        }
        return try normalizedPages(Array(pages), pageCount: pageCount)
    }

    private static func document(at url: URL, allowLocked: Bool = false) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw PDFToolsError(message: "Couldn’t open “\(url.lastPathComponent)”.")
        }
        guard allowLocked || !document.isLocked else {
            throw PDFToolsError(message: "“\(url.lastPathComponent)” is password protected.")
        }
        return document
    }

    private static func editableCopy(of url: URL) throws -> PDFDocument {
        let source = try document(at: url)
        guard let data = source.dataRepresentation(), let copy = PDFDocument(data: data) else {
            throw PDFToolsError(message: "Couldn’t prepare “\(url.lastPathComponent)” for editing.")
        }
        return copy
    }

    private static func normalizedPages(_ pages: [Int], pageCount: Int) throws -> [Int] {
        let normalized = Array(Set(pages)).sorted()
        guard !normalized.isEmpty, normalized.allSatisfy({ (1...pageCount).contains($0) }) else {
            throw PDFToolsError(message: "Select one or more valid pages.")
        }
        return normalized
    }

    private static func normalizedRotation(_ rotation: Int) -> Int {
        let normalized = rotation % 360
        return normalized >= 0 ? normalized : normalized + 360
    }

    private static func outputURL(for source: URL, suffix: String) -> URL {
        let baseName = source.deletingPathExtension().lastPathComponent
        return FileOperations.uniqueDestination(
            for: source.deletingLastPathComponent().appendingPathComponent("\(baseName)-\(suffix).pdf")
        )
    }

    private static func write(
        _ document: PDFDocument,
        to destination: URL,
        options: [PDFDocumentWriteOption: Any] = [:]
    ) throws {
        guard document.write(to: destination, withOptions: options) else {
            try? FileManager.default.removeItem(at: destination)
            throw PDFToolsError(message: "Couldn’t save “\(destination.lastPathComponent)”.")
        }
    }
}
