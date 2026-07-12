import AppKit
import SwiftUI

private let panelResizeHandleWidth: CGFloat = 7.8

/// Vertical divider on the leading edge of a side panel; drag to resize width.
struct PanelResizeHandle: View {
    let onDrag: (CGFloat) -> Void
    var onDragEnded: () -> Void = {}

    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(handleColor)
            .frame(width: panelResizeHandleWidth)
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
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
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
    let onDrag: (CGFloat) -> Void
    var onDragEnded: () -> Void = {}
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            PanelResizeHandle(
                onDrag: onDrag,
                onDragEnded: onDragEnded
            )

            content()
        }
        .frame(maxHeight: .infinity)
    }
}

typealias ResizableNotesContainer = ResizableSidePanelContainer
