import AppKit
import SwiftUI

/// Icon-grid view mode with Quick Look thumbnails. Click selects (⌘-click
/// toggles), double-click opens, arrow keys navigate (up/down move by row),
/// Space previews, cells are draggable and share the standard context menu.
struct FileGridView: View {
    @Environment(AppState.self) private var appState
    let model: PaneModel
    let paneIndex: Int

    @FocusState private var focused: Bool
    @State private var columnCount = 1
    /// Last item selected by click or keyboard — the anchor arrow keys move from.
    @State private var anchorID: FileItem.ID?
    @State private var cellFrames: [FileItem.ID: CGRect] = [:]
    @State private var selectionDragStart: CGPoint?
    @State private var selectionDragBase = Set<FileItem.ID>()
    @State private var selectionRect: CGRect?

    private let minCellWidth: CGFloat = 110
    private let cellSpacing: CGFloat = 12
    private let gridPadding: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(
                            .adaptive(minimum: minCellWidth, maximum: 150),
                            spacing: cellSpacing
                        )],
                        spacing: cellSpacing
                    ) {
                        ForEach(model.displayItems) { item in
                            GridCell(
                                item: item,
                                isSelected: model.selection.contains(item.id),
                                compareMarker: model.compareMarker(for: item)
                            )
                                .background(
                                    GeometryReader { proxy in
                                        Color.clear.preference(
                                            key: GridCellFramePreferenceKey.self,
                                            value: [
                                                item.id: proxy.frame(
                                                    in: .named(FileGridSelectionLayout.coordinateSpace)
                                                )
                                            ]
                                        )
                                    }
                                )
                                .draggable(item.url)
                                .dropDestination(for: URL.self) { urls, _ in
                                    guard item.isDirectory else { return false }
                                    return appState.drop(urls, to: item.url, paneIndex: paneIndex)
                                }
                                .contextMenu {
                                    FileItemContextMenu(
                                        ids: menuIDs(for: item), model: model, paneIndex: paneIndex
                                    )
                                }
                                .background(
                                    MouseDownReporter { clickCount in
                                        handleMouseDown(on: item, clickCount: clickCount)
                                    }
                                )
                        }
                    }
                    .padding(gridPadding)
                }
                .coordinateSpace(name: FileGridSelectionLayout.coordinateSpace)
                .background(
                    ShiftDragSelectionReporter(
                        onBegin: beginSelectionDrag,
                        onChange: updateSelectionDrag,
                        onEnd: finishSelectionDrag
                    )
                )
                .dropDestination(for: URL.self) { urls, _ in
                    appState.drop(urls, to: model.currentURL, paneIndex: paneIndex)
                }
                .overlay(alignment: .topLeading) {
                    if let selectionRect {
                        Rectangle()
                            .fill(Color.green.opacity(0.18))
                            .overlay(
                                Rectangle()
                                    .stroke(Color.green.opacity(0.7), lineWidth: 1)
                            )
                            .frame(
                                width: max(selectionRect.width, 1),
                                height: max(selectionRect.height, 1)
                            )
                            .offset(x: selectionRect.minX, y: selectionRect.minY)
                            .allowsHitTesting(false)
                    }
                }
                .onPreferenceChange(GridCellFramePreferenceKey.self) { frames in
                    cellFrames = frames
                }
                .onChange(of: geometry.size.width, initial: true) { _, width in
                    // Mirror LazyVGrid's adaptive layout: as many columns of at
                    // least minCellWidth as fit. Needed for up/down arrow moves.
                    let available = width - gridPadding * 2
                    columnCount = max(1, Int((available + cellSpacing) / (minCellWidth + cellSpacing)))
                }
                .focusable()
                .focusEffectDisabled()
                .focused($focused)
                .onKeyPress(.leftArrow) { moveSelection(by: -1, scroller); return .handled }
                .onKeyPress(.rightArrow) { moveSelection(by: 1, scroller); return .handled }
                .onKeyPress(.upArrow) { moveSelection(by: -columnCount, scroller); return .handled }
                .onKeyPress(.downArrow) { moveSelection(by: columnCount, scroller); return .handled }
                .onKeyPress(.space) {
                    appState.activePaneIndex = paneIndex
                    appState.quickLookSelection()
                    return .handled
                }
                .onKeyPress("0") { rateSelection(0); return .handled }
                .onKeyPress("1") { rateSelection(1); return .handled }
                .onKeyPress("2") { rateSelection(2); return .handled }
                .onKeyPress("3") { rateSelection(3); return .handled }
                .onKeyPress("4") { rateSelection(4); return .handled }
                .onKeyPress("5") { rateSelection(5); return .handled }
                .onAppear { focused = true }
            }
        }
    }

    private func rateSelection(_ rating: Int) {
        appState.activePaneIndex = paneIndex
        appState.rateSelection(rating)
    }

    private func moveSelection(by delta: Int, _ scroller: ScrollViewProxy) {
        let items = model.displayItems
        guard !items.isEmpty else { return }
        appState.activePaneIndex = paneIndex
        let currentIndex: Int
        if let anchorID, let index = items.firstIndex(where: { $0.id == anchorID }) {
            currentIndex = index
        } else {
            // No selection yet: first press lands on the first (or last) item.
            currentIndex = delta > 0 ? -1 : items.count
        }
        let target = min(max(currentIndex + delta, 0), items.count - 1)
        let id = items[target].id
        model.selection = [id]
        anchorID = id
        withAnimation {
            scroller.scrollTo(id)
        }
    }

    private func select(_ item: FileItem) {
        appState.activePaneIndex = paneIndex
        focused = true
        anchorID = item.id
        if NSEvent.modifierFlags.contains(.command) {
            if model.selection.contains(item.id) {
                model.selection.remove(item.id)
            } else {
                model.selection.insert(item.id)
            }
        } else {
            model.selection = [item.id]
        }
    }

    private func handleMouseDown(on item: FileItem, clickCount: Int) {
        if clickCount == 2 {
            appState.activePaneIndex = paneIndex
            model.open([item.id])
        } else {
            select(item)
        }
    }

    private func beginSelectionDrag(at point: CGPoint) {
        appState.activePaneIndex = paneIndex
        focused = true
        selectionDragStart = point
        selectionDragBase = model.selection
        updateSelectionDrag(to: point)
    }

    private func updateSelectionDrag(to point: CGPoint) {
        guard let selectionDragStart else { return }
        let rect = selectionRectangle(from: selectionDragStart, to: point)
        selectionRect = rect
        let hitIDs = Set(model.displayItems.compactMap { item -> FileItem.ID? in
            guard let frame = cellFrames[item.id] else { return nil }
            return frame.intersects(rect) || frame.contains(point) ? item.id : nil
        })
        model.selection = selectionDragBase.union(hitIDs)
        if let anchor = model.displayItems.last(where: { hitIDs.contains($0.id) }) {
            anchorID = anchor.id
        }
    }

    private func finishSelectionDrag(at point: CGPoint) {
        updateSelectionDrag(to: point)
        selectionDragStart = nil
        selectionDragBase.removeAll()
        selectionRect = nil
    }

    private func selectionRectangle(from start: CGPoint, to end: CGPoint) -> CGRect {
        let origin = CGPoint(x: min(start.x, end.x), y: min(start.y, end.y))
        let size = CGSize(width: abs(start.x - end.x), height: abs(start.y - end.y))
        return CGRect(origin: origin, size: size)
    }

    /// Right-clicking a selected item acts on the whole selection;
    /// right-clicking an unselected item acts on just that item.
    private func menuIDs(for item: FileItem) -> Set<FileItem.ID> {
        model.selection.contains(item.id) ? model.selection : [item.id]
    }
}

private enum FileGridSelectionLayout {
    static let coordinateSpace = "fileGridSelectionCoordinateSpace"
}

private struct GridCellFramePreferenceKey: PreferenceKey {
    static var defaultValue: [FileItem.ID: CGRect] = [:]

    static func reduce(value: inout [FileItem.ID: CGRect], nextValue: () -> [FileItem.ID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct GridCell: View {
    let item: FileItem
    let isSelected: Bool
    let compareMarker: FolderCompareMarker?
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(nsImage: item.icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                }
            }
            .frame(width: 96, height: 96)
            Text(item.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
            RatingStarsView(rating: item.rating, size: 8, showEmpty: item.rating > 0)
                .frame(height: 10)
            if let compareMarker {
                CompareMarkerBadge(marker: compareMarker)
                    .labelStyle(.iconOnly)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.22)
                : compareMarker?.color.opacity(0.12) ?? Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(compareMarker?.color.opacity(0.35) ?? Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .task(id: "\(item.id)|\(item.modified.timeIntervalSince1970)") {
            thumbnail = nil
            thumbnail = await ThumbnailLoader.thumbnail(for: item, pixelSize: 96)
        }
    }
}

private struct ShiftDragSelectionReporter: NSViewRepresentable {
    let onBegin: (CGPoint) -> Void
    let onChange: (CGPoint) -> Void
    let onEnd: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onBegin: onBegin, onChange: onChange, onEnd: onEnd)
    }

    func makeNSView(context: Context) -> NSView {
        let view = FlippedEventView()
        context.coordinator.view = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.view = view
        context.coordinator.onBegin = onBegin
        context.coordinator.onChange = onChange
        context.coordinator.onEnd = onEnd
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    private final class FlippedEventView: NSView {
        override var isFlipped: Bool { true }
    }

    final class Coordinator {
        weak var view: NSView?
        var onBegin: (CGPoint) -> Void
        var onChange: (CGPoint) -> Void
        var onEnd: (CGPoint) -> Void
        private var monitor: Any?
        private var isDraggingSelection = false

        init(
            onBegin: @escaping (CGPoint) -> Void,
            onChange: @escaping (CGPoint) -> Void,
            onEnd: @escaping (CGPoint) -> Void
        ) {
            self.onBegin = onBegin
            self.onChange = onChange
            self.onEnd = onEnd
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                guard let self, let view, event.window === view.window else { return event }
                let point = view.convert(event.locationInWindow, from: nil)

                switch event.type {
                case .leftMouseDown:
                    guard event.modifierFlags.contains(.shift),
                          view.bounds.contains(point) else { return event }
                    isDraggingSelection = true
                    onBegin(point)
                    return nil
                case .leftMouseDragged:
                    guard isDraggingSelection else { return event }
                    onChange(point)
                    return nil
                case .leftMouseUp:
                    guard isDraggingSelection else { return event }
                    isDraggingSelection = false
                    onEnd(point)
                    return nil
                default:
                    return event
                }
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        deinit {
            removeMonitor()
        }
    }
}

private struct MouseDownReporter: NSViewRepresentable {
    let onMouseDown: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onMouseDown: onMouseDown)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.postsFrameChangedNotifications = true
        context.coordinator.view = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.view = view
        context.coordinator.onMouseDown = onMouseDown
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        weak var view: NSView?
        var onMouseDown: (Int) -> Void
        private var monitor: Any?

        init(onMouseDown: @escaping (Int) -> Void) {
            self.onMouseDown = onMouseDown
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let view, event.window === view.window else { return event }
                guard !event.modifierFlags.contains(.shift) else { return event }
                let point = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(point) else { return event }
                onMouseDown(event.clickCount)
                return event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        deinit {
            removeMonitor()
        }
    }
}
