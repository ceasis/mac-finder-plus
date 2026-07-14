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
    /// Item the keyboard cursor moves from.
    @State private var anchorID: FileItem.ID?
    /// Fixed base for extending selection with Shift-arrow.
    @State private var rangeAnchorID: FileItem.ID?
    @State private var cellFrames: [FileItem.ID: CGRect] = [:]
    @State private var selectionDragStart: CGPoint?
    @State private var selectionDragBase = Set<FileItem.ID>()
    @State private var selectionRect: CGRect?

    private let cellSpacing: CGFloat = 25
    private let gridPadding: CGFloat = 10

    private var thumbnailSide: CGFloat {
        FileGridThumbnailSettings.clamped(appState.fileGridThumbnailSize)
    }

    private var minCellWidth: CGFloat {
        max(82, thumbnailSide + 14)
    }

    private var maxCellWidth: CGFloat {
        minCellWidth + 44
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(
                            .adaptive(minimum: minCellWidth, maximum: maxCellWidth),
                            spacing: cellSpacing
                        )],
                        spacing: cellSpacing
                    ) {
                        ForEach(model.displayItems) { item in
                            GridCell(
                                item: item,
                                isSelected: model.selection.contains(item.id),
                                compareMarker: model.compareMarker(for: item),
                                thumbnailSize: thumbnailSide
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
                                .fileDragSource(item, paneIndex: paneIndex, appState: appState)
                                .fileDropTarget(
                                    to: item.url,
                                    paneIndex: paneIndex,
                                    appState: appState,
                                    isEnabled: item.isDirectory
                                )
                                .contextMenu {
                                    FileItemContextMenu(
                                        ids: menuIDs(for: item), model: model, paneIndex: paneIndex
                                    )
                                }
                                .overlay(
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
                    SelectionDragReporter(
                        shouldBegin: shouldBeginSelectionDrag,
                        onBegin: beginSelectionDrag,
                        onChange: updateSelectionDrag,
                        onEnd: finishSelectionDrag
                    )
                )
                .fileDropTarget(to: model.currentURL, paneIndex: paneIndex, appState: appState)
                .contextMenu {
                    FileItemContextMenu(ids: [], model: model, paneIndex: paneIndex)
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
        let result = FileKeyboardSelection.move(
            ids: items.map(\.id),
            focusedID: anchorID,
            rangeAnchorID: rangeAnchorID,
            selectedIDs: model.selection,
            delta: delta,
            extending: NSEvent.modifierFlags.contains(.shift)
        )
        model.selection = result.selection
        anchorID = result.focusedID
        rangeAnchorID = result.rangeAnchorID
        guard let id = result.focusedID else { return }
        withAnimation {
            scroller.scrollTo(id)
        }
    }

    private func select(_ item: FileItem) {
        appState.activePaneIndex = paneIndex
        focused = true
        anchorID = item.id
        rangeAnchorID = item.id
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
        } else if model.selection.contains(item.id), !NSEvent.modifierFlags.contains(.command) {
            appState.activePaneIndex = paneIndex
            focused = true
            anchorID = item.id
            rangeAnchorID = item.id
        } else {
            select(item)
        }
    }

    private func shouldBeginSelectionDrag(
        at point: CGPoint,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        if modifiers.contains(.shift) { return true }
        guard !cellFrames.isEmpty || model.displayItems.isEmpty else { return false }
        return !cellFrames.values.contains { $0.insetBy(dx: -2, dy: -2).contains(point) }
    }

    private func beginSelectionDrag(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        appState.activePaneIndex = paneIndex
        focused = true
        selectionDragStart = point
        selectionDragBase = modifiers.contains(.shift) ? model.selection : []
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
            rangeAnchorID = anchor.id
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

enum FileGridThumbnailSettings {
    static let defaultsKey = "fileGrid.thumbnailSize"
    static let defaultSize = 96.0
    static let range = 64.0...180.0

    static func clamped(_ value: Double) -> CGFloat {
        CGFloat(clampedValue(value))
    }

    static func clampedValue(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    static func normalized(_ value: Double) -> CGFloat {
        CGFloat((clampedValue(value) - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    static func value(forNormalized progress: CGFloat) -> Double {
        let clampedProgress = min(max(Double(progress), 0), 1)
        return range.lowerBound + (range.upperBound - range.lowerBound) * clampedProgress
    }

    static func restoredValue(defaults: UserDefaults = .standard) -> Double {
        let stored = defaults.object(forKey: defaultsKey) as? Double ?? defaultSize
        return clampedValue(stored)
    }
}

enum FileKeyboardSelection {
    static func move<ID: Hashable>(
        ids: [ID],
        focusedID: ID?,
        rangeAnchorID: ID?,
        selectedIDs: Set<ID>,
        delta: Int,
        extending: Bool
    ) -> (selection: Set<ID>, focusedID: ID?, rangeAnchorID: ID?) {
        guard !ids.isEmpty else {
            return ([], nil, nil)
        }

        let selectedIndexes = ids.indices.filter { selectedIDs.contains(ids[$0]) }
        let currentIndex = index(of: focusedID, in: ids)
            ?? selectedEdgeIndex(in: selectedIndexes, delta: delta)
            ?? (delta > 0 ? -1 : ids.count)
        let targetIndex = min(max(currentIndex + delta, 0), ids.count - 1)
        let targetID = ids[targetIndex]

        guard extending else {
            return ([targetID], targetID, targetID)
        }

        let anchorIndex = index(of: rangeAnchorID, in: ids)
            ?? extendingAnchorIndex(
                focusedID: focusedID,
                ids: ids,
                selectedIndexes: selectedIndexes,
                delta: delta
            )
            ?? targetIndex
        let bounds = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        return (Set(ids[bounds]), targetID, ids[anchorIndex])
    }

    private static func index<ID: Equatable>(of id: ID?, in ids: [ID]) -> Int? {
        guard let id else { return nil }
        return ids.firstIndex(of: id)
    }

    private static func selectedEdgeIndex(in indexes: [Int], delta: Int) -> Int? {
        guard !indexes.isEmpty else { return nil }
        return delta >= 0 ? indexes.max() : indexes.min()
    }

    private static func extendingAnchorIndex<ID: Equatable>(
        focusedID: ID?,
        ids: [ID],
        selectedIndexes: [Int],
        delta: Int
    ) -> Int? {
        if selectedIndexes.count <= 1, let focusedIndex = index(of: focusedID, in: ids) {
            return focusedIndex
        }
        guard !selectedIndexes.isEmpty else {
            return index(of: focusedID, in: ids)
        }
        return delta >= 0 ? selectedIndexes.min() : selectedIndexes.max()
    }
}

private struct GridCellFramePreferenceKey: PreferenceKey {
    static var defaultValue: [FileItem.ID: CGRect] { [:] }

    static func reduce(value: inout [FileItem.ID: CGRect], nextValue: () -> [FileItem.ID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct GridCell: View {
    let item: FileItem
    let isSelected: Bool
    let compareMarker: FolderCompareMarker?
    let thumbnailSize: CGFloat
    @State private var thumbnail: NSImage?

    private var fileIconSize: CGFloat {
        min(max(thumbnailSize * 0.5, 34), 64)
    }

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
                        .frame(width: fileIconSize, height: fileIconSize)
                }
            }
            .frame(width: thumbnailSize, height: thumbnailSize)
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
        .padding(.horizontal, 6)
        .padding(.vertical, 4.5)
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
        .clickableCursor()
        .task(id: "\(item.id)|\(item.modified.timeIntervalSince1970)") {
            thumbnail = nil
            thumbnail = await ThumbnailLoader.thumbnail(
                for: item,
                pixelSize: CGFloat(FileGridThumbnailSettings.range.upperBound)
            )
        }
    }
}

private struct SelectionDragReporter: NSViewRepresentable {
    let shouldBegin: (CGPoint, NSEvent.ModifierFlags) -> Bool
    let onBegin: (CGPoint, NSEvent.ModifierFlags) -> Void
    let onChange: (CGPoint) -> Void
    let onEnd: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            shouldBegin: shouldBegin,
            onBegin: onBegin,
            onChange: onChange,
            onEnd: onEnd
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = FlippedEventView()
        context.coordinator.view = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.view = view
        context.coordinator.shouldBegin = shouldBegin
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

    final class Coordinator: @unchecked Sendable {
        weak var view: NSView?
        var shouldBegin: (CGPoint, NSEvent.ModifierFlags) -> Bool
        var onBegin: (CGPoint, NSEvent.ModifierFlags) -> Void
        var onChange: (CGPoint) -> Void
        var onEnd: (CGPoint) -> Void
        private var monitor: Any?
        private var isDraggingSelection = false

        init(
            shouldBegin: @escaping (CGPoint, NSEvent.ModifierFlags) -> Bool,
            onBegin: @escaping (CGPoint, NSEvent.ModifierFlags) -> Void,
            onChange: @escaping (CGPoint) -> Void,
            onEnd: @escaping (CGPoint) -> Void
        ) {
            self.shouldBegin = shouldBegin
            self.onBegin = onBegin
            self.onChange = onChange
            self.onEnd = onEnd
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                // Extract the Sendable primitives from the (non-Sendable) event
                // before hopping to the main actor — local monitors always fire
                // on the main thread, so assumeIsolated is safe.
                let location = event.locationInWindow
                let type = event.type
                let modifiers = event.modifierFlags
                let windowID = event.window.map(ObjectIdentifier.init)
                let swallow = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let view = self.view,
                          view.window.map(ObjectIdentifier.init) == windowID else { return false }
                    let point = view.convert(location, from: nil)

                    switch type {
                    case .leftMouseDown:
                        guard view.bounds.contains(point),
                              !SelectionDragScrollGuard.isPointInScrollControl(
                                windowPoint: location,
                                localPoint: point,
                                hostView: view
                              ),
                              self.shouldBegin(point, modifiers) else { return false }
                        self.isDraggingSelection = true
                        self.onBegin(point, modifiers)
                        return true
                    case .leftMouseDragged:
                        guard self.isDraggingSelection else { return false }
                        self.onChange(point)
                        return true
                    case .leftMouseUp:
                        guard self.isDraggingSelection else { return false }
                        self.isDraggingSelection = false
                        self.onEnd(point)
                        return true
                    default:
                        return false
                    }
                }
                return swallow ? nil : event
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
        let view = PassthroughEventView()
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

    final class Coordinator: @unchecked Sendable {
        weak var view: NSView?
        var onMouseDown: (Int) -> Void
        private var monitor: Any?

        init(onMouseDown: @escaping (Int) -> Void) {
            self.onMouseDown = onMouseDown
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                let location = event.locationInWindow
                let modifiers = event.modifierFlags
                let clickCount = event.clickCount
                let windowID = event.window.map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, let view = self.view,
                          view.window.map(ObjectIdentifier.init) == windowID,
                          !modifiers.contains(.shift) else { return }
                    let point = view.convert(location, from: nil)
                    guard view.bounds.contains(point) else { return }
                    self.onMouseDown(clickCount)
                }
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

    private final class PassthroughEventView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

@MainActor
enum SelectionDragScrollGuard {
    private static let fallbackScrollerGutter: CGFloat = 24
    private static let scrollerSlop: CGFloat = 4

    static func isPointInScrollControl(
        windowPoint: CGPoint,
        localPoint: CGPoint,
        hostView: NSView
    ) -> Bool {
        guard let scrollView = hostView.enclosingScrollView else {
            return isPointInFallbackGutter(localPoint, bounds: hostView.bounds)
        }

        if let verticalScroller = scrollView.verticalScroller,
           scrollView.hasVerticalScroller,
           !verticalScroller.isHidden,
           verticalScroller.alphaValue > 0 {
            let scrollerPoint = verticalScroller.convert(windowPoint, from: nil)
            if verticalScroller.bounds.insetBy(dx: -scrollerSlop, dy: -scrollerSlop).contains(scrollerPoint) {
                return true
            }
        }

        if let horizontalScroller = scrollView.horizontalScroller,
           scrollView.hasHorizontalScroller,
           !horizontalScroller.isHidden,
           horizontalScroller.alphaValue > 0 {
            let scrollerPoint = horizontalScroller.convert(windowPoint, from: nil)
            if horizontalScroller.bounds.insetBy(dx: -scrollerSlop, dy: -scrollerSlop).contains(scrollerPoint) {
                return true
            }
        }

        return isPointInFallbackGutter(
            localPoint,
            bounds: hostView.bounds,
            hasVerticalScroller: scrollView.hasVerticalScroller,
            hasHorizontalScroller: scrollView.hasHorizontalScroller,
            scrollerStyle: scrollView.scrollerStyle
        )
    }

    private static func isPointInFallbackGutter(
        _ point: CGPoint,
        bounds: CGRect,
        hasVerticalScroller: Bool = true,
        hasHorizontalScroller: Bool = true,
        scrollerStyle: NSScroller.Style = .overlay
    ) -> Bool {
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: scrollerStyle)
        let gutter = max(fallbackScrollerGutter, scrollerWidth + scrollerSlop)
        if hasVerticalScroller && point.x >= bounds.maxX - gutter {
            return true
        }
        if hasHorizontalScroller && point.y >= bounds.maxY - gutter {
            return true
        }
        return false
    }
}
