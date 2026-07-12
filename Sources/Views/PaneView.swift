import AppKit
import SwiftUI

/// One browser pane: path bar on top, sortable file table below.
struct PaneView: View {
    @Environment(AppState.self) private var appState
    let paneIndex: Int

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
                    TableNameMouseDownReporter {
                        selectListItem(item, in: model)
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
            appState.activePaneIndex = paneIndex
            model.open(ids)
        }
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
        .fileDropTarget(to: model.currentURL, paneIndex: paneIndex, appState: appState)
    }

    private func rateSelection(_ rating: Int) {
        appState.activePaneIndex = paneIndex
        appState.rateSelection(rating)
    }

    private func selectListItem(_ item: FileItem, in model: PaneModel) {
        let modifiers = NSEvent.modifierFlags
        guard !modifiers.contains(.shift) else { return }
        appState.activePaneIndex = paneIndex
        if modifiers.contains(.command) {
            if model.selection.contains(item.id) {
                model.selection.remove(item.id)
            } else {
                model.selection.insert(item.id)
            }
        } else if !model.selection.contains(item.id) {
            model.selection = [item.id]
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

private struct TableNameMouseDownReporter: NSViewRepresentable {
    let onMouseDown: () -> Void

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
        var onMouseDown: () -> Void
        private var monitor: Any?

        init(onMouseDown: @escaping () -> Void) {
            self.onMouseDown = onMouseDown
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                let location = event.locationInWindow
                let windowID = event.window.map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, let view = self.view,
                          view.window.map(ObjectIdentifier.init) == windowID else { return }
                    let point = view.convert(location, from: nil)
                    guard view.bounds.contains(point) else { return }
                    self.onMouseDown()
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
