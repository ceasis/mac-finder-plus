import AppKit
import SwiftUI

extension View {
    func clickableCursor(_ isEnabled: Bool = true) -> some View {
        cursor(.pointingHand, isEnabled: isEnabled)
    }

    func draggableCursor(_ isEnabled: Bool = true) -> some View {
        cursor(.openHand, isEnabled: isEnabled)
    }

    func horizontalResizeCursor(_ isEnabled: Bool = true) -> some View {
        cursor(.resizeLeftRight, isEnabled: isEnabled)
    }

    private func cursor(_ cursor: NSCursor, isEnabled: Bool) -> some View {
        background(CursorRegion(cursor: cursor, isEnabled: isEnabled))
    }
}

private struct CursorRegion: NSViewRepresentable {
    let cursor: NSCursor
    let isEnabled: Bool

    func makeNSView(context: Context) -> CursorRegionView {
        let view = CursorRegionView()
        view.cursor = cursor
        view.isCursorEnabled = isEnabled
        return view
    }

    func updateNSView(_ nsView: CursorRegionView, context: Context) {
        nsView.cursor = cursor
        nsView.isCursorEnabled = isEnabled
    }
}

private final class CursorRegionView: NSView {
    var cursor: NSCursor = .pointingHand {
        didSet { invalidateCursorRects() }
    }

    var isCursorEnabled = true {
        didSet { invalidateCursorRects() }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isCursorEnabled else { return }
        addCursorRect(bounds, cursor: cursor)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidateCursorRects()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func invalidateCursorRects() {
        window?.invalidateCursorRects(for: self)
    }
}
