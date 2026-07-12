import AppKit

enum WorkbenchAppIconMode: String, CaseIterable, Identifiable {
    static let defaultsKey = "appIconMode"

    case animated
    case staticIcon = "static"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .animated: "Animated"
        case .staticIcon: "Static"
        }
    }

    static var preferred: WorkbenchAppIconMode {
        guard let rawValue = UserDefaults.standard.string(forKey: defaultsKey) else {
            return .animated
        }
        return WorkbenchAppIconMode(rawValue: rawValue) ?? .animated
    }
}

final class WorkbenchAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        WorkbenchDockIconAnimator.shared.startObservingPreferences()
    }

    func applicationWillTerminate(_ notification: Notification) {
        WorkbenchDockIconAnimator.shared.stopObservingPreferences()
    }
}

@MainActor
final class WorkbenchDockIconAnimator {
    static let shared = WorkbenchDockIconAnimator()

    private let view = WorkbenchDockIconView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
    private var timer: Timer?
    private var defaultsObserver: NSObjectProtocol?
    private var startedAt = CACurrentMediaTime()

    private init() {}

    func startObservingPreferences() {
        guard defaultsObserver == nil else {
            applyPreferredMode()
            return
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyPreferredMode()
            }
        }
        applyPreferredMode()
    }

    func stopObservingPreferences() {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }
        stop()
    }

    func applyPreferredMode() {
        switch WorkbenchAppIconMode.preferred {
        case .animated:
            start()
        case .staticIcon:
            stop()
        }
    }

    func start() {
        guard timer == nil else { return }

        startedAt = CACurrentMediaTime()
        NSApplication.shared.dockTile.contentView = view
        NSApplication.shared.dockTile.display()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        NSApplication.shared.dockTile.contentView = nil
        NSApplication.shared.dockTile.display()
    }

    private func tick() {
        view.elapsed = CACurrentMediaTime() - startedAt
        view.needsDisplay = true
        NSApplication.shared.dockTile.display()
    }
}

private final class WorkbenchDockIconView: NSView {
    var elapsed: TimeInterval = 0

    private let cycleDuration: CGFloat = 1.45

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: bounds.minX, y: bounds.minY)
        context.scaleBy(x: bounds.width / 1024.0, y: bounds.height / 1024.0)

        let phase = CGFloat(elapsed.truncatingRemainder(dividingBy: TimeInterval(cycleDuration))) / cycleDuration
        let impact = impactPulse(for: phase)

        drawTileBackground(in: context, impact: impact)
        context.saveGState()
        context.translateBy(x: 512, y: 318)
        context.scaleBy(x: 1.5, y: 1.5)
        context.translateBy(x: -512, y: -318)
        drawAnvil(in: context, impact: impact)
        drawHammer(in: context, phase: phase, impact: impact)
        drawSparks(in: context, phase: phase)
        context.restoreGState()

        context.restoreGState()
    }

    private func drawTileBackground(in context: CGContext, impact: CGFloat) {
        let tile = CGRect(x: 58, y: 58, width: 908, height: 908)
        let tilePath = CGPath(roundedRect: tile, cornerWidth: 204, cornerHeight: 204, transform: nil)

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -18),
            blur: 38,
            color: NSColor.black.withAlphaComponent(0.30).cgColor
        )
        drawGradientRoundedRect(
            tile,
            radius: 204,
            colors: [
                NSColor(red: 0.245, green: 0.555, blue: 0.620, alpha: 1.0),
                NSColor(red: 0.455, green: 0.755, blue: 0.735, alpha: 1.0),
                NSColor(red: 1.000, green: 0.735, blue: 0.330, alpha: 1.0),
            ],
            start: CGPoint(x: 180, y: 930),
            end: CGPoint(x: 860, y: 84),
            in: context
        )
        context.restoreGState()

        strokeRoundedRect(
            tile.insetBy(dx: 16, dy: 16),
            radius: 186,
            lineWidth: 26,
            color: NSColor(red: 0.095, green: 0.118, blue: 0.135, alpha: 1.0),
            in: context
        )
        strokeRoundedRect(
            tile.insetBy(dx: 38, dy: 38),
            radius: 170,
            lineWidth: 5,
            color: NSColor.white.withAlphaComponent(0.58),
            in: context
        )

        context.saveGState()
        context.addPath(tilePath)
        context.clip()
        drawGradientRoundedRect(
            tile.insetBy(dx: 34, dy: 34),
            radius: 172,
            colors: [
                NSColor(red: 0.355, green: 0.680, blue: 0.735, alpha: 1.0),
                NSColor(red: 0.605, green: 0.840, blue: 0.785, alpha: 1.0),
                NSColor(red: 1.000, green: 0.800, blue: 0.395, alpha: 1.0),
            ],
            start: CGPoint(x: 174, y: 894),
            end: CGPoint(x: 850, y: 130),
            in: context
        )

        context.saveGState()
        context.setLineCap(.round)
        context.setLineWidth(12)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
        for x in stride(from: CGFloat(170), through: CGFloat(660), by: CGFloat(160)) {
            context.beginPath()
            context.move(to: CGPoint(x: x, y: 174))
            context.addLine(to: CGPoint(x: x + 230, y: 888))
            context.strokePath()
        }
        context.setLineWidth(8)
        context.setStrokeColor(NSColor(red: 0.04, green: 0.10, blue: 0.13, alpha: 0.16).cgColor)
        context.beginPath()
        context.move(to: CGPoint(x: 132, y: 336))
        context.addLine(to: CGPoint(x: 900, y: 336))
        context.strokePath()
        context.restoreGState()

        drawGradientRoundedRect(
            CGRect(x: 116, y: 104, width: 792, height: 316),
            radius: 86,
            colors: [
                NSColor(red: 0.125, green: 0.340, blue: 0.390, alpha: 0.48),
                NSColor(red: 0.305, green: 0.560, blue: 0.510, alpha: 0.32),
                NSColor(red: 0.950, green: 0.555, blue: 0.150, alpha: 0.32),
            ],
            start: CGPoint(x: 512, y: 420),
            end: CGPoint(x: 512, y: 104),
            in: context
        )

        context.setBlendMode(.screen)
        context.setFillColor(NSColor(red: 0.42, green: 0.88, blue: 0.98, alpha: 0.18).cgColor)
        context.fillEllipse(in: CGRect(x: 128, y: 664, width: 568, height: 198))
        context.setFillColor(NSColor(red: 0.18, green: 0.72, blue: 0.82, alpha: 0.16).cgColor)
        context.fillEllipse(in: CGRect(x: 516, y: 312, width: 388, height: 382))
        context.setFillColor(NSColor(red: 1.0, green: 0.58, blue: 0.10, alpha: 0.34 + 0.18 * impact).cgColor)
        context.fillEllipse(in: CGRect(x: 276, y: 204, width: 488, height: 244))
        context.setFillColor(NSColor(red: 1.0, green: 0.88, blue: 0.30, alpha: 0.20 + 0.12 * impact).cgColor)
        context.fillEllipse(in: CGRect(x: 374, y: 254, width: 292, height: 124))
        context.restoreGState()
    }

    private func drawAnvil(in context: CGContext, impact: CGFloat) {
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -12),
            blur: 20,
            color: NSColor.black.withAlphaComponent(0.38).cgColor
        )

        let top = CGMutablePath()
        top.move(to: CGPoint(x: 310, y: 330))
        top.addCurve(to: CGPoint(x: 374, y: 350), control1: CGPoint(x: 326, y: 344), control2: CGPoint(x: 348, y: 350))
        top.addLine(to: CGPoint(x: 658, y: 350))
        top.addCurve(to: CGPoint(x: 714, y: 326), control1: CGPoint(x: 684, y: 350), control2: CGPoint(x: 704, y: 340))
        top.addCurve(to: CGPoint(x: 650, y: 276), control1: CGPoint(x: 700, y: 304), control2: CGPoint(x: 678, y: 286))
        top.addLine(to: CGPoint(x: 604, y: 258))
        top.addLine(to: CGPoint(x: 420, y: 258))
        top.addLine(to: CGPoint(x: 374, y: 276))
        top.addCurve(to: CGPoint(x: 310, y: 330), control1: CGPoint(x: 346, y: 286), control2: CGPoint(x: 324, y: 306))
        top.closeSubpath()
        drawGradientPath(
            top,
            colors: [
                NSColor(red: 0.39, green: 0.43, blue: 0.46, alpha: 1.0),
                NSColor(red: 0.16, green: 0.19, blue: 0.21, alpha: 1.0),
            ],
            start: CGPoint(x: 512, y: 354),
            end: CGPoint(x: 512, y: 252),
            in: context
        )
        strokePath(top, lineWidth: 3, color: NSColor.black.withAlphaComponent(0.36), in: context)

        drawGradientRoundedRect(
            CGRect(x: 420, y: 212, width: 184, height: 58),
            radius: 14,
            colors: [
                NSColor(red: 0.20, green: 0.23, blue: 0.25, alpha: 0.98),
                NSColor(red: 0.09, green: 0.11, blue: 0.13, alpha: 0.98),
            ],
            start: CGPoint(x: 512, y: 270),
            end: CGPoint(x: 512, y: 212),
            in: context
        )
        drawGradientRoundedRect(
            CGRect(x: 378, y: 196, width: 96, height: 38),
            radius: 10,
            colors: [
                NSColor(red: 0.13, green: 0.16, blue: 0.18, alpha: 0.98),
                NSColor(red: 0.055, green: 0.070, blue: 0.080, alpha: 0.98),
            ],
            start: CGPoint(x: 378, y: 234),
            end: CGPoint(x: 474, y: 196),
            in: context
        )
        drawGradientRoundedRect(
            CGRect(x: 552, y: 196, width: 96, height: 38),
            radius: 10,
            colors: [
                NSColor(red: 0.13, green: 0.16, blue: 0.18, alpha: 0.98),
                NSColor(red: 0.055, green: 0.070, blue: 0.080, alpha: 0.98),
            ],
            start: CGPoint(x: 552, y: 234),
            end: CGPoint(x: 648, y: 196),
            in: context
        )

        if impact > 0.01 {
            context.setFillColor(NSColor(red: 1.0, green: 0.68, blue: 0.18, alpha: 0.42 * impact).cgColor)
            context.fillEllipse(in: CGRect(x: 430, y: 288, width: 170, height: 46))
        }

        context.restoreGState()

        let highlight = CGMutablePath()
        highlight.move(to: CGPoint(x: 374, y: 326))
        highlight.addLine(to: CGPoint(x: 650, y: 326))
        context.addPath(highlight)
        context.setLineWidth(5)
        context.setLineCap(.round)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.42).cgColor)
        context.strokePath()
    }

    private func drawHammer(in context: CGContext, phase: CGFloat, impact: CGFloat) {
        let strike = strikeProgress(for: phase)
        let pivot = CGPoint(x: 764, y: 459 + impact * 4)
        let hammerScale: CGFloat = 1.14
        let handlePivotY: CGFloat = 274 / hammerScale
        let angle = degreesToRadians(-118 + 38 * strike - impact * 5)

        context.saveGState()
        context.translateBy(x: pivot.x, y: pivot.y)
        context.rotate(by: angle)
        context.scaleBy(x: hammerScale, y: hammerScale)
        context.translateBy(x: 0, y: -handlePivotY)

        context.setShadow(
            offset: CGSize(width: 0, height: -8),
            blur: 18,
            color: NSColor.black.withAlphaComponent(0.34).cgColor
        )

        let handle = CGRect(x: -24, y: 18, width: 48, height: 276)
        drawGradientRoundedRect(
            handle,
            radius: 24,
            colors: [
                NSColor(red: 1.00, green: 0.77, blue: 0.26, alpha: 1.0),
                NSColor(red: 0.86, green: 0.42, blue: 0.12, alpha: 1.0),
                NSColor(red: 0.45, green: 0.19, blue: 0.05, alpha: 1.0),
            ],
            start: CGPoint(x: handle.minX, y: handle.midY),
            end: CGPoint(x: handle.maxX, y: handle.midY),
            in: context
        )
        strokeRoundedRect(handle, radius: 24, lineWidth: 2, color: NSColor(red: 0.26, green: 0.11, blue: 0.03, alpha: 0.70), in: context)
        fillRoundedRect(
            CGRect(x: -15, y: 38, width: 15, height: 232),
            radius: 7.5,
            color: NSColor.white.withAlphaComponent(0.30),
            in: context
        )
        drawGradientRoundedRect(
            CGRect(x: -104, y: -48, width: 208, height: 96),
            radius: 26,
            colors: [
                NSColor(red: 0.82, green: 0.87, blue: 0.89, alpha: 1.0),
                NSColor(red: 0.48, green: 0.54, blue: 0.58, alpha: 1.0),
                NSColor(red: 0.20, green: 0.24, blue: 0.28, alpha: 1.0),
            ],
            start: CGPoint(x: 0, y: 48),
            end: CGPoint(x: 0, y: -48),
            in: context
        )
        strokeRoundedRect(CGRect(x: -104, y: -48, width: 208, height: 96), radius: 26, lineWidth: 3, color: NSColor.black.withAlphaComponent(0.32), in: context)
        fillRoundedRect(
            CGRect(x: -82, y: 6, width: 164, height: 24),
            radius: 12,
            color: NSColor.white.withAlphaComponent(0.34),
            in: context
        )
        fillRoundedRect(
            CGRect(x: -128, y: -29, width: 45, height: 57),
            radius: 15,
            color: NSColor(red: 0.19, green: 0.23, blue: 0.26, alpha: 1.0),
            in: context
        )
        fillRoundedRect(
            CGRect(x: 83, y: -29, width: 45, height: 57),
            radius: 15,
            color: NSColor(red: 0.19, green: 0.23, blue: 0.26, alpha: 1.0),
            in: context
        )

        context.restoreGState()
    }

    private func drawSparks(in context: CGContext, phase: CGFloat) {
        let hitPhase: CGFloat = 0.50
        let sparkLife: CGFloat = 0.46
        var age = phase - hitPhase
        if age < 0 {
            age += 1
        }
        guard age >= 0, age <= sparkLife else { return }

        let t = age / sparkLife
        let ignition = easeOutCubic(min(t * 5, 1))
        let opacity = ignition * pow(1 - t, 1.18)
        let contact = CGPoint(x: 536, y: 318)
        let directions: [(CGFloat, CGFloat, CGFloat)] = [
            (-1.00, 0.36, 116),
            (-0.76, 0.74, 146),
            (-0.42, 1.00, 112),
            (-0.08, 1.00, 132),
            (0.24, 0.98, 128),
            (0.58, 0.76, 150),
            (0.94, 0.36, 120),
            (-0.94, -0.20, 86),
            (-0.38, -0.34, 74),
            (0.34, -0.30, 80),
            (0.84, -0.18, 92),
        ]

        context.saveGState()
        context.setLineCap(.round)
        context.setFillColor(NSColor(red: 1.0, green: 0.48, blue: 0.07, alpha: 0.36 * opacity).cgColor)
        context.fillEllipse(in: CGRect(x: contact.x - 84, y: contact.y - 44, width: 168, height: 82))
        context.setFillColor(NSColor(red: 1.0, green: 0.86, blue: 0.22, alpha: 0.34 * opacity).cgColor)
        context.fillEllipse(in: CGRect(x: contact.x - 42, y: contact.y - 24, width: 84, height: 46))

        for (index, direction) in directions.enumerated() {
            let jitter = CGFloat((index % 3) - 1) * 0.08
            let distance = direction.2 * easeOutCubic(t)
            let start = CGPoint(
                x: contact.x + direction.0 * distance * 0.20,
                y: contact.y + direction.1 * distance * 0.20
            )
            let end = CGPoint(
                x: contact.x + (direction.0 + jitter) * distance,
                y: contact.y + direction.1 * distance
            )

            context.beginPath()
            context.move(to: start)
            context.addLine(to: end)
            context.setLineWidth(index.isMultiple(of: 2) ? 18 : 13)
            context.setStrokeColor(NSColor(red: 1.0, green: 0.26, blue: 0.04, alpha: 0.58 * opacity).cgColor)
            context.strokePath()

            context.beginPath()
            context.move(to: start)
            context.addLine(to: end)
            context.setLineWidth(index.isMultiple(of: 2) ? 9 : 6)
            context.setStrokeColor(NSColor(red: 1.0, green: 0.92, blue: 0.26, alpha: 0.98 * opacity).cgColor)
            context.strokePath()

            let dotRadius: CGFloat = index.isMultiple(of: 2) ? 8 : 6
            context.setFillColor(NSColor(red: 1.0, green: 0.30, blue: 0.08, alpha: 0.76 * opacity).cgColor)
            context.fillEllipse(in: CGRect(x: end.x - dotRadius, y: end.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
        }

        context.restoreGState()
    }

    private func strikeProgress(for phase: CGFloat) -> CGFloat {
        if phase < 0.14 {
            return 0
        }
        if phase < 0.50 {
            return easeInQuart((phase - 0.14) / 0.36)
        }
        if phase < 0.61 {
            return 1.0 - 0.24 * easeOutCubic((phase - 0.50) / 0.11)
        }
        if phase < 0.74 {
            return 0.76 + 0.10 * easeInOutCubic((phase - 0.61) / 0.13)
        }
        return 0.86 * (1.0 - easeInOutCubic((phase - 0.74) / 0.26))
    }

    private func impactPulse(for phase: CGFloat) -> CGFloat {
        let distance = abs(phase - 0.50)
        guard distance < 0.075 else { return 0 }
        return 1.0 - distance / 0.075
    }

    private func easeInCubic(_ value: CGFloat) -> CGFloat {
        let t = min(max(value, 0), 1)
        return t * t * t
    }

    private func easeInQuart(_ value: CGFloat) -> CGFloat {
        let t = min(max(value, 0), 1)
        return t * t * t * t
    }

    private func easeOutCubic(_ value: CGFloat) -> CGFloat {
        let t = 1 - min(max(value, 0), 1)
        return 1 - t * t * t
    }

    private func easeInOutCubic(_ value: CGFloat) -> CGFloat {
        let t = min(max(value, 0), 1)
        if t < 0.5 {
            return 4 * t * t * t
        }
        return 1 - pow(-2 * t + 2, 3) / 2
    }

    private func degreesToRadians(_ degrees: CGFloat) -> CGFloat {
        degrees * .pi / 180
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
}
