import AppKit
import SwiftUI

/// Vertical divider on the leading edge of a side panel; drag to resize width.
struct PanelResizeHandle: View {
    let onDrag: (CGFloat) -> Void
    var onDragEnded: () -> Void = {}

    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(handleColor)
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if hovering || isDragging {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            NSCursor.resizeLeftRight.push()
                        }
                        onDrag(value.translation.width)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onDragEnded()
                        if !isHovering {
                            NSCursor.pop()
                        }
                    }
            )
            .accessibilityLabel("Resize panel")
    }

    private var handleColor: Color {
        isHovering || isDragging
            ? Color.secondary.opacity(0.35)
            : Color.secondary.opacity(0.12)
    }
}

/// Right-docked tool panel with a draggable width and a 50% default on first open.
struct ResizableSidePanelContainer<Content: View>: View {
    let availableWidth: CGFloat
    @Binding var widthFraction: Double
    @ViewBuilder var content: () -> Content

    @State private var widthAtDragStart: CGFloat?

    private var minWidth: CGFloat { 320 }
    private var maxFraction: Double { 0.75 }

    private var resolvedFraction: Double {
        let stored = widthFraction > 0 ? widthFraction : 0.5
        let minFraction = Double(minWidth / max(availableWidth, 1))
        return min(max(stored, minFraction), maxFraction)
    }

    private var resolvedWidth: CGFloat {
        availableWidth * resolvedFraction
    }

    var body: some View {
        HStack(spacing: 0) {
            PanelResizeHandle(
                onDrag: { delta in
                    if widthAtDragStart == nil {
                        widthAtDragStart = resolvedWidth
                    }
                    guard let start = widthAtDragStart else { return }
                    let next = start - delta
                    let clamped = min(max(next, minWidth), availableWidth * maxFraction)
                    widthFraction = Double(clamped / max(availableWidth, 1))
                },
                onDragEnded: {
                    widthAtDragStart = nil
                }
            )

            content()
        }
        .frame(width: resolvedWidth)
        .frame(maxHeight: .infinity)
        .onAppear(perform: applyDefaultFractionIfNeeded)
        .onChange(of: availableWidth) { _, _ in
            clampFraction()
            applyDefaultFractionIfNeeded()
        }
    }

    private func applyDefaultFractionIfNeeded() {
        if widthFraction <= 0 {
            widthFraction = 0.5
        }
    }

    private func clampFraction() {
        let minFraction = Double(minWidth / max(availableWidth, 1))
        widthFraction = min(max(widthFraction, minFraction), maxFraction)
    }
}

typealias ResizableNotesContainer = ResizableSidePanelContainer
