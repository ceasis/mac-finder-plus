import AppKit
import CoreGraphics
import Foundation
import ImageIO

enum ContactSheetExporter {
    struct ContactSheetError: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    private struct Source: Sendable {
        let url: URL
        let name: String
    }

    private struct Layout {
        let pageSize = CGSize(width: 612, height: 792)
        let margin: CGFloat = 36
        let columns = 4
        let gap: CGFloat = 12
        let headerHeight: CGFloat = 28
        let captionHeight: CGFloat = 24

        var cellWidth: CGFloat {
            (pageSize.width - margin * 2 - CGFloat(columns - 1) * gap) / CGFloat(columns)
        }

        var cellHeight: CGFloat {
            cellWidth + captionHeight + 8
        }

        var rowsPerPage: Int {
            let available = pageSize.height - margin * 2 - headerHeight
            return max(1, Int((available + gap) / (cellHeight + gap)))
        }

        var itemsPerPage: Int {
            rowsPerPage * columns
        }
    }

    static func export(
        items: [FileItem],
        toFolder folder: URL,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> URL {
        let sources = items.map { Source(url: $0.url, name: $0.name) }
        let destination = FileOperations.uniqueDestination(
            for: folder.appendingPathComponent("Contact Sheet.pdf")
        )
        return try await Task.detached(priority: .userInitiated) {
            try await render(sources: sources, to: destination, progress: progress)
            return destination
        }.value
    }

    private static func render(
        sources: [Source],
        to destination: URL,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        let layout = Layout()
        var mediaBox = CGRect(origin: .zero, size: layout.pageSize)
        guard let context = CGContext(destination as CFURL, mediaBox: &mediaBox, nil) else {
            throw ContactSheetError(message: "Couldn’t create the contact sheet PDF.")
        }

        defer {
            context.closePDF()
        }

        let total = max(sources.count, 1)
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            let position = index % layout.itemsPerPage
            if position == 0 {
                if index > 0 {
                    context.endPDFPage()
                }
                context.beginPDFPage(nil)
                drawHeader(in: context, layout: layout, page: index / layout.itemsPerPage + 1)
            }

            draw(source: source, index: position, in: context, layout: layout)
            await progress(Double(index + 1) / Double(total))
        }

        context.endPDFPage()
    }

    private static func drawHeader(in context: CGContext, layout: Layout, page: Int) {
        let titleRect = CGRect(
            x: layout.margin,
            y: layout.pageSize.height - layout.margin - 18,
            width: layout.pageSize.width - layout.margin * 2 - 80,
            height: 18
        )
        drawText("Contact Sheet", in: titleRect, context: context, font: .boldSystemFont(ofSize: 12))

        let pageRect = CGRect(
            x: layout.pageSize.width - layout.margin - 70,
            y: titleRect.minY,
            width: 70,
            height: 18
        )
        drawText(
            "Page \(page)",
            in: pageRect,
            context: context,
            font: .systemFont(ofSize: 9),
            color: .secondaryLabelColor,
            alignment: .right
        )
    }

    private static func draw(source: Source, index: Int, in context: CGContext, layout: Layout) {
        let column = index % layout.columns
        let row = index / layout.columns
        let x = layout.margin + CGFloat(column) * (layout.cellWidth + layout.gap)
        let top = layout.pageSize.height - layout.margin - layout.headerHeight
            - CGFloat(row) * (layout.cellHeight + layout.gap)
        let cell = CGRect(x: x, y: top - layout.cellHeight, width: layout.cellWidth, height: layout.cellHeight)
        let imageBox = CGRect(
            x: cell.minX,
            y: cell.minY + layout.captionHeight + 6,
            width: cell.width,
            height: cell.height - layout.captionHeight - 6
        )

        context.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.55).cgColor)
        context.stroke(imageBox.insetBy(dx: 0.5, dy: 0.5), width: 0.5)

        if let thumbnail = thumbnail(for: source.url, maxPixelSize: max(imageBox.width, imageBox.height) * 2) {
            let fitted = fittedRect(for: thumbnail, in: imageBox.insetBy(dx: 3, dy: 3))
            context.interpolationQuality = .high
            context.draw(thumbnail, in: fitted)
        } else {
            drawText(
                "No Preview",
                in: imageBox.insetBy(dx: 8, dy: imageBox.height * 0.4),
                context: context,
                font: .systemFont(ofSize: 9),
                color: .secondaryLabelColor
            )
        }

        let caption = CGRect(x: cell.minX, y: cell.minY, width: cell.width, height: layout.captionHeight)
        drawText(
            source.name,
            in: caption,
            context: context,
            font: .systemFont(ofSize: 8),
            color: .labelColor,
            alignment: .center,
            lineBreak: .byTruncatingMiddle
        )
    }

    private static func thumbnail(for url: URL, maxPixelSize: CGFloat) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize),
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    private static func fittedRect(for image: CGImage, in box: CGRect) -> CGRect {
        let imageSize = CGSize(width: image.width, height: image.height)
        guard imageSize.width > 0, imageSize.height > 0 else { return box }
        let scale = min(box.width / imageSize.width, box.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: box.midX - size.width / 2,
            y: box.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func drawText(
        _ text: String,
        in rect: CGRect,
        context: CGContext,
        font: NSFont,
        color: NSColor = .labelColor,
        alignment: NSTextAlignment = .left,
        lineBreak: NSLineBreakMode = .byTruncatingTail
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = lineBreak
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSString(string: text).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attributes
        )
        NSGraphicsContext.current = previous
    }
}
