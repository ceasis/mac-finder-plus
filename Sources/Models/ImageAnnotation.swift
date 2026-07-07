import AppKit
import SwiftUI

enum ImageAnnotationTool: String, CaseIterable, Identifiable, Sendable {
    case arrow
    case text
    case rectangle
    case ellipse
    case line
    case highlight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arrow: "Arrow"
        case .text: "Text"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .highlight: "Highlight"
        }
    }

    var systemImage: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .highlight: "paintbrush"
        }
    }
}

struct AnnotationPoint: Hashable, Sendable {
    var x: Double
    var y: Double
}

struct AnnotationColor: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    var nsColor: NSColor {
        NSColor(
            calibratedRed: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        )
    }

    func withAlpha(_ value: Double) -> AnnotationColor {
        AnnotationColor(
            id: "\(id)-\(value)",
            name: name,
            red: red,
            green: green,
            blue: blue,
            alpha: value
        )
    }

    static let red = AnnotationColor(
        id: "red",
        name: "Red",
        red: 0.96,
        green: 0.10,
        blue: 0.10,
        alpha: 1
    )
    static let yellow = AnnotationColor(
        id: "yellow",
        name: "Yellow",
        red: 1.00,
        green: 0.82,
        blue: 0.10,
        alpha: 1
    )
    static let green = AnnotationColor(
        id: "green",
        name: "Green",
        red: 0.10,
        green: 0.66,
        blue: 0.32,
        alpha: 1
    )
    static let blue = AnnotationColor(
        id: "blue",
        name: "Blue",
        red: 0.10,
        green: 0.40,
        blue: 0.95,
        alpha: 1
    )
    static let white = AnnotationColor(
        id: "white",
        name: "White",
        red: 1,
        green: 1,
        blue: 1,
        alpha: 1
    )
    static let black = AnnotationColor(
        id: "black",
        name: "Black",
        red: 0.05,
        green: 0.05,
        blue: 0.06,
        alpha: 1
    )

    static let presets: [AnnotationColor] = [.red, .yellow, .green, .blue, .white, .black]
}

struct ImageAnnotationMark: Identifiable, Hashable, Sendable {
    let id: UUID
    var tool: ImageAnnotationTool
    var start: AnnotationPoint
    var end: AnnotationPoint
    var text: String
    var color: AnnotationColor
    var lineWidth: Double

    init(
        id: UUID = UUID(),
        tool: ImageAnnotationTool,
        start: AnnotationPoint,
        end: AnnotationPoint,
        text: String = "",
        color: AnnotationColor,
        lineWidth: Double
    ) {
        self.id = id
        self.tool = tool
        self.start = start
        self.end = end
        self.text = text
        self.color = color
        self.lineWidth = lineWidth
    }
}

enum ImageAnnotationRenderer {
    struct RenderError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func pixelSize(for image: NSImage) -> CGSize {
        if let representation = image.representations.max(
            by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }
        ), representation.pixelsWide > 0, representation.pixelsHigh > 0 {
            return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }
        return CGSize(width: max(image.size.width, 1), height: max(image.size.height, 1))
    }

    static func export(image: NSImage, sourceURL: URL, marks: [ImageAnnotationMark]) throws -> URL {
        guard !marks.isEmpty else {
            throw RenderError(message: "Add at least one annotation before saving.")
        }
        let size = pixelSize(for: image)
        guard size.width > 0, size.height > 0 else {
            throw RenderError(message: "The image dimensions could not be read.")
        }

        let output = NSImage(size: size)
        output.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        for mark in marks {
            draw(mark, in: size)
        }
        output.unlockFocus()

        guard let tiffData = output.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError(message: "The annotated image could not be encoded.")
        }

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let destination = FileOperations.uniqueDestination(
            for: sourceURL.deletingLastPathComponent()
                .appendingPathComponent("\(baseName)-annotated.png")
        )
        try pngData.write(to: destination, options: .atomic)
        return destination
    }

    private static func draw(_ mark: ImageAnnotationMark, in size: CGSize) {
        let start = appKitPoint(mark.start, in: size)
        let end = appKitPoint(mark.end, in: size)
        let color = mark.color.nsColor
        let lineWidth = CGFloat(max(mark.lineWidth, 1))

        switch mark.tool {
        case .arrow:
            drawLine(from: start, to: end, color: color, lineWidth: lineWidth, arrow: true)
        case .line:
            drawLine(from: start, to: end, color: color, lineWidth: lineWidth, arrow: false)
        case .rectangle:
            let rect = rectBetween(start, end)
            color.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = lineWidth
            path.stroke()
        case .ellipse:
            let rect = rectBetween(start, end)
            color.setStroke()
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = lineWidth
            path.stroke()
        case .highlight:
            let rect = rectBetween(start, end)
            color.withAlphaComponent(0.22).setFill()
            NSBezierPath(rect: rect).fill()
            color.withAlphaComponent(0.55).setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = max(lineWidth * 0.75, 1)
            path.stroke()
        case .text:
            drawText(mark.text, at: end, in: size, color: color, lineWidth: lineWidth)
        }
    }

    private static func drawLine(
        from start: NSPoint,
        to end: NSPoint,
        color: NSColor,
        lineWidth: CGFloat,
        arrow: Bool
    ) {
        color.setStroke()
        let line = NSBezierPath()
        line.lineCapStyle = .round
        line.lineJoinStyle = .round
        line.lineWidth = lineWidth
        line.move(to: start)
        line.line(to: end)
        line.stroke()

        guard arrow else { return }
        let dx = end.x - start.x
        let dy = end.y - start.y
        guard abs(dx) + abs(dy) > 0.5 else { return }

        let angle = atan2(dy, dx)
        let headLength = max(lineWidth * 5, 18)
        let wingAngle = CGFloat.pi / 7
        let points = [
            NSPoint(
                x: end.x - headLength * cos(angle - wingAngle),
                y: end.y - headLength * sin(angle - wingAngle)
            ),
            NSPoint(
                x: end.x - headLength * cos(angle + wingAngle),
                y: end.y - headLength * sin(angle + wingAngle)
            ),
        ]
        let head = NSBezierPath()
        head.lineCapStyle = .round
        head.lineJoinStyle = .round
        head.lineWidth = lineWidth
        for point in points {
            head.move(to: end)
            head.line(to: point)
        }
        head.stroke()
    }

    private static func drawText(
        _ value: String,
        at point: NSPoint,
        in canvasSize: CGSize,
        color: NSColor,
        lineWidth: CGFloat
    ) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Text" : value
        let fontSize = max(lineWidth * 5, 18)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let padding = max(lineWidth * 1.4, 6)
        let width = size.width + padding * 2
        let height = size.height + padding * 2
        let rect = NSRect(
            x: min(max(point.x - width / 2, 0), max(canvasSize.width - width, 0)),
            y: min(max(point.y - height / 2, 0), max(canvasSize.height - height, 0)),
            width: width,
            height: height
        )
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(
            in: rect.insetBy(dx: padding, dy: padding),
            withAttributes: attributes
        )
    }

    private static func appKitPoint(_ point: AnnotationPoint, in size: CGSize) -> NSPoint {
        NSPoint(
            x: CGFloat(point.x) * size.width,
            y: (1 - CGFloat(point.y)) * size.height
        )
    }

    private static func rectBetween(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: max(abs(a.x - b.x), 1),
            height: max(abs(a.y - b.y), 1)
        )
    }
}
