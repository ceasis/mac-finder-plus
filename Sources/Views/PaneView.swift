import AppKit
import SwiftUI

/// One browser pane: path bar on top, sortable file table below.
struct PaneView: View {
    @Environment(AppState.self) private var appState
    let paneIndex: Int

    @State private var listAnchorID: FileItem.ID?
    @State private var listRangeAnchorID: FileItem.ID?

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
        .onAppear { model.loadIfNeeded() }
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
                    Text(item.name)
                        .lineLimit(1)
                    if let marker {
                        Spacer(minLength: 4)
                        CompareMarkerBadge(marker: marker)
                    }
                }
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
                .background(
                    marker?.color.opacity(0.10) ?? Color.clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .contentShape(Rectangle())
                .clickableCursor()
                .fileDragSource(item, paneIndex: paneIndex, appState: appState)
                .fileDropTarget(
                    to: item.url,
                    paneIndex: paneIndex,
                    appState: appState,
                    isEnabled: item.isDirectory
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
            }
            .width(min: 56, ideal: 70)

            TableColumn("Size", value: \.size) { item in
                Text(item.sizeText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 80)

            TableColumn("Kind", value: \.kind) { item in
                Text(item.kind)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 130)

            TableColumn("Date Modified", value: \.modified) { item in
                Text(
                    item.modified == .distantPast
                        ? "—"
                        : item.modified.formatted(date: .abbreviated, time: .shortened)
                )
                .foregroundStyle(.secondary)
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
        .onKeyPress("0") { rateSelection(0); return .handled }
        .onKeyPress("1") { rateSelection(1); return .handled }
        .onKeyPress("2") { rateSelection(2); return .handled }
        .onKeyPress("3") { rateSelection(3); return .handled }
        .onKeyPress("4") { rateSelection(4); return .handled }
        .onKeyPress("5") { rateSelection(5); return .handled }
        .background(
            TableKeyboardSelectionReporter(isEnabled: isActive) { delta in
                moveListSelection(by: delta, extending: true, in: model)
            }
        )
        .onChange(of: model.selection) { _, selection in
            syncListAnchor(after: selection, in: model)
        }
        .fileDropTarget(to: model.currentURL, paneIndex: paneIndex, appState: appState)
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
