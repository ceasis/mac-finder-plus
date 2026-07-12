import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum SidebarSectionID: String, CaseIterable, Identifiable {
    case places
    case devices
    case favorites
    case tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .places: "Places"
        case .devices: "Devices"
        case .favorites: "Favorites"
        case .tools: "Tools"
        }
    }
}

private enum SidebarToolID: String, CaseIterable, Identifiable {
    case notes
    case snippets
    case cleanup
    case diskSpace
    case organize
    case clipboard
    case voiceRecorder
    case screenshot
    case screenRecording

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notes: "Notes"
        case .snippets: "Snippets"
        case .cleanup: "Clean Up"
        case .diskSpace: "Disk Space"
        case .organize: "Organize"
        case .clipboard: "Clipboard History"
        case .voiceRecorder: "Voice Recorder"
        case .screenshot: "Screenshot"
        case .screenRecording: "Screen Recording"
        }
    }

    var systemImage: String {
        switch self {
        case .notes: "note.text"
        case .snippets: "text.quote"
        case .cleanup: "sparkles"
        case .diskSpace: "chart.pie"
        case .organize: "folder.badge.gearshape"
        case .clipboard: "clipboard"
        case .voiceRecorder: "mic"
        case .screenshot: "camera.viewfinder"
        case .screenRecording: "record.circle"
        }
    }

    var panel: DockedToolPanel {
        switch self {
        case .notes: .notes
        case .snippets: .snippets
        case .cleanup: .cleanup
        case .diskSpace: .diskSpace
        case .organize: .organize
        case .clipboard: .clipboard
        case .voiceRecorder: .voiceRecorder
        case .screenshot: .screenshot
        case .screenRecording: .recording
        }
    }

    var help: String {
        switch self {
        case .notes: "Open notes"
        case .snippets: "Save reusable text, images, and files"
        case .cleanup: "Find large, old, and unused files"
        case .diskSpace: "Analyze disk space by type, date, size, and apps"
        case .organize: "Sort files in a folder into subfolders"
        case .clipboard: "Open clipboard history"
        case .voiceRecorder: "Record audio into the active folder"
        case .screenshot: "Capture a screenshot"
        case .screenRecording: "Record the screen"
        }
    }
}

private enum SidebarToolViewMode: String, CaseIterable, Identifiable {
    case list
    case icons
    case labeledIcons

    static let defaultsKey = "sidebar.toolViewMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: "One Line Per Tool"
        case .icons: "Icon Buttons"
        case .labeledIcons: "Big Icons with Labels"
        }
    }

    var systemImage: String {
        switch self {
        case .list: "list.bullet"
        case .icons: "square.grid.2x2"
        case .labeledIcons: "square.grid.2x2.fill"
        }
    }
}

private let sidebarToolActiveBackground = Color(red: 0.0, green: 0.28, blue: 0.14)

enum SidebarLayoutPreferences {
    static let didResetNotification = Notification.Name("WorkbenchSidebarLayoutDidReset")
    static let sectionOrderKey = "sidebar.sectionOrder"
    static let placeOrderKey = "sidebar.placeOrder"
    static let deviceOrderKey = "sidebar.deviceOrder"
    static let toolOrderKey = "sidebar.toolOrder"
    static let notesSnippetsOrderMigrationKey = "sidebar.toolOrder.notesSnippetsFirst"
    static let defaultPlaceOrder = ["home", "desktop", "documents", "downloads"]

    static func reset() {
        let defaults = UserDefaults.standard
        [
            sectionOrderKey,
            placeOrderKey,
            deviceOrderKey,
            toolOrderKey,
            SidebarToolViewMode.defaultsKey,
            notesSnippetsOrderMigrationKey,
        ].forEach(defaults.removeObject(forKey:))
        NotificationCenter.default.post(name: didResetNotification, object: nil)
    }
}

private enum SidebarDragHandleMetrics {
    static let sectionSize = CGSize(width: 24, height: 24)
    static let rowSize = CGSize(width: 26, height: 24)
    static let compactIconSize = CGSize(width: 18, height: 18)
    static let labeledIconSize = CGSize(width: 22, height: 22)
}

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(SidebarToolViewMode.defaultsKey) private var toolViewModeRaw = SidebarToolViewMode.list.rawValue
    @State private var orderStore = SidebarOrderStore.shared
    @State private var selection: URL?
    @State private var devices: [Place] = []
    private let isReordering = true
    @State private var draggedSection: SidebarSectionID?
    @State private var sectionDropTarget: SidebarSectionID?
    @State private var draggedPlaceID: String?
    @State private var placeDropTargetID: String?
    @State private var draggedDeviceID: String?
    @State private var deviceDropTargetID: String?
    @State private var draggedFavoriteID: String?
    @State private var favoriteDropTargetID: String?
    @State private var draggedTool: SidebarToolID?
    @State private var toolDropTarget: SidebarToolID?

    fileprivate struct Place: Identifiable {
        let id: String
        let name: String
        let icon: String
        let url: URL
    }

    private var places: [Place] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var result = [Place(id: "home", name: "Home", icon: "house", url: home)]
        let standard: [(String, String, String, FileManager.SearchPathDirectory)] = [
            ("desktop", "Desktop", "menubar.dock.rectangle", .desktopDirectory),
            ("documents", "Documents", "doc", .documentDirectory),
            ("downloads", "Downloads", "arrow.down.circle", .downloadsDirectory),
        ]
        for (id, name, icon, directory) in standard {
            if let url = FileManager.default.urls(for: directory, in: .userDomainMask).first {
                result.append(Place(id: id, name: name, icon: icon, url: url))
            }
        }
        return orderStore.orderedPlaces(result)
    }

    private var favorites: [URL] {
        BookmarkStore.shared.grantedURLs
    }

    private var visibleSections: [SidebarSectionID] {
        var sections: [SidebarSectionID] = [.places]
        if !devices.isEmpty {
            sections.append(.devices)
        }
        if !favorites.isEmpty {
            sections.append(.favorites)
        }
        sections.append(.tools)
        return orderStore.orderedSections(sections)
    }

    private var toolViewMode: SidebarToolViewMode {
        SidebarToolViewMode(rawValue: toolViewModeRaw) ?? .list
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(visibleSections) { section in
                sidebarSection(section)
            }
        }
        .contextMenu {
            Button("Reset Sidebar Layout") {
                SidebarLayoutPreferences.reset()
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            // Dropping a folder pins it as a favorite. Drops from Finder also
            // extend the sandbox to that folder, so save the bookmark right away.
            let folders = urls.filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
            guard !folders.isEmpty else { return false }
            for folder in folders {
                BookmarkStore.shared.save(folder)
            }
            return true
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    appState.showNewFolderPrompt = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New folder in the active pane (⇧⌘N)")
                .clickableCursor()

                Button {
                    if let granted = BookmarkStore.shared.requestAccess(
                        startingAt: appState.activePane.currentURL
                    ) {
                        selection = granted
                        appState.activePane.navigate(to: granted)
                    }
                } label: {
                    Label("Pin to Favorites…", systemImage: "plus.circle")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Add a folder to the sidebar favorites")
                .clickableCursor()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: selection) { _, url in
            guard let url else { return }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if exists && !isDirectory.boolValue {
                // File favorite: reveal it inside its enclosing folder.
                appState.activePane.navigate(to: url.deletingLastPathComponent())
            } else {
                appState.activePane.navigate(to: url)
            }
        }
        .onAppear(perform: refreshDevices)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didMountNotification
        )) { _ in
            refreshDevices()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didUnmountNotification
        )) { _ in
            refreshDevices()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didRenameVolumeNotification
        )) { _ in
            refreshDevices()
        }
        .onReceive(NotificationCenter.default.publisher(for: SidebarLayoutPreferences.didResetNotification)) { _ in
            resetSidebarLayout()
        }
    }

    @ViewBuilder
    private func sidebarSection(_ section: SidebarSectionID) -> some View {
        switch section {
        case .places:
            let orderedPlaces = places
            Section(header: sidebarSectionHeader(section)) {
                ForEach(orderedPlaces) { place in
                    SidebarReorderableLabelRow(
                        title: place.name,
                        systemImage: place.icon,
                        isReordering: isReordering,
                        isDropTarget: placeDropTargetID == place.id,
                        dragHandle: {
                            SidebarStringDragHandle(
                                id: place.id,
                                draggedID: $draggedPlaceID,
                                dropTargetID: $placeDropTargetID
                            )
                        }
                    )
                    .modifier(SidebarStringRowReorderModifier(
                        id: place.id,
                        isEnabled: isReordering,
                        draggedID: $draggedPlaceID,
                        dropTargetID: $placeDropTargetID,
                        move: { source, target in
                            movePlace(source, onto: target, in: orderedPlaces)
                        }
                    ))
                    .tag(place.url)
                }
            }

        case .devices:
            let orderedDevices = orderStore.orderedDevices(devices)
            Section(header: sidebarSectionHeader(section)) {
                ForEach(orderedDevices) { device in
                    SidebarReorderableLabelRow(
                        title: device.name,
                        systemImage: device.icon,
                        help: device.url.path,
                        isReordering: isReordering,
                        isDropTarget: deviceDropTargetID == device.id,
                        dragHandle: {
                            SidebarStringDragHandle(
                                id: device.id,
                                draggedID: $draggedDeviceID,
                                dropTargetID: $deviceDropTargetID
                            )
                        }
                    )
                    .modifier(SidebarStringRowReorderModifier(
                        id: device.id,
                        isEnabled: isReordering,
                        draggedID: $draggedDeviceID,
                        dropTargetID: $deviceDropTargetID,
                        move: { source, target in
                            moveDevice(source, onto: target, in: orderedDevices)
                        }
                    ))
                    .tag(device.url)
                }
            }

        case .favorites:
            let orderedFavorites = favorites
            Section(header: sidebarSectionHeader(section)) {
                ForEach(orderedFavorites, id: \.self) { url in
                    let favoriteID = favoriteReorderID(url)
                    SidebarReorderableLabelRow(
                        title: url.lastPathComponent,
                        systemImage: url.hasDirectoryPath ? "folder" : "doc",
                        isReordering: isReordering,
                        isDropTarget: favoriteDropTargetID == favoriteID,
                        dragHandle: {
                            SidebarStringDragHandle(
                                id: favoriteID,
                                draggedID: $draggedFavoriteID,
                                dropTargetID: $favoriteDropTargetID
                            )
                        }
                    )
                    .modifier(SidebarStringRowReorderModifier(
                        id: favoriteID,
                        isEnabled: isReordering,
                        draggedID: $draggedFavoriteID,
                        dropTargetID: $favoriteDropTargetID,
                        move: { source, target in
                            moveFavorite(source, onto: target, in: orderedFavorites)
                        }
                    ))
                    .tag(url)
                    .contextMenu {
                        Button("Remove from Favorites") {
                            BookmarkStore.shared.remove(url)
                        }
                    }
                }
                // Drop a folder or file between rows to insert it there;
                // SwiftUI draws the blue insertion line automatically.
                .onInsert(of: [UTType.fileURL]) { index, providers in
                    insertFavorites(at: index, providers: providers)
                }
            }

        case .tools:
            let orderedTools = orderStore.orderedTools()
            Section(header: sidebarSectionHeader(section)) {
                toolsSectionContent(orderedTools)
            }
        }
    }

    @ViewBuilder
    private func toolsSectionContent(_ orderedTools: [SidebarToolID]) -> some View {
        switch toolViewMode {
        case .list:
            ForEach(orderedTools) { tool in
                toolListRow(tool, in: orderedTools)
            }

        case .icons:
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 32, maximum: 38), spacing: 5, alignment: .leading)],
                alignment: .leading,
                spacing: 5
            ) {
                ForEach(orderedTools) { tool in
                    toolIconButton(tool, in: orderedTools)
                }
            }
            .padding(.vertical, 4)
            .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 5, trailing: 10))

        case .labeledIcons:
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 74, maximum: 92), spacing: 8, alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(orderedTools) { tool in
                    toolLabeledIconButton(tool, in: orderedTools)
                }
            }
            .padding(.vertical, 5)
            .listRowInsets(EdgeInsets(top: 3, leading: 10, bottom: 6, trailing: 10))
        }
    }

    private func toolListRow(_ tool: SidebarToolID, in orderedTools: [SidebarToolID]) -> some View {
        let isActive = appState.activeToolPanel == tool.panel
        return SidebarToolButton(
            title: tool.title,
            systemImage: tool.systemImage,
            help: tool.help,
            isActive: isActive,
            isDropTarget: toolDropTarget == tool,
            isReordering: isReordering,
            action: {
                performTool(tool)
            },
            dragHandle: {
                SidebarToolDragHandle(
                    tool: tool,
                    draggedTool: $draggedTool,
                    dropTarget: $toolDropTarget,
                    font: .caption,
                    foregroundColor: isActive ? Color.white.opacity(0.75) : Color.secondary,
                    hitSize: SidebarDragHandleMetrics.rowSize
                )
            }
        )
        .modifier(SidebarToolReorderModifier(
            tool: tool,
            draggedTool: $draggedTool,
            dropTarget: $toolDropTarget,
            move: moveTool(_:onto:)
        ))
        .contextMenu {
            toolContextMenu(tool, in: orderedTools)
        }
    }

    private func toolIconButton(_ tool: SidebarToolID, in orderedTools: [SidebarToolID]) -> some View {
        let isActive = appState.activeToolPanel == tool.panel
        return SidebarToolIconButton(
            title: tool.title,
            systemImage: tool.systemImage,
            help: tool.help,
            isActive: isActive,
            isDropTarget: toolDropTarget == tool,
            isReordering: isReordering,
            action: {
                performTool(tool)
            },
            dragHandle: {
                SidebarToolDragHandle(
                    tool: tool,
                    draggedTool: $draggedTool,
                    dropTarget: $toolDropTarget,
                    font: .system(size: 7, weight: .semibold),
                    foregroundColor: isActive ? Color.white.opacity(0.8) : Color.secondary,
                    hitSize: SidebarDragHandleMetrics.compactIconSize
                )
            }
        )
        .modifier(SidebarToolReorderModifier(
            tool: tool,
            draggedTool: $draggedTool,
            dropTarget: $toolDropTarget,
            move: moveTool(_:onto:)
        ))
        .contextMenu {
            toolContextMenu(tool, in: orderedTools)
        }
    }

    private func toolLabeledIconButton(_ tool: SidebarToolID, in orderedTools: [SidebarToolID]) -> some View {
        let isActive = appState.activeToolPanel == tool.panel
        return SidebarToolLabeledIconButton(
            title: tool.title,
            systemImage: tool.systemImage,
            help: tool.help,
            isActive: isActive,
            isDropTarget: toolDropTarget == tool,
            isReordering: isReordering,
            action: {
                performTool(tool)
            },
            dragHandle: {
                SidebarToolDragHandle(
                    tool: tool,
                    draggedTool: $draggedTool,
                    dropTarget: $toolDropTarget,
                    font: .system(size: 8, weight: .semibold),
                    foregroundColor: isActive ? Color.white.opacity(0.82) : Color.secondary,
                    hitSize: SidebarDragHandleMetrics.labeledIconSize
                )
            }
        )
        .modifier(SidebarToolReorderModifier(
            tool: tool,
            draggedTool: $draggedTool,
            dropTarget: $toolDropTarget,
            move: moveTool(_:onto:)
        ))
        .contextMenu {
            toolContextMenu(tool, in: orderedTools)
        }
    }

    @ViewBuilder
    private func toolContextMenu(_ tool: SidebarToolID, in orderedTools: [SidebarToolID]) -> some View {
        Button("Move Up") {
            moveTool(tool, in: orderedTools, by: -1)
        }
        .disabled(!canMove(tool, in: orderedTools, by: -1))

        Button("Move Down") {
            moveTool(tool, in: orderedTools, by: 1)
        }
        .disabled(!canMove(tool, in: orderedTools, by: 1))
    }

    private func sidebarSectionHeader(_ section: SidebarSectionID) -> some View {
        HStack(spacing: 6) {
            Text(section.title)
            if isReordering {
                SidebarSectionDragHandle(
                    section: section,
                    draggedSection: $draggedSection,
                    dropTarget: $sectionDropTarget
                )
            }
            Spacer(minLength: 8)
            if section == .tools {
                Picker("Tools View", selection: $toolViewModeRaw) {
                    ForEach(SidebarToolViewMode.allCases) { mode in
                        Image(systemName: mode.systemImage)
                            .tag(mode.rawValue)
                            .help(mode.title)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.regular)
                .frame(width: 135)
                .help("Change tools view")
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background {
            if sectionDropTarget == section {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
            }
        }
        .contentShape(Rectangle())
        .modifier(SidebarSectionReorderModifier(
            section: section,
            isEnabled: isReordering,
            draggedSection: $draggedSection,
            dropTarget: $sectionDropTarget,
            move: moveSection(_:onto:)
        ))
    }

    private func canMove<ID: Equatable>(_ id: ID, in orderedIDs: [ID], by offset: Int) -> Bool {
        guard let index = orderedIDs.firstIndex(of: id) else { return false }
        return orderedIDs.indices.contains(index + offset)
    }

    private func moveSection(_ source: SidebarSectionID, onto target: SidebarSectionID) {
        let orderedSections = visibleSections
        guard source != target,
              let sourceIndex = orderedSections.firstIndex(of: source),
              let targetIndex = orderedSections.firstIndex(of: target) else { return }
        orderStore.moveSections(
            fromOffsets: IndexSet(integer: sourceIndex),
            toOffset: sourceIndex < targetIndex ? targetIndex + 1 : targetIndex,
            visible: orderedSections
        )
    }

    private func movePlace(_ sourceID: String, onto targetID: String, in orderedPlaces: [Place]) {
        let ids = orderedPlaces.map(\.id)
        guard sourceID != targetID,
              let sourceIndex = ids.firstIndex(of: sourceID),
              let targetIndex = ids.firstIndex(of: targetID) else { return }
        orderStore.movePlaces(
            fromOffsets: IndexSet(integer: sourceIndex),
            toOffset: sourceIndex < targetIndex ? targetIndex + 1 : targetIndex,
            visible: ids
        )
    }

    private func moveDevice(_ sourceID: String, onto targetID: String, in orderedDevices: [Place]) {
        let ids = orderedDevices.map(\.id)
        guard sourceID != targetID,
              let sourceIndex = ids.firstIndex(of: sourceID),
              let targetIndex = ids.firstIndex(of: targetID) else { return }
        orderStore.moveDevices(
            fromOffsets: IndexSet(integer: sourceIndex),
            toOffset: sourceIndex < targetIndex ? targetIndex + 1 : targetIndex,
            visible: ids
        )
    }

    private func moveFavorite(_ sourceID: String, onto targetID: String, in orderedFavorites: [URL]) {
        let ids = orderedFavorites.map(favoriteReorderID)
        guard sourceID != targetID,
              let sourceIndex = ids.firstIndex(of: sourceID),
              let targetIndex = ids.firstIndex(of: targetID) else { return }
        BookmarkStore.shared.move(
            fromOffsets: IndexSet(integer: sourceIndex),
            toOffset: sourceIndex < targetIndex ? targetIndex + 1 : targetIndex
        )
    }

    private func favoriteReorderID(_ url: URL) -> String {
        url.standardizedFileURL.absoluteString
    }

    private func moveTool(_ tool: SidebarToolID, in orderedTools: [SidebarToolID], by offset: Int) {
        guard let index = orderedTools.firstIndex(of: tool) else { return }
        orderStore.moveTools(
            fromOffsets: IndexSet(integer: index),
            toOffset: destinationOffset(from: index, by: offset)
        )
    }

    private func moveTool(_ source: SidebarToolID, onto target: SidebarToolID) {
        let orderedTools = orderStore.orderedTools()
        guard source != target,
              let sourceIndex = orderedTools.firstIndex(of: source),
              let targetIndex = orderedTools.firstIndex(of: target) else { return }
        orderStore.moveTools(
            fromOffsets: IndexSet(integer: sourceIndex),
            toOffset: sourceIndex < targetIndex ? targetIndex + 1 : targetIndex
        )
    }

    private func destinationOffset(from index: Int, by offset: Int) -> Int {
        let destination = index + offset
        return offset > 0 ? destination + 1 : destination
    }

    private func performTool(_ tool: SidebarToolID) {
        switch tool {
        case .organize:
            appState.showOrganizeTool()
        case .cleanup:
            appState.showCleanupTool()
        case .diskSpace:
            appState.showDiskSpaceAnalyzer()
        case .clipboard:
            appState.showClipboardHistory()
        case .notes:
            appState.showNotes()
        case .snippets:
            appState.showSnippets()
        case .voiceRecorder:
            appState.showVoiceRecorderTool()
        case .screenshot:
            appState.beginScreenshotCapture()
        case .screenRecording:
            appState.beginScreenRecording()
        }
    }

    private func refreshDevices() {
        devices = orderStore.orderedDevices(Self.externalVolumePlaces())
    }

    private func resetSidebarLayout() {
        orderStore.resetLayout()
        toolViewModeRaw = SidebarToolViewMode.list.rawValue
        draggedSection = nil
        sectionDropTarget = nil
        draggedPlaceID = nil
        placeDropTargetID = nil
        draggedDeviceID = nil
        deviceDropTargetID = nil
        draggedFavoriteID = nil
        favoriteDropTargetID = nil
        draggedTool = nil
        toolDropTarget = nil
        refreshDevices()
    }

    private static func externalVolumePlaces() -> [Place] {
        let keys: [URLResourceKey] = [
            .volumeIsBrowsableKey,
            .volumeIsEjectableKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeLocalizedNameKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable != false,
                  values.volumeIsInternal != true,
                  values.volumeIsEjectable == true || values.volumeIsRemovable == true
                    || values.volumeIsInternal == false else { return nil }
            let name = values.volumeLocalizedName
                ?? (url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
            let standardized = url.standardizedFileURL
            return Place(id: standardized.path, name: name, icon: "externaldrive", url: standardized)
        }
        .sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func insertFavorites(at index: Int, providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                let url: URL? = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    ?? (item as? URL)
                guard let resolved = url else { return }
                Task { @MainActor in
                    BookmarkStore.shared.insert(resolved, at: index)
                }
            }
        }
    }
}

@Observable
@MainActor
private final class SidebarOrderStore {
    static let shared = SidebarOrderStore()

    private static let defaultToolOrder: [SidebarToolID] = [
        .notes,
        .snippets,
        .cleanup,
        .diskSpace,
        .organize,
        .clipboard,
        .voiceRecorder,
        .screenshot,
        .screenRecording,
    ]

    private var sectionOrder: [SidebarSectionID]
    private var placeOrder: [String]
    private var deviceOrder: [String]
    private var toolOrder: [SidebarToolID]

    private init() {
        sectionOrder = Self.loadEnumArray(
            key: SidebarLayoutPreferences.sectionOrderKey,
            allCases: SidebarSectionID.allCases
        )
        placeOrder = Self.loadStringArray(
            key: SidebarLayoutPreferences.placeOrderKey,
            fallback: SidebarLayoutPreferences.defaultPlaceOrder
        )
        deviceOrder = Self.loadStringArray(key: SidebarLayoutPreferences.deviceOrderKey, fallback: [])
        toolOrder = Self.loadEnumArray(
            key: SidebarLayoutPreferences.toolOrderKey,
            allCases: Self.defaultToolOrder
        )
        migrateNotesAndSnippetsToTopIfNeeded()
    }

    func orderedSections(_ available: [SidebarSectionID]) -> [SidebarSectionID] {
        orderedIDs(
            available,
            stored: sectionOrder,
            allCases: SidebarSectionID.allCases
        )
    }

    func orderedPlaces(_ places: [SidebarView.Place]) -> [SidebarView.Place] {
        orderedByStringIDs(places, stored: placeOrder)
    }

    func orderedDevices(_ devices: [SidebarView.Place]) -> [SidebarView.Place] {
        orderedByStringIDs(devices, stored: deviceOrder)
    }

    func orderedTools() -> [SidebarToolID] {
        orderedIDs(
            SidebarToolID.allCases,
            stored: toolOrder,
            allCases: Self.defaultToolOrder
        )
    }

    private func migrateNotesAndSnippetsToTopIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: SidebarLayoutPreferences.notesSnippetsOrderMigrationKey) else { return }
        let primaryTools: [SidebarToolID] = [.notes, .snippets]
        let current = orderedIDs(
            SidebarToolID.allCases,
            stored: toolOrder,
            allCases: Self.defaultToolOrder
        )
        toolOrder = primaryTools.filter { current.contains($0) }
            + current.filter { !primaryTools.contains($0) }
        persistEnumArray(toolOrder, key: SidebarLayoutPreferences.toolOrderKey)
        UserDefaults.standard.set(true, forKey: SidebarLayoutPreferences.notesSnippetsOrderMigrationKey)
    }

    func resetLayout() {
        sectionOrder = SidebarSectionID.allCases
        placeOrder = SidebarLayoutPreferences.defaultPlaceOrder
        deviceOrder = []
        toolOrder = Self.defaultToolOrder
        persistEnumArray(sectionOrder, key: SidebarLayoutPreferences.sectionOrderKey)
        persistStringArray(placeOrder, key: SidebarLayoutPreferences.placeOrderKey)
        persistStringArray(deviceOrder, key: SidebarLayoutPreferences.deviceOrderKey)
        persistEnumArray(toolOrder, key: SidebarLayoutPreferences.toolOrderKey)
        UserDefaults.standard.set(true, forKey: SidebarLayoutPreferences.notesSnippetsOrderMigrationKey)
    }

    func moveSections(
        fromOffsets source: IndexSet,
        toOffset destination: Int,
        visible: [SidebarSectionID]
    ) {
        var visibleOrder = visible
        visibleOrder.moveItems(fromOffsets: source, toOffset: destination)
        let visibleSet = Set(visible)
        var movedIterator = visibleOrder.makeIterator()
        sectionOrder = orderedIDs(
            SidebarSectionID.allCases,
            stored: sectionOrder,
            allCases: SidebarSectionID.allCases
        ).map { section in
            visibleSet.contains(section) ? movedIterator.next() ?? section : section
        }
        persistEnumArray(sectionOrder, key: SidebarLayoutPreferences.sectionOrderKey)
    }

    func movePlaces(fromOffsets source: IndexSet, toOffset destination: Int, visible: [String]) {
        placeOrder = movedStringOrder(
            source: source,
            destination: destination,
            visible: visible,
            stored: placeOrder
        )
        persistStringArray(placeOrder, key: SidebarLayoutPreferences.placeOrderKey)
    }

    func moveDevices(fromOffsets source: IndexSet, toOffset destination: Int, visible: [String]) {
        deviceOrder = movedStringOrder(
            source: source,
            destination: destination,
            visible: visible,
            stored: deviceOrder
        )
        persistStringArray(deviceOrder, key: SidebarLayoutPreferences.deviceOrderKey)
    }

    func moveTools(fromOffsets source: IndexSet, toOffset destination: Int) {
        toolOrder = orderedTools()
        toolOrder.moveItems(fromOffsets: source, toOffset: destination)
        persistEnumArray(toolOrder, key: SidebarLayoutPreferences.toolOrderKey)
    }

    private func orderedIDs<ID>(
        _ available: [ID],
        stored: [ID],
        allCases: [ID]
    ) -> [ID] where ID: Hashable {
        let availableSet = Set(available)
        let storedAvailable = stored.filter { availableSet.contains($0) }
        let newItems = allCases.filter { availableSet.contains($0) && !storedAvailable.contains($0) }
        return storedAvailable + newItems
    }

    private func orderedByStringIDs(_ places: [SidebarView.Place], stored: [String]) -> [SidebarView.Place] {
        let byID = Dictionary(uniqueKeysWithValues: places.map { ($0.id, $0) })
        let storedPlaces = stored.compactMap { byID[$0] }
        let newPlaces = places.filter { !stored.contains($0.id) }
        return storedPlaces + newPlaces
    }

    private func movedStringOrder(
        source: IndexSet,
        destination: Int,
        visible: [String],
        stored: [String]
    ) -> [String] {
        var visibleOrder = visible
        visibleOrder.moveItems(fromOffsets: source, toOffset: destination)
        let visibleSet = Set(visible)
        let hidden = stored.filter { !visibleSet.contains($0) }
        return visibleOrder + hidden
    }

    private func persistEnumArray<ID>(_ ids: [ID], key: String) where ID: RawRepresentable, ID.RawValue == String {
        UserDefaults.standard.set(ids.map(\.rawValue), forKey: key)
    }

    private func persistStringArray(_ ids: [String], key: String) {
        UserDefaults.standard.set(ids, forKey: key)
    }

    private static func loadEnumArray<ID>(
        key: String,
        allCases: [ID]
    ) -> [ID] where ID: RawRepresentable, ID.RawValue == String, ID: Hashable {
        let rawValues = UserDefaults.standard.stringArray(forKey: key) ?? []
        let saved = rawValues.compactMap(ID.init(rawValue:))
        let missing = allCases.filter { !saved.contains($0) }
        return saved + missing
    }

    private static func loadStringArray(key: String, fallback: [String]) -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? fallback
    }
}

private extension Array {
    mutating func moveItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { self[$0] }
        for index in source.sorted(by: >) {
            remove(at: index)
        }
        let adjustedDestination = destination - source.filter { $0 < destination }.count
        insert(
            contentsOf: moving,
            at: Swift.min(Swift.max(adjustedDestination, 0), count)
        )
    }
}

private struct SidebarReorderableLabelRow<DragHandle: View>: View {
    let title: String
    let systemImage: String
    var help: String?
    let isReordering: Bool
    var isDropTarget = false
    @ViewBuilder let dragHandle: () -> DragHandle

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isReordering {
                dragHandle()
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            }
        }
        .contentShape(Rectangle())
        .clickableCursor()
        .help(help ?? title)
    }
}

private struct SidebarSectionDragHandle: View {
    let section: SidebarSectionID
    @Binding var draggedSection: SidebarSectionID?
    @Binding var dropTarget: SidebarSectionID?

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(dropTarget == section ? Color.accentColor : Color.secondary)
            .frame(
                width: SidebarDragHandleMetrics.sectionSize.width,
                height: SidebarDragHandleMetrics.sectionSize.height
            )
            .contentShape(Rectangle())
            .draggableCursor()
            .help("Drag to reorder section")
            .onDrag {
                draggedSection = section
                dropTarget = nil
                return NSItemProvider(object: section.rawValue as NSString)
            }
    }
}

private struct SidebarStringDragHandle: View {
    let id: String
    @Binding var draggedID: String?
    @Binding var dropTargetID: String?

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.caption)
            .foregroundStyle(dropTargetID == id ? Color.accentColor : Color.secondary)
            .frame(
                width: SidebarDragHandleMetrics.rowSize.width,
                height: SidebarDragHandleMetrics.rowSize.height
            )
            .contentShape(Rectangle())
            .draggableCursor()
            .help("Drag to reorder")
            .onDrag {
                draggedID = id
                dropTargetID = nil
                return NSItemProvider(object: id as NSString)
            }
    }
}

private struct SidebarToolDragHandle: View {
    let tool: SidebarToolID
    @Binding var draggedTool: SidebarToolID?
    @Binding var dropTarget: SidebarToolID?
    var font: Font
    var foregroundColor: Color
    var hitSize: CGSize

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(font)
            .foregroundStyle(dropTarget == tool ? Color.accentColor : foregroundColor)
            .frame(width: hitSize.width, height: hitSize.height)
            .contentShape(Rectangle())
            .draggableCursor()
            .help("Drag to reorder")
            .onDrag {
                draggedTool = tool
                dropTarget = nil
                return NSItemProvider(object: tool.rawValue as NSString)
            }
    }
}

private struct SidebarSectionDropDelegate: DropDelegate {
    let target: SidebarSectionID
    @Binding var draggedSection: SidebarSectionID?
    @Binding var dropTarget: SidebarSectionID?
    let move: (SidebarSectionID, SidebarSectionID) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedSection,
              draggedSection != target,
              dropTarget != target else { return }
        dropTarget = target
        move(draggedSection, target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedSection = nil
        dropTarget = nil
        return true
    }
}

private struct SidebarSectionReorderModifier: ViewModifier {
    let section: SidebarSectionID
    let isEnabled: Bool
    @Binding var draggedSection: SidebarSectionID?
    @Binding var dropTarget: SidebarSectionID?
    let move: (SidebarSectionID, SidebarSectionID) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .onDrop(
                    of: [UTType.text, UTType.plainText],
                    delegate: SidebarSectionDropDelegate(
                        target: section,
                        draggedSection: $draggedSection,
                        dropTarget: $dropTarget,
                        move: move
                    )
                )
        } else {
            content
        }
    }
}

private struct SidebarStringRowDropDelegate: DropDelegate {
    let target: String
    @Binding var draggedID: String?
    @Binding var dropTargetID: String?
    let move: (String, String) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedID,
              draggedID != target,
              dropTargetID != target else { return }
        dropTargetID = target
        move(draggedID, target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        dropTargetID = nil
        return true
    }
}

private struct SidebarStringRowReorderModifier: ViewModifier {
    let id: String
    let isEnabled: Bool
    @Binding var draggedID: String?
    @Binding var dropTargetID: String?
    let move: (String, String) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .onDrop(
                    of: [UTType.text, UTType.plainText],
                    delegate: SidebarStringRowDropDelegate(
                        target: id,
                        draggedID: $draggedID,
                        dropTargetID: $dropTargetID,
                        move: move
                    )
                )
        } else {
            content
        }
    }
}

private struct SidebarToolDropDelegate: DropDelegate {
    let target: SidebarToolID
    @Binding var draggedTool: SidebarToolID?
    @Binding var dropTarget: SidebarToolID?
    let move: (SidebarToolID, SidebarToolID) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedTool, draggedTool != target, dropTarget != target else { return }
        dropTarget = target
        move(draggedTool, target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedTool = nil
        dropTarget = nil
        return true
    }
}

private struct SidebarToolReorderModifier: ViewModifier {
    let tool: SidebarToolID
    @Binding var draggedTool: SidebarToolID?
    @Binding var dropTarget: SidebarToolID?
    let move: (SidebarToolID, SidebarToolID) -> Void

    func body(content: Content) -> some View {
        content
            .onDrop(
                of: [UTType.text, UTType.plainText],
                delegate: SidebarToolDropDelegate(
                    target: tool,
                    draggedTool: $draggedTool,
                    dropTarget: $dropTarget,
                    move: move
                )
            )
    }
}

private struct SidebarToolButton<DragHandle: View>: View {
    let title: String
    let systemImage: String
    let help: String
    let isActive: Bool
    let isDropTarget: Bool
    let isReordering: Bool
    let action: () -> Void
    @ViewBuilder let dragHandle: () -> DragHandle

    private var activeBackgroundColor: Color {
        sidebarToolActiveBackground
    }

    private var rowBackgroundColor: Color {
        if isDropTarget {
            Color.accentColor.opacity(0.10)
        } else if isActive {
            activeBackgroundColor
        } else {
            Color.clear
        }
    }

    private var primaryForegroundColor: Color {
        isActive ? .white : .primary
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: action) {
                Label {
                    Text(title)
                        .foregroundStyle(primaryForegroundColor)
                } icon: {
                    Image(systemName: systemImage)
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(primaryForegroundColor)
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(primaryForegroundColor)
            .clickableCursor()

            if isReordering {
                dragHandle()
            }
        }
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowBackgroundColor)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .help(help)
    }
}

private struct SidebarToolIconButton<DragHandle: View>: View {
    let title: String
    let systemImage: String
    let help: String
    let isActive: Bool
    let isDropTarget: Bool
    let isReordering: Bool
    let action: () -> Void
    @ViewBuilder let dragHandle: () -> DragHandle

    @State private var showsNameTooltip = false
    @State private var tooltipTask: Task<Void, Never>?

    private var backgroundColor: Color {
        if isDropTarget {
            Color.accentColor.opacity(0.14)
        } else if isActive {
            sidebarToolActiveBackground
        } else {
            Color.clear
        }
    }

    private var foregroundColor: Color {
        isActive ? .white : .primary
    }

    private var borderColor: Color {
        if isDropTarget {
            Color.accentColor.opacity(0.55)
        } else if isActive {
            Color.white.opacity(0.18)
        } else {
            Color.secondary.opacity(0.20)
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(foregroundColor)
                .frame(width: 31, height: 31)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(backgroundColor)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isActive || isDropTarget ? 1 : 0.5)
        }
        .overlay(alignment: .bottomTrailing) {
            if isReordering {
                dragHandle()
                    .padding(2)
            }
        }
        .overlay(alignment: .top) {
            if showsNameTooltip {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
                    }
                    .shadow(color: Color.black.opacity(0.12), radius: 5, y: 2)
                    .offset(y: -30)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .allowsHitTesting(false)
                    .zIndex(1)
            }
        }
        .zIndex(showsNameTooltip ? 1 : 0)
        .onHover { hovering in
            tooltipTask?.cancel()
            if hovering {
                tooltipTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.08)) {
                        showsNameTooltip = true
                    }
                }
            } else {
                withAnimation(.easeOut(duration: 0.06)) {
                    showsNameTooltip = false
                }
            }
        }
        .onDisappear {
            tooltipTask?.cancel()
            showsNameTooltip = false
        }
        .help("\(title): \(help)")
        .accessibilityLabel(title)
    }
}

private struct SidebarToolLabeledIconButton<DragHandle: View>: View {
    let title: String
    let systemImage: String
    let help: String
    let isActive: Bool
    let isDropTarget: Bool
    let isReordering: Bool
    let action: () -> Void
    @ViewBuilder let dragHandle: () -> DragHandle

    private var backgroundColor: Color {
        if isDropTarget {
            Color.accentColor.opacity(0.14)
        } else if isActive {
            sidebarToolActiveBackground
        } else {
            Color.secondary.opacity(0.055)
        }
    }

    private var foregroundColor: Color {
        isActive ? .white : .primary
    }

    private var borderColor: Color {
        if isDropTarget {
            Color.accentColor.opacity(0.55)
        } else if isActive {
            Color.white.opacity(0.18)
        } else {
            Color.secondary.opacity(0.16)
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(foregroundColor)
                    .frame(height: 26)

                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(foregroundColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .top)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 70)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(backgroundColor)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isActive || isDropTarget ? 1 : 0.5)
        }
        .overlay(alignment: .bottomTrailing) {
            if isReordering {
                dragHandle()
                    .padding(3)
            }
        }
        .help("\(title): \(help)")
        .accessibilityLabel(title)
    }
}
