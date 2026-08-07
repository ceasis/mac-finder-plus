import AppKit
import SwiftUI

/// One browser pane: path bar on top, sortable file table below.
struct PaneView: View {
    @Environment(AppState.self) private var appState
    let paneIndex: Int

    @State private var listAnchorID: FileItem.ID?
    @State private var listRangeAnchorID: FileItem.ID?
    @State private var rowDropLocator = TableRowDropLocator()
    @State private var listDropTargetURL: URL?

    private var model: PaneModel { appState.panes[paneIndex] }
    private var isActive: Bool { appState.activePaneIndex == paneIndex }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            PaneTabBarView(model: model, isActive: isActive)
            Divider()
            PathBarView(model: model, isActive: isActive)
            Divider()
            if model.needsAccessGrant {
                grantAccessView
            } else if let error = model.loadError {
                ContentUnavailableView(
                    "Can’t Open Folder",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if model.isLoading && model.displayItems.isEmpty {
                loadingFolderView
            } else if model.viewMode == .columns {
                FileColumnView(model: model, paneIndex: paneIndex)
            } else if model.viewMode == .icons {
                FileGridView(model: model, paneIndex: paneIndex)
            } else {
                fileTable(model: model)
            }
        }
        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if isActive && appState.isDualPane {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .simultaneousGesture(
            TapGesture().onEnded { appState.activePaneIndex = paneIndex }
        )
        .onAppear { model.startMonitoring() }
        .onDisappear { model.stopMonitoring() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            model.refresh()
        }
    }

    private func fileTable(model: PaneModel) -> some View {
        @Bindable var model = model
        return Table(model.displayItems, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name) { item in
                let marker = model.compareMarker(for: item)
                HStack(spacing: 6) {
                    Image(nsImage: item.icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                    if appState.isRenaming(item, in: paneIndex) {
                        InlineFileRenameField(
                            item: item,
                            compact: false,
                            onCommit: {
                                appState.commitRename(item, in: paneIndex, to: $0)
                            },
                            onCancel: {
                                appState.cancelRename()
                            }
                        )
                        .frame(minWidth: 90, maxWidth: .infinity, minHeight: 22, maxHeight: 22)
                    } else {
                        Text(item.name)
                            .lineLimit(1)
                    }
                    if let marker {
                        Spacer(minLength: 4)
                        CompareMarkerBadge(marker: marker)
                    }
                }
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .background(
                    marker?.color.opacity(0.10) ?? Color.clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .fileDropHoverAppearance(
                    isTargeted: isListDropTarget(item),
                    cornerRadius: 5
                )
                .contentShape(Rectangle())
                .clickableCursor()
                .fileDragSource(item, paneIndex: paneIndex, appState: appState)
                .fileDropTarget(
                    to: item.url,
                    paneIndex: paneIndex,
                    appState: appState,
                    isEnabled: item.isDirectory,
                    showsIndicator: false,
                    onTargetedDestinationChange: updateListDropTarget
                )
                .overlay(
                    TableNameMouseDownReporter { clickCount in
                        handleListNameMouseDown(item, clickCount: clickCount, in: model)
                    }
                )
            }
            .width(min: 160, ideal: 280)

            TableColumn("Rating", value: \.rating) { item in
                RatingStarsView(rating: item.rating, size: 8)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .fileDropHoverAppearance(
                        isTargeted: isListDropTarget(item),
                        cornerRadius: 5
                    )
                    .fileDropTarget(
                        to: item.url,
                        paneIndex: paneIndex,
                        appState: appState,
                        isEnabled: item.isDirectory,
                        showsIndicator: false,
                        onTargetedDestinationChange: updateListDropTarget
                    )
            }
            .width(min: 56, ideal: 70)

            TableColumn("Size", value: \.size) { item in
                Text(item.sizeText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .fileDropHoverAppearance(
                        isTargeted: isListDropTarget(item),
                        cornerRadius: 5
                    )
                    .fileDropTarget(
                        to: item.url,
                        paneIndex: paneIndex,
                        appState: appState,
                        isEnabled: item.isDirectory,
                        showsIndicator: false,
                        onTargetedDestinationChange: updateListDropTarget
                    )
            }
            .width(min: 60, ideal: 80)

            TableColumn("Kind", value: \.kind) { item in
                Text(item.kind)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .fileDropHoverAppearance(
                        isTargeted: isListDropTarget(item),
                        cornerRadius: 5
                    )
                    .fileDropTarget(
                        to: item.url,
                        paneIndex: paneIndex,
                        appState: appState,
                        isEnabled: item.isDirectory,
                        showsIndicator: false,
                        onTargetedDestinationChange: updateListDropTarget
                    )
            }
            .width(min: 80, ideal: 130)

            TableColumn("Date Modified", value: \.modified) { item in
                Text(
                    item.modified == .distantPast
                        ? "—"
                        : item.modified.formatted(date: .abbreviated, time: .shortened)
                )
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .fileDropHoverAppearance(
                    isTargeted: isListDropTarget(item),
                    cornerRadius: 5
                )
                .fileDropTarget(
                    to: item.url,
                    paneIndex: paneIndex,
                    appState: appState,
                    isEnabled: item.isDirectory,
                    showsIndicator: false,
                    onTargetedDestinationChange: updateListDropTarget
                )
            }
            .width(min: 110, ideal: 150)
        }
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            FileItemContextMenu(ids: ids, model: model, paneIndex: paneIndex)
        } primaryAction: { ids in
            appState.openItems(ids, in: paneIndex)
        }
        .onKeyPress(.space) {
            appState.activePaneIndex = paneIndex
            appState.quickLookSelection()
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveListSelection(by: -1, extending: NSEvent.modifierFlags.contains(.shift), in: model)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveListSelection(by: 1, extending: NSEvent.modifierFlags.contains(.shift), in: model)
            return .handled
        }
        .onKeyPress(.return, phases: .down) { _ in
            appState.beginRenameSelectionAfterCurrentEvent(in: paneIndex)
                ? .handled
                : .ignored
        }
        .ratingKeyShortcuts { rateSelection($0) }
        .background(
            TableKeyboardSelectionReporter(isEnabled: isActive) { delta in
                moveListSelection(by: delta, extending: true, in: model)
            }
        )
        .onChange(of: model.selection) { _, selection in
            syncListAnchor(after: selection, in: model)
        }
        .background(TableRowDropLocatorAnchor(locator: rowDropLocator))
        .fileDropTarget(
            to: model.currentURL,
            paneIndex: paneIndex,
            appState: appState,
            showsIndicator: false,
            destinationResolver: { _ in folderDestinationUnderCursor(in: model) },
            onTargetedDestinationChange: updateListDropTarget
        )
    }

    /// `Table` cells don't reliably receive their own `.onDrop`, so the pane-level
    /// drop target resolves the folder row under the cursor itself. Without this a
    /// drop onto a folder row lands on the folder already being browsed, and a move
    /// into your own parent folder is a no-op — the file appears to go nowhere.
    private func folderDestinationUnderCursor(in model: PaneModel) -> URL? {
        guard let row = rowDropLocator.rowUnderCursor(),
              model.displayItems.indices.contains(row) else { return nil }
        let item = model.displayItems[row]
        return item.isDirectory ? item.url : nil
    }

    private func updateListDropTarget(_ destination: URL?) {
        let next = FileDropHighlightPolicy.visibleFolder(
            destination: destination,
            folders: model.displayItems.filter(\.isDirectory).map(\.url)
        )
        if listDropTargetURL?.standardizedFileURL != next?.standardizedFileURL {
            listDropTargetURL = next
        }
    }

    private func isListDropTarget(_ item: FileItem) -> Bool {
        item.isDirectory
            && item.url.standardizedFileURL == listDropTargetURL?.standardizedFileURL
    }

    private func rateSelection(_ rating: Int) {
        appState.activePaneIndex = paneIndex
        appState.rateSelection(rating)
    }

    private func moveListSelection(by delta: Int, extending: Bool, in model: PaneModel) {
        let ids = model.displayItems.map(\.id)
        guard !ids.isEmpty else { return }
        appState.activePaneIndex = paneIndex

        let result = FileKeyboardSelection.move(
            ids: ids,
            focusedID: listAnchorID,
            rangeAnchorID: listRangeAnchorID,
            selectedIDs: model.selection,
            delta: delta,
            extending: extending
        )
        model.selection = result.selection
        listAnchorID = result.focusedID
        listRangeAnchorID = result.rangeAnchorID
    }

    private func syncListAnchor(after selection: Set<FileItem.ID>, in model: PaneModel) {
        guard model.viewMode == .list else { return }
        if selection.isEmpty {
            listAnchorID = nil
            listRangeAnchorID = nil
            return
        }
        if selection.count == 1, let id = selection.first {
            listAnchorID = id
            listRangeAnchorID = id
            return
        }
        if let listAnchorID,
           let listRangeAnchorID,
           selection.contains(listAnchorID),
           selection.contains(listRangeAnchorID) {
            return
        }
        let visibleSelection = model.displayItems.filter { selection.contains($0.id) }
        listAnchorID = visibleSelection.last?.id
        listRangeAnchorID = visibleSelection.first?.id
    }

    private func handleListNameMouseDown(
        _ item: FileItem,
        clickCount: Int,
        in model: PaneModel
    ) -> Bool {
        appState.activePaneIndex = paneIndex
        guard !appState.isRenaming(item, in: paneIndex) else { return false }
        guard clickCount >= 2 else {
            selectListItem(item, in: model)
            return false
        }

        listAnchorID = item.id
        listRangeAnchorID = item.id
        let ids = model.selection.contains(item.id) ? model.selection : [item.id]
        model.selection = ids
        appState.openItems(ids, in: paneIndex)
        return true
    }

    private var loadingFolderView: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Loading \(model.currentURL.lastPathComponent.isEmpty ? model.currentURL.path : model.currentURL.lastPathComponent)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func selectListItem(_ item: FileItem, in model: PaneModel) {
        let modifiers = NSEvent.modifierFlags
        guard !modifiers.contains(.shift) else { return }
        let itemID = item.id
        let paneIndex = paneIndex
        Task { @MainActor in
            appState.activePaneIndex = paneIndex
            listAnchorID = itemID
            listRangeAnchorID = itemID
            if modifiers.contains(.command) {
                if model.selection.contains(itemID) {
                    model.selection.remove(itemID)
                } else {
                    model.selection.insert(itemID)
                }
            } else if !model.selection.contains(itemID) {
                model.selection = [itemID]
            }
        }
    }

    private var grantAccessView: some View {
        ContentUnavailableView {
            Label("No Access to “\(model.currentURL.lastPathComponent)”", systemImage: "lock")
        } description: {
            Text("macOS requires your permission before Workbench can browse this folder.")
        } actions: {
            Button("Grant Access…") {
                if let granted = BookmarkStore.shared.requestAccess(startingAt: model.currentURL) {
                    model.navigate(to: granted)
                    model.refresh()
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// A narrow AppKit bridge for Finder-style filename editing. AppKit owns the
/// temporary editor and selection range; AppState remains the rename source of truth.
struct InlineFileRenameField: NSViewRepresentable {
    let item: FileItem
    let compact: Bool
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommit: onCommit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: item.name)
        field.delegate = context.coordinator
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.focusRingType = .default
        field.lineBreakMode = .byTruncatingMiddle
        field.usesSingleLineMode = true
        field.controlSize = compact ? .small : .regular
        field.font = compact
            ? .systemFont(ofSize: NSFont.smallSystemFontSize)
            : .systemFont(ofSize: NSFont.systemFontSize)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.field = field

        DispatchQueue.main.async {
            context.coordinator.beginEditing(item: item)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        weak var field: NSTextField?
        var onCommit: (String) -> Void
        var onCancel: () -> Void
        private var hasFinished = false

        init(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func beginEditing(item: FileItem) {
            guard !hasFinished, let field, let window = field.window else { return }
            window.makeFirstResponder(field)
            field.selectText(nil)
            if let editor = field.currentEditor() {
                editor.selectedRange = InlineRenameSelection.range(
                    for: item.name,
                    isDirectory: item.isDirectory
                )
            }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                finish(commit: true)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finish(commit: false)
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            finish(commit: true)
        }

        private func finish(commit: Bool) {
            guard !hasFinished else { return }
            hasFinished = true
            if commit, let field {
                onCommit(field.stringValue)
            } else {
                onCancel()
            }
        }
    }
}

enum InlineRenameSelection {
    static func range(for name: String, isDirectory: Bool) -> NSRange {
        let fullName = name as NSString
        guard !isDirectory else {
            return NSRange(location: 0, length: fullName.length)
        }
        let stem = fullName.deletingPathExtension as NSString
        return NSRange(location: 0, length: stem.length)
    }
}

/// Hit-tests the `NSTableView` backing a SwiftUI `Table` so a drop can be mapped to
/// the row under the pointer. Uses the live cursor position rather than the drop's
/// SwiftUI coordinates, which avoids having to reconcile scroll offset and header
/// inset against the table's own geometry.
@MainActor
final class TableRowDropLocator {
    weak var anchorView: NSView?

    func rowUnderCursor() -> Int? {
        guard let tableView = backingTableView(), let window = tableView.window else {
            return nil
        }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = tableView.convert(windowPoint, from: nil)
        guard tableView.bounds.contains(point) else { return nil }
        let row = tableView.row(at: point)
        return row >= 0 ? row : nil
    }

    /// Walks up from the anchor so the nearest enclosing table wins — in a dual-pane
    /// window the other pane's table must never be picked up.
    private func backingTableView() -> NSTableView? {
        var node = anchorView
        while let current = node {
            if let tableView = Self.firstTableView(in: current) { return tableView }
            node = current.superview
        }
        return nil
    }

    private static func firstTableView(in view: NSView) -> NSTableView? {
        if let tableView = view as? NSTableView { return tableView }
        for subview in view.subviews {
            if let tableView = firstTableView(in: subview) { return tableView }
        }
        return nil
    }
}

private struct TableRowDropLocatorAnchor: NSViewRepresentable {
    let locator: TableRowDropLocator

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughEventView()
        locator.anchorView = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        locator.anchorView = view
    }

    private final class PassthroughEventView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

private struct TableKeyboardSelectionReporter: NSViewRepresentable {
    let isEnabled: Bool
    let onShiftMove: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, onShiftMove: onShiftMove)
    }

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughEventView()
        context.coordinator.view = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.view = view
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onShiftMove = onShiftMove
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator: @unchecked Sendable {
        weak var view: NSView?
        var isEnabled: Bool
        var onShiftMove: (Int) -> Void
        private var monitor: Any?

        init(isEnabled: Bool, onShiftMove: @escaping (Int) -> Void) {
            self.isEnabled = isEnabled
            self.onShiftMove = onShiftMove
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self,
                          self.shouldHandle(event),
                          let delta = Self.shiftVerticalDelta(for: event) else {
                        return event
                    }
                    self.onShiftMove(delta)
                    return nil
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

        private func shouldHandle(_ event: NSEvent) -> Bool {
            guard isEnabled,
                  let view,
                  let window = view.window,
                  event.window === window,
                  !Self.isEditingText(window.firstResponder) else {
                return false
            }
            return true
        }

        private static func shiftVerticalDelta(for event: NSEvent) -> Int? {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.contains(.shift),
                  !modifiers.contains(.command),
                  !modifiers.contains(.option),
                  !modifiers.contains(.control) else {
                return nil
            }
            switch event.keyCode {
            case 126: return -1
            case 125: return 1
            default: return nil
            }
        }

        private static func isEditingText(_ responder: NSResponder?) -> Bool {
            if responder is NSTextView || responder is NSText {
                return true
            }
            if let textField = responder as? NSTextField {
                return textField.currentEditor() != nil
            }
            return false
        }
    }

    private final class PassthroughEventView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

private struct TableNameMouseDownReporter: NSViewRepresentable {
    let onMouseDown: (Int) -> Bool

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

    final class Coordinator: @unchecked Sendable {
        weak var view: NSView?
        var onMouseDown: (Int) -> Bool
        private var monitor: Any?

        init(onMouseDown: @escaping (Int) -> Bool) {
            self.onMouseDown = onMouseDown
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                let location = event.locationInWindow
                let clickCount = event.clickCount
                let windowID = event.window.map(ObjectIdentifier.init)
                let swallow = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let view = self.view,
                          view.window.map(ObjectIdentifier.init) == windowID else { return false }
                    let point = view.convert(location, from: nil)
                    guard view.bounds.contains(point) else { return false }
                    return self.onMouseDown(clickCount)
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

    private final class PassthroughEventView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}
