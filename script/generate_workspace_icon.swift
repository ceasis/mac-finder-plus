#!/usr/bin/env swift

import AppKit

// Run from the repository root: swift script/generate_workspace_icon.swift
// Native macOS artwork uses a transparent, padded canvas at every rendition.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconSet = root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let sizes = [16, 32, 128, 256, 512]

for size in sizes {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let url = iconSet.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try render(size * scale).write(to: url, options: .atomic)
    }
}

func render(_ pixels: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                            bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: scale, y: -scale)

    func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }

    func round(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
               cornerWidth: r, cornerHeight: r, transform: nil)
    }

    func fill(_ path: CGPath, _ tint: CGColor) {
        context.addPath(path)
        context.setFillColor(tint)
        context.fillPath()
    }

    func shade(_ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
        context.saveGState()
        context.addPath(path)
        context.clip()
        let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
        context.drawLinearGradient(gradient, start: from, end: to,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    func stroke(_ path: CGPath, _ tint: CGColor, width: CGFloat) {
        context.addPath(path)
        context.setStrokeColor(tint)
        context.setLineWidth(width)
        context.setLineJoin(.round)
        context.strokePath()
    }

    func shadow(_ path: CGPath, blur: CGFloat, offset: CGFloat, opacity: CGFloat) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -offset * scale),
                          blur: blur * scale, color: color(0x03071A, opacity))
        fill(path, color(0x0B1430))
        context.restoreGState()
    }

    let tile = round(100, 94, 824, 824, 184)
    shadow(tile, blur: 24, offset: 20, opacity: 0.32)
    shade(tile, [color(0x365381), color(0x202D54), color(0x121B34)],
          from: CGPoint(x: 220, y: 128), to: CGPoint(x: 809, y: 917))
    stroke(round(106, 100, 812, 812, 178), color(0xABC9FF, 0.22), width: 7)

    // The back folder's tab and one mint sheet sit behind the monogram.
    let folder = CGMutablePath()
    folder.move(to: CGPoint(x: 242, y: 451))
    folder.addLine(to: CGPoint(x: 242, y: 300))
    folder.addQuadCurve(to: CGPoint(x: 289, y: 253), control: CGPoint(x: 242, y: 253))
    folder.addLine(to: CGPoint(x: 399, y: 253))
    folder.addQuadCurve(to: CGPoint(x: 440, y: 268), control: CGPoint(x: 425, y: 253))
    folder.addLine(to: CGPoint(x: 484, y: 309))
    folder.addQuadCurve(to: CGPoint(x: 513, y: 320), control: CGPoint(x: 496, y: 320))
    folder.addLine(to: CGPoint(x: 735, y: 320))
    folder.addQuadCurve(to: CGPoint(x: 782, y: 367), control: CGPoint(x: 782, y: 320))
    folder.addLine(to: CGPoint(x: 782, y: 451))
    folder.closeSubpath()
    shade(folder, [color(0x93BCF3), color(0x5074B8)],
          from: CGPoint(x: 270, y: 253), to: CGPoint(x: 690, y: 450))
    stroke(folder, color(0xD6E9FF, 0.32), width: 4)

    let sheet = round(557, 278, 155, 173, 23)
    shade(sheet, [color(0xA7FFDE), color(0x48D3B4)],
          from: CGPoint(x: 566, y: 278), to: CGPoint(x: 693, y: 444))

    // A single bold W forms the face of the folder, without outlined lettering.
    let mark = CGMutablePath()
    mark.move(to: CGPoint(x: 228, y: 358))
    mark.addLine(to: CGPoint(x: 335, y: 358))
    mark.addQuadCurve(to: CGPoint(x: 377, y: 391), control: CGPoint(x: 369, y: 358))
    mark.addLine(to: CGPoint(x: 420, y: 548))
    mark.addLine(to: CGPoint(x: 470, y: 447))
    mark.addQuadCurve(to: CGPoint(x: 512, y: 424), control: CGPoint(x: 482, y: 424))
    mark.addQuadCurve(to: CGPoint(x: 554, y: 447), control: CGPoint(x: 542, y: 424))
    mark.addLine(to: CGPoint(x: 604, y: 548))
    mark.addLine(to: CGPoint(x: 647, y: 391))
    mark.addQuadCurve(to: CGPoint(x: 689, y: 358), control: CGPoint(x: 655, y: 358))
    mark.addLine(to: CGPoint(x: 796, y: 358))
    mark.addQuadCurve(to: CGPoint(x: 826, y: 398), control: CGPoint(x: 837, y: 358))
    mark.addLine(to: CGPoint(x: 745, y: 684))
    mark.addQuadCurve(to: CGPoint(x: 707, y: 715), control: CGPoint(x: 736, y: 715))
    mark.addLine(to: CGPoint(x: 607, y: 715))
    mark.addQuadCurve(to: CGPoint(x: 576, y: 696), control: CGPoint(x: 586, y: 715))
    mark.addLine(to: CGPoint(x: 512, y: 592))
    mark.addLine(to: CGPoint(x: 448, y: 696))
    mark.addQuadCurve(to: CGPoint(x: 417, y: 715), control: CGPoint(x: 438, y: 715))
    mark.addLine(to: CGPoint(x: 317, y: 715))
    mark.addQuadCurve(to: CGPoint(x: 279, y: 684), control: CGPoint(x: 288, y: 715))
    mark.addLine(to: CGPoint(x: 198, y: 398))
    mark.addQuadCurve(to: CGPoint(x: 228, y: 358), control: CGPoint(x: 187, y: 358))
    mark.closeSubpath()
    shadow(mark, blur: 27, offset: 21, opacity: 0.53)
    shade(mark, [color(0x86DDFF), color(0x4A9BFF), color(0x4163F3)],
          from: CGPoint(x: 358, y: 344), to: CGPoint(x: 649, y: 720))
    stroke(mark, color(0xC8ECFF, 0.52), width: 5)

    // A short baseline hints at a workbench without crowding the silhouette.
    shade(round(367, 759, 290, 22, 11), [color(0x7290BE), color(0x425780)],
          from: CGPoint(x: 367, y: 759), to: CGPoint(x: 657, y: 781))

    let image = NSBitmapImageRep(cgImage: context.makeImage()!)
    return image.representation(using: .png, properties: [:])!
}
