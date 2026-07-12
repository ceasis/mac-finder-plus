import AppKit
import SwiftUI

/// Compact current-folder view: filenames flow left-to-right into columns with
/// no size, kind, date, or preview details.
struct FileColumnView: View {
    @Environment(AppState.self) private var appState
    let model: PaneModel
    let paneIndex: Int

    @FocusState private var focused: Bool
    @State private var columnCount = 1
    @State private var anchorID: FileItem.ID?
    @State private var cellFrames: [FileItem.ID: CGRect] = [:]
    @State private var selectionDragStart: CGPoint?
    @State private var selectionDragBase = Set<FileItem.ID>()
    @State private var selectionRect: CGRect?

    private let columnWidth: CGFloat = 170
    private let columnSpacing: CGFloat = 18
    private let rowSpacing: CGFloat = 2
    private let rowHeight: CGFloat = 24
    private let contentPadding: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroller in
                ScrollView {
                    if model.displayItems.isEmpty && !model.isLoading {
                        ContentUnavailableView("No Items", systemImage: "doc")
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        LazyVGrid(
                            columns: gridColumns,
                            alignment: .leading,
                            spacing: rowSpacing
                        ) {
                            ForEach(model.displayItems) { item in
                                FileNameColumnCell(
                                    item: item,
                                    isSelected: model.selection.contains(item.id),
                                    compareMarker: model.compareMarker(for: item),
                                    width: columnWidth,
                                    height: rowHeight
                                )
                                .background(
                                    GeometryReader { proxy in
                                        Color.clear.preference(
                                            key: ColumnCellFramePreferenceKey.self,
                                            value: [
                                                item.id: proxy.frame(
                                                    in: .named(FileColumnSelectionLayout.coordinateSpace)
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
                                        ids: menuIDs(for: item),
                                        model: model,
                                        paneIndex: paneIndex
                                    )
                                }
                                .overlay(
                                    ColumnMouseDownReporter { clickCount in
                                        handleMouseDown(on: item, clickCount: clickCount)
                                    }
                                )
                                .id(item.id)
                            }
                        }
                        .padding(contentPadding)
                    }
                }
                .coordinateSpace(name: FileColumnSelectionLayout.coordinateSpace)
                .background(
                    ColumnSelectionDragReporter(
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
                .onPreferenceChange(ColumnCellFramePreferenceKey.self) { frames in
                    cellFrames = frames
                }
                .onChange(of: geometry.size.width, initial: true) { _, width in
                    let available = max(width - contentPadding * 2, columnWidth)
                    columnCount = max(
                        1,
                        Int((available + columnSpacing) / (columnWidth + columnSpacing))
                    )
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

    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(columnWidth), spacing: columnSpacing, alignment: .leading),
            count: columnCount
        )
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
            currentIndex = delta > 0 ? -1 : items.count
        }

        let target = min(max(currentIndex + delta, 0), items.count - 1)
        let id = items[target].id
        model.selection = [id]
        anchorID = id
        withAnimation {
            scroller.scrollTo(id, anchor: .center)
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
        } else if model.selection.contains(item.id), !NSEvent.modifierFlags.contains(.command) {
            appState.activePaneIndex = paneIndex
            focused = true
            anchorID = item.id
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

    private func menuIDs(for item: FileItem) -> Set<FileItem.ID> {
        model.selection.contains(item.id) ? model.selection : [item.id]
    }
}

private struct FileNameColumnCell: View {
    let item: FileItem
    let isSelected: Bool
    let compareMarker: FolderCompareMarker?
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: 16, height: 16)

            Text(item.name)
                .font(.callout)
                .fontWeight(item.isDirectory ? .medium : .regular)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)

            Spacer(minLength: 0)
        }
            .padding(.horizontal, 7)
            .frame(width: width, height: height, alignment: .leading)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.24)
                    : compareMarker?.color.opacity(0.10) ?? Color.clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(compareMarker?.color.opacity(isSelected ? 0 : 0.35) ?? Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .clickableCursor()
            .help(item.url.path)
    }
}

private enum FileColumnSelectionLayout {
    static let coordinateSpace = "fileColumnSelectionCoordinateSpace"
}

private struct ColumnCellFramePreferenceKey: PreferenceKey {
    static var defaultValue: [FileItem.ID: CGRect] { [:] }

    static func reduce(value: inout [FileItem.ID: CGRect], nextValue: () -> [FileItem.ID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct ColumnSelectionDragReporter: NSViewRepresentable {
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

    final class Coordinator {
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

private struct ColumnMouseDownReporter: NSViewRepresentable {
    let onMouseDown: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onMouseDown: onMouseDown)
    }

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughEventView()
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
