#!/usr/bin/env swift

import AppKit

struct IconRendition {
    let filename: String
    let pixels: Int
}

let renditions: [IconRendition] = [
    .init(filename: "icon_16x16.png", pixels: 16),
    .init(filename: "icon_16x16@2x.png", pixels: 32),
    .init(filename: "icon_32x32.png", pixels: 32),
    .init(filename: "icon_32x32@2x.png", pixels: 64),
    .init(filename: "icon_128x128.png", pixels: 128),
    .init(filename: "icon_128x128@2x.png", pixels: 256),
    .init(filename: "icon_256x256.png", pixels: 256),
    .init(filename: "icon_256x256@2x.png", pixels: 512),
    .init(filename: "icon_512x512.png", pixels: 512),
    .init(filename: "icon_512x512@2x.png", pixels: 1024),
]

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outputURL = root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let masterURL = root.appendingPathComponent("Design/AppIconConcepts/workbench-icon-02a-hammer-anvil.png")

try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
try FileManager.default.createDirectory(
    at: masterURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

for rendition in renditions {
    let bitmap = makeIconBitmap(pixels: rendition.pixels)
    try writePNG(bitmap, to: outputURL.appendingPathComponent(rendition.filename))
}

try writePNG(makeIconBitmap(pixels: 1024), to: masterURL)

print("Generated \(renditions.count) hammer/anvil Workbench app icon renditions in \(outputURL.path).")
print("Updated master icon at \(masterURL.path).")

private func makeIconBitmap(pixels: Int) -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Unable to create \(pixels)x\(pixels) bitmap.")
    }

    bitmap.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high

    NSColor.clear.setFill()
    CGRect(x: 0, y: 0, width: pixels, height: pixels).fill()

    guard let context = NSGraphicsContext.current?.cgContext else {
        fatalError("Unable to create drawing context.")
    }

    context.saveGState()
    let scale = CGFloat(pixels) / 1024.0
    context.scaleBy(x: scale, y: scale)
    drawWorkbenchIcon(in: context)
    context.restoreGState()

    NSGraphicsContext.restoreGraphicsState()

    return bitmap
}

private func writePNG(_ bitmap: NSBitmapImageRep, to url: URL) throws {
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Unable to encode \(url.lastPathComponent).")
    }

    try data.write(to: url, options: .atomic)
}

private func drawWorkbenchIcon(in context: CGContext) {
    let tile = CGRect(x: 54, y: 54, width: 916, height: 916)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 212, cornerHeight: 212, transform: nil)

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -28),
        blur: 48,
        color: NSColor.black.withAlphaComponent(0.32).cgColor
    )
    drawGradientRoundedRect(
        tile,
        radius: 212,
        colors: [
            NSColor(red: 0.245, green: 0.555, blue: 0.620, alpha: 1.0),
            NSColor(red: 0.455, green: 0.755, blue: 0.735, alpha: 1.0),
            NSColor(red: 1.000, green: 0.735, blue: 0.330, alpha: 1.0),
        ],
        start: CGPoint(x: 170, y: 930),
        end: CGPoint(x: 880, y: 96),
        in: context
    )
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    drawGradientRoundedRect(
        tile.insetBy(dx: 24, dy: 24),
        radius: 188,
        colors: [
            NSColor(red: 0.355, green: 0.680, blue: 0.735, alpha: 1.0),
            NSColor(red: 0.605, green: 0.840, blue: 0.785, alpha: 1.0),
            NSColor(red: 1.000, green: 0.800, blue: 0.395, alpha: 1.0),
        ],
        start: CGPoint(x: 188, y: 900),
        end: CGPoint(x: 840, y: 124),
        in: context
    )

    context.saveGState()
    context.setLineCap(.round)
    context.setLineWidth(14)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
    for x in stride(from: CGFloat(162), through: CGFloat(682), by: CGFloat(164)) {
        context.beginPath()
        context.move(to: CGPoint(x: x, y: 164))
        context.addLine(to: CGPoint(x: x + 244, y: 884))
        context.strokePath()
    }
    context.setLineWidth(9)
    context.setStrokeColor(NSColor(red: 0.04, green: 0.10, blue: 0.13, alpha: 0.16).cgColor)
    context.beginPath()
    context.move(to: CGPoint(x: 126, y: 402))
    context.addLine(to: CGPoint(x: 910, y: 402))
    context.strokePath()
    context.restoreGState()

    drawGradientRoundedRect(
        CGRect(x: 110, y: 104, width: 804, height: 376),
        radius: 92,
        colors: [
            NSColor(red: 0.125, green: 0.340, blue: 0.390, alpha: 0.50),
            NSColor(red: 0.305, green: 0.560, blue: 0.510, alpha: 0.34),
            NSColor(red: 0.950, green: 0.555, blue: 0.150, alpha: 0.34),
        ],
        start: CGPoint(x: 512, y: 480),
        end: CGPoint(x: 512, y: 104),
        in: context
    )

    context.setBlendMode(.screen)
    context.setFillColor(NSColor(red: 0.42, green: 0.88, blue: 0.98, alpha: 0.18).cgColor)
    context.fillEllipse(in: CGRect(x: 130, y: 660, width: 572, height: 208))
    context.setFillColor(NSColor(red: 0.18, green: 0.72, blue: 0.82, alpha: 0.16).cgColor)
    context.fillEllipse(in: CGRect(x: 520, y: 320, width: 400, height: 390))
    context.setFillColor(NSColor(red: 1.0, green: 0.58, blue: 0.10, alpha: 0.38).cgColor)
    context.fillEllipse(in: CGRect(x: 258, y: 238, width: 516, height: 268))
    context.setFillColor(NSColor(red: 1.0, green: 0.88, blue: 0.30, alpha: 0.24).cgColor)
    context.fillEllipse(in: CGRect(x: 368, y: 312, width: 308, height: 134))
    context.restoreGState()

    strokeRoundedRect(
        tile.insetBy(dx: 12, dy: 12),
        radius: 198,
        lineWidth: 26,
        color: NSColor(red: 0.095, green: 0.118, blue: 0.135, alpha: 1.0),
        in: context
    )
    strokeRoundedRect(
        tile.insetBy(dx: 32, dy: 32),
        radius: 180,
        lineWidth: 5,
        color: NSColor.white.withAlphaComponent(0.62),
        in: context
    )
    strokeRoundedRect(
        tile.insetBy(dx: 46, dy: 46),
        radius: 166,
        lineWidth: 2,
        color: NSColor(red: 0.20, green: 0.24, blue: 0.27, alpha: 0.16),
        in: context
    )

    context.saveGState()
    context.translateBy(x: 512, y: 390)
    context.scaleBy(x: 1.5, y: 1.5)
    context.translateBy(x: -512, y: -390)
    drawAnvil(in: context)
    drawSparks(in: context)
    drawHammer(in: context)
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    context.setBlendMode(.screen)
    context.setFillColor(NSColor.white.withAlphaComponent(0.12).cgColor)
    context.fillEllipse(in: CGRect(x: 94, y: 672, width: 740, height: 260))
    context.restoreGState()
}

private func drawAnvil(in context: CGContext) {
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -20),
        blur: 30,
        color: NSColor.black.withAlphaComponent(0.34).cgColor
    )

    let top = CGMutablePath()
    top.move(to: CGPoint(x: 226, y: 412))
    top.addCurve(to: CGPoint(x: 306, y: 448), control1: CGPoint(x: 246, y: 436), control2: CGPoint(x: 272, y: 448))
    top.addLine(to: CGPoint(x: 744, y: 448))
    top.addCurve(to: CGPoint(x: 804, y: 416), control1: CGPoint(x: 772, y: 448), control2: CGPoint(x: 794, y: 436))
    top.addCurve(to: CGPoint(x: 722, y: 358), control1: CGPoint(x: 786, y: 388), control2: CGPoint(x: 758, y: 368))
    top.addLine(to: CGPoint(x: 628, y: 330))
    top.addLine(to: CGPoint(x: 394, y: 330))
    top.addLine(to: CGPoint(x: 304, y: 358))
    top.addCurve(to: CGPoint(x: 226, y: 412), control1: CGPoint(x: 268, y: 368), control2: CGPoint(x: 240, y: 388))
    top.closeSubpath()
    drawGradientPath(
        top,
        colors: [
            NSColor(red: 0.39, green: 0.43, blue: 0.46, alpha: 1.0),
            NSColor(red: 0.16, green: 0.19, blue: 0.21, alpha: 1.0),
        ],
        start: CGPoint(x: 512, y: 464),
        end: CGPoint(x: 512, y: 326),
        in: context
    )
    strokePath(
        top,
        lineWidth: 5,
        color: NSColor(red: 0.07, green: 0.09, blue: 0.10, alpha: 0.75),
        in: context
    )

    let topFace = CGMutablePath()
    topFace.move(to: CGPoint(x: 286, y: 420))
    topFace.addLine(to: CGPoint(x: 744, y: 420))
    topFace.addCurve(to: CGPoint(x: 706, y: 394), control1: CGPoint(x: 732, y: 406), control2: CGPoint(x: 720, y: 398))
    topFace.addLine(to: CGPoint(x: 322, y: 394))
    topFace.addCurve(to: CGPoint(x: 286, y: 420), control1: CGPoint(x: 306, y: 398), control2: CGPoint(x: 294, y: 406))
    topFace.closeSubpath()
    drawGradientPath(
        topFace,
        colors: [
            NSColor(red: 0.56, green: 0.60, blue: 0.63, alpha: 0.85),
            NSColor(red: 0.30, green: 0.34, blue: 0.37, alpha: 0.82),
        ],
        start: CGPoint(x: 512, y: 426),
        end: CGPoint(x: 512, y: 388),
        in: context
    )

    let belly = CGRect(x: 362, y: 252, width: 300, height: 92)
    drawGradientRoundedRect(
        belly,
        radius: 24,
        colors: [
            NSColor(red: 0.20, green: 0.23, blue: 0.25, alpha: 1.0),
            NSColor(red: 0.10, green: 0.12, blue: 0.14, alpha: 1.0),
        ],
        start: CGPoint(x: belly.midX, y: belly.maxY),
        end: CGPoint(x: belly.midX, y: belly.minY),
        in: context
    )
    strokeRoundedRect(
        belly,
        radius: 24,
        lineWidth: 3,
        color: NSColor.black.withAlphaComponent(0.30),
        in: context
    )

    drawGradientRoundedRect(
        CGRect(x: 260, y: 220, width: 184, height: 58),
        radius: 16,
        colors: [
            NSColor(red: 0.13, green: 0.16, blue: 0.18, alpha: 1.0),
            NSColor(red: 0.055, green: 0.070, blue: 0.080, alpha: 1.0),
        ],
        start: CGPoint(x: 260, y: 278),
        end: CGPoint(x: 444, y: 220),
        in: context
    )
    drawGradientRoundedRect(
        CGRect(x: 580, y: 220, width: 184, height: 58),
        radius: 16,
        colors: [
            NSColor(red: 0.13, green: 0.16, blue: 0.18, alpha: 1.0),
            NSColor(red: 0.055, green: 0.070, blue: 0.080, alpha: 1.0),
        ],
        start: CGPoint(x: 580, y: 278),
        end: CGPoint(x: 764, y: 220),
        in: context
    )

    context.restoreGState()

    context.beginPath()
    context.move(to: CGPoint(x: 318, y: 426))
    context.addLine(to: CGPoint(x: 716, y: 426))
    context.setLineWidth(7)
    context.setLineCap(.round)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.44).cgColor)
    context.strokePath()

    context.beginPath()
    context.move(to: CGPoint(x: 408, y: 314))
    context.addLine(to: CGPoint(x: 616, y: 314))
    context.setLineWidth(4)
    context.setLineCap(.round)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.20).cgColor)
    context.strokePath()
}

private func drawHammer(in context: CGContext) {
    let pivot = CGPoint(x: 765, y: 585)
    let hammerScale: CGFloat = 1.12
    let handlePivotY: CGFloat = 330 / hammerScale

    context.saveGState()
    context.translateBy(x: pivot.x, y: pivot.y)
    context.rotate(by: -82.0 * .pi / 180.0)
    context.scaleBy(x: hammerScale, y: hammerScale)
    context.translateBy(x: 0, y: -handlePivotY)
    context.setShadow(offset: CGSize(width: 0, height: -16), blur: 32, color: NSColor.black.withAlphaComponent(0.40).cgColor)

    let handle = CGRect(x: -33, y: 26, width: 66, height: 338)
    drawGradientRoundedRect(
        handle,
        radius: 33,
        colors: [
            NSColor(red: 1.00, green: 0.77, blue: 0.26, alpha: 1.0),
            NSColor(red: 0.90, green: 0.44, blue: 0.12, alpha: 1.0),
            NSColor(red: 0.47, green: 0.20, blue: 0.06, alpha: 1.0),
        ],
        start: CGPoint(x: handle.minX, y: handle.midY),
        end: CGPoint(x: handle.maxX, y: handle.midY),
        in: context
    )
    strokeRoundedRect(
        handle,
        radius: 33,
        lineWidth: 3,
        color: NSColor(red: 0.28, green: 0.12, blue: 0.035, alpha: 0.82),
        in: context
    )
    fillRoundedRect(
        CGRect(x: -20, y: 54, width: 15, height: 270),
        radius: 7.5,
        color: NSColor.white.withAlphaComponent(0.30),
        in: context
    )
    for y in stride(from: CGFloat(76), through: CGFloat(292), by: CGFloat(72)) {
        context.beginPath()
        context.move(to: CGPoint(x: 9, y: y))
        context.addCurve(
            to: CGPoint(x: 5, y: y + 48),
            control1: CGPoint(x: 18, y: y + 16),
            control2: CGPoint(x: -2, y: y + 32)
        )
        context.setLineWidth(3)
        context.setLineCap(.round)
        context.setStrokeColor(NSColor(red: 0.32, green: 0.14, blue: 0.04, alpha: 0.28).cgColor)
        context.strokePath()
    }

    let head = CGRect(x: -142, y: -69, width: 284, height: 138)
    drawGradientRoundedRect(
        head,
        radius: 36,
        colors: [
            NSColor(red: 0.82, green: 0.87, blue: 0.89, alpha: 1.0),
            NSColor(red: 0.50, green: 0.56, blue: 0.60, alpha: 1.0),
            NSColor(red: 0.20, green: 0.24, blue: 0.28, alpha: 1.0),
        ],
        start: CGPoint(x: head.midX, y: head.maxY),
        end: CGPoint(x: head.midX, y: head.minY),
        in: context
    )
    strokeRoundedRect(
        head,
        radius: 36,
        lineWidth: 4,
        color: NSColor(red: 0.09, green: 0.11, blue: 0.13, alpha: 0.72),
        in: context
    )
    fillRoundedRect(
        CGRect(x: -178, y: -42, width: 60, height: 84),
        radius: 24,
        color: NSColor(red: 0.19, green: 0.23, blue: 0.26, alpha: 1.0),
        in: context
    )
    fillRoundedRect(
        CGRect(x: 118, y: -42, width: 60, height: 84),
        radius: 24,
        color: NSColor(red: 0.19, green: 0.23, blue: 0.26, alpha: 1.0),
        in: context
    )
    fillRoundedRect(
        CGRect(x: -96, y: 12, width: 192, height: 27),
        radius: 13.5,
        color: NSColor.white.withAlphaComponent(0.34),
        in: context
    )
    fillRoundedRect(
        CGRect(x: -82, y: -39, width: 164, height: 14),
        radius: 7,
        color: NSColor.black.withAlphaComponent(0.18),
        in: context
    )

    context.restoreGState()
}

private func drawSparks(in context: CGContext) {
    let contact = CGPoint(x: 536, y: 420)
    let sparks: [(CGFloat, CGFloat, CGFloat)] = [
        (-0.98, 0.40, 104),
        (-0.58, 0.84, 132),
        (-0.16, 1.0, 98),
        (0.22, 0.96, 120),
        (0.58, 0.72, 132),
        (0.96, 0.34, 110),
        (-0.86, -0.16, 64),
        (0.74, -0.14, 70),
    ]

    context.saveGState()
    context.setLineCap(.round)

    context.setFillColor(NSColor(red: 1.0, green: 0.60, blue: 0.08, alpha: 0.22).cgColor)
    context.fillEllipse(in: CGRect(x: contact.x - 78, y: contact.y - 48, width: 156, height: 76))

    for (index, spark) in sparks.enumerated() {
        let end = CGPoint(
            x: contact.x + spark.0 * spark.2,
            y: contact.y + spark.1 * spark.2
        )
        let start = CGPoint(
            x: contact.x + spark.0 * spark.2 * 0.34,
            y: contact.y + spark.1 * spark.2 * 0.34
        )

        context.beginPath()
        context.move(to: start)
        context.addLine(to: end)
        context.setLineWidth(index.isMultiple(of: 2) ? 13 : 10)
        context.setStrokeColor(NSColor(red: 1.0, green: 0.36, blue: 0.07, alpha: 0.52).cgColor)
        context.strokePath()

        context.beginPath()
        context.move(to: start)
        context.addLine(to: end)
        context.setLineWidth(index.isMultiple(of: 2) ? 7 : 5)
        context.setStrokeColor(NSColor(red: 1.0, green: 0.86, blue: 0.24, alpha: 0.95).cgColor)
        context.strokePath()

        context.setFillColor(NSColor(red: 1.0, green: 0.34, blue: 0.08, alpha: 0.62).cgColor)
        context.fillEllipse(in: CGRect(x: end.x - 6, y: end.y - 6, width: 12, height: 12))
    }

    context.restoreGState()
}

private func drawGradientRoundedRect(
    _ rect: CGRect,
    radius: CGFloat,
    colors: [NSColor],
    start: CGPoint,
    end: CGPoint,
    in context: CGContext
) {
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    let cgColors = colors.map(\.cgColor) as NSArray

    guard let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: cgColors,
        locations: nil
    ) else {
        return
    }

    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(gradient, start: start, end: end, options: [])
    context.restoreGState()
}

private func drawGradientPath(
    _ path: CGPath,
    colors: [NSColor],
    start: CGPoint,
    end: CGPoint,
    in context: CGContext
) {
    let cgColors = colors.map(\.cgColor) as NSArray

    guard let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: cgColors,
        locations: nil
    ) else {
        return
    }

    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(gradient, start: start, end: end, options: [])
    context.restoreGState()
}

private func strokePath(
    _ path: CGPath,
    lineWidth: CGFloat,
    color: NSColor,
    in context: CGContext
) {
    context.addPath(path)
    context.setStrokeColor(color.cgColor)
    context.setLineWidth(lineWidth)
    context.strokePath()
}

private func fillRoundedRect(
    _ rect: CGRect,
    radius: CGFloat,
    color: NSColor,
    in context: CGContext
) {
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.setFillColor(color.cgColor)
    context.fillPath()
}

private func strokeRoundedRect(
    _ rect: CGRect,
    radius: CGFloat,
    lineWidth: CGFloat,
    color: NSColor,
    in context: CGContext
) {
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.setStrokeColor(color.cgColor)
    context.setLineWidth(lineWidth)
    context.strokePath()
}
