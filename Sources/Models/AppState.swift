import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Docked tool panels — only one may be active at a time.
enum DockedToolPanel: String, Equatable {
    case cleanup
    case diskSpace
    case clipboard
    case notes
    case calendar
    case calculator
    case terminal
    case snippets
    case dropStack
    case workflows
    case advancedSearch
    case archiveBrowser
    case preview
    case organize
    case screenshot
    case recording
    case voiceRecorder
    case pomodoro
}

enum CapturePermissionRequirement: String, CaseIterable, Identifiable {
    case screenRecording
    case microphone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .microphone: "Microphone"
        }
    }

    var detail: String {
        switch self {
        case .screenRecording:
            "Required before Workbench can capture screenshots or record the screen."
        case .microphone:
            "Required before Workbench can record narration or voice notes."
        }
    }

    var systemImage: String {
        switch self {
        case .screenRecording: "record.circle"
        case .microphone: "mic"
        }
    }
}

struct CapturePermissionPrompt: Identifiable {
    let id = UUID()
    let kind: CaptureKind
    let required: [CapturePermissionRequirement]
    let missing: [CapturePermissionRequirement]

    var title: String {
        "\(kind.title) Permissions"
    }
}

enum PDFToolSheetMode: Equatable {
    case extractPages
    case watermark
    case protect
    case removePassword

    var title: String {
        switch self {
        case .extractPages: "Extract PDF Pages"
        case .watermark: "Add Text Watermark"
        case .protect: "Protect PDF"
        case .removePassword: "Remove PDF Password"
        }
    }
}

private struct FileDragSession {
    let id: String
    let urls: [URL]
    let sourcePaneIndex: Int
    let defaultsToMove: Bool
}

enum FileDropOperationPolicy {
    static func shouldMove(
        isInternalDrag: Bool,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        if modifiers.contains(.option) { return false }
        return isInternalDrag || modifiers.contains(.command)
    }
}

enum MountedVolumeSupport {
    nonisolated static func contains(_ candidate: URL, volumeRoot: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = volumeRoot.standardizedFileURL.pathComponents
        return candidateComponents.starts(with: rootComponents)
    }

    nonisolated static func isMounted(_ volumeURL: URL, among mountedVolumes: [URL]) -> Bool {
        let targetPath = volumeURL.standardizedFileURL.path
        return mountedVolumes.contains {
            $0.standardizedFileURL.path == targetPath
        }
    }

    nonisolated static func isMounted(_ volumeURL: URL) -> Bool {
        let mountedVolumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: []
        ) ?? []
        return isMounted(volumeURL, among: mountedVolumes)
    }
}

extension Notification.Name {
    static let workbenchMountedVolumesChanged = Notification.Name(
        "WorkbenchMountedVolumesChanged"
    )
}

/// App-wide state: the two panes, which one is active, global toggles, and the
/// entry points that menu commands and toolbar buttons call.
@Observable
@MainActor
final class AppState {
    static let shared = AppState()
    static let internalFileDragType = UTType(exportedAs: "com.qnsub.workbench.file-drag")

    let panes: [PaneModel]
    var activePaneIndex = 0 {
        didSet {
            if activePaneIndex < 0 || activePaneIndex >= panes.count {
                activePaneIndex = 0
            }
            savePersistentState()
        }
    }
    var isDualPane = true {
        didSet {
            if !isDualPane { activePaneIndex = 0 }
            savePersistentState()
        }
    }
    var hasCurrentFileDragSession: Bool {
        currentFileDragSession != nil
    }
    var showHidden = false {
        didSet {
            panes.forEach { $0.showHidden = showHidden }
            savePersistentState()
        }
    }
    var autoCalculateFolderSizes = false {
        didSet {
            panes.forEach { $0.autoCalculateFolderSizes = autoCalculateFolderSizes }
            savePersistentState()
        }
    }
    var foldersFirst = true {
        didSet {
            panes.forEach { $0.foldersFirst = foldersFirst }
            savePersistentState()
        }
    }
    var fileGridThumbnailSize = FileGridThumbnailSettings.restoredValue()

    var lastError: String?
    var quickLookURL: URL?
    var showNewFolderPrompt = false
    var showNewFilePrompt = false
    var showMoveIntoNewFolderPrompt = false
    var moveIntoNewFolderURLs: [URL] = []
    var moveIntoNewFolderParentURL: URL?
    var showGoToPrompt = false
    var renameTarget: FileItem?
    var renamePaneIndex: Int?
    /// The single docked tool panel visible in the main window, if any.
    var activeToolPanel: DockedToolPanel? {
        didSet {
            if oldValue == .preview || activeToolPanel == .preview {
                savePersistentState()
            }
        }
    }
    var showResizeSheet = false
    var resizeTargets: [FileItem] = []
    var showBatchRenameSheet = false
    var batchRenameTargets: [FileItem] = []
    var showConvertSheet = false
    var convertTargets: [FileItem] = []
    var showPDFToolSheet = false
    var pdfToolTarget: FileItem?
    var pdfToolMode: PDFToolSheetMode?
    var pdfToolPageCount = 0
    var showMergeIntoVideoSheet = false
    var mergeIntoVideoTargets: [FileItem] = []
    var showPreviewSlideshow = false
    var previewSlideshowItems: [FileItem] = []
    var annotationTarget: FileItem?
    var textEditorSession: TextEditorSession?
    var showOnboarding = false
    var showAboutWorkbench = false
    var showUpdatePanel = false
    var showKeyboardShortcuts = false
    var showActivityHistory = false
    var showReleaseChecklist = false
    var showCommandPalette = false
    var capturePermissionPrompt: CapturePermissionPrompt?
    var proToolsEnabled = UserDefaults.standard.bool(
        forKey: ProToolsAccessPolicy.enabledDefaultsKey
    ) {
        didSet {
            UserDefaults.standard.set(
                proToolsEnabled,
                forKey: ProToolsAccessPolicy.enabledDefaultsKey
            )
        }
    }
    var isEnablingProTools = false
    var proToolsPermissionPrompt: ProToolsPermissionPrompt?
    /// Non-nil while a video merge render is in flight (0…1).
    var mergeIntoVideoProgress: Double?
    private var mergeIntoVideoTask: Task<Void, Never>?
    var fileActivities: [FileActivity] = []
    var fileOperationConflictPolicy: FileConflictPolicy = .keepBoth
    var undoStack: [FileUndoAction] = []
    @ObservationIgnored private var activityTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pausedActivityIDs = Set<UUID>()
    @ObservationIgnored private var lastFolderCompareResult: FolderCompareResult?
    @ObservationIgnored private var lastFolderCompareLeftURL: URL?
    @ObservationIgnored private var lastFolderCompareRightURL: URL?
    @ObservationIgnored private var currentFileDragSession: FileDragSession?
    @ObservationIgnored private var targetedFileDropDestinations: [UUID: URL] = [:]
    @ObservationIgnored private let permissionsManager = PermissionsManager()
    /// Incremented by the ⌘F command; the active pane's search field focuses on change.
    var searchFocusTick = 0

    var activePane: PaneModel { panes[activePaneIndex] }
    var inactivePane: PaneModel { panes[activePaneIndex == 0 ? 1 : 0] }
    var currentlyAccessedFolderPaths: Set<String> {
        let visiblePanes = isDualPane ? panes : [panes[0]]
        return Set(visiblePanes.map { $0.currentURL.standardizedFileURL.path })
    }
    var canUndoFileOperation: Bool { !undoStack.isEmpty }
    var clipboardFileCount: Int { fileURLsFromPasteboard().count }
    var canPasteFilesFromClipboard: Bool { clipboardFileCount > 0 }
    var clipboardFileOperation: FilePasteboard.Operation {
        FilePasteboard.operation(from: NSPasteboard.general)
    }
    var hasActiveSelection: Bool { !activePane.selection.isEmpty }
    var hasSelectedImage: Bool { activePane.selectedItems.contains(where: \.isImage) }
    var canTransferSelectionToOtherPane: Bool { isDualPane && hasActiveSelection }
    var canShareSelectionViaAirDrop: Bool { hasActiveSelection }
    var canAnnotateSelection: Bool { hasSelectedImage }
    var canAddSelectionToDropStack: Bool { hasActiveSelection }
    var canTransferDropStackToOtherPane: Bool {
        isDualPane && !DropStackStore.shared.existingItems.isEmpty
    }
    var undoFileOperationTitle: String {
        undoStack.last.map { "Undo \($0.title)" } ?? "Undo"
    }

    var selectionTransferUnavailableReason: String? {
        switch (isDualPane, hasActiveSelection) {
        case (false, false):
            "Open two panes and select one or more files."
        case (false, true):
            "Open two panes to copy or move files there."
        case (true, false):
            "Select one or more files first."
        case (true, true):
            nil
        }
    }

    var airDropUnavailableReason: String? {
        hasActiveSelection ? nil : "Select one or more files to share."
    }

    var annotateUnavailableReason: String? {
        hasSelectedImage ? nil : "Select an image to annotate."
    }

    var addSelectionToDropStackUnavailableReason: String? {
        hasActiveSelection ? nil : "Select one or more files first."
    }

    var dropStackTransferUnavailableReason: String? {
        switch (isDualPane, DropStackStore.shared.existingItems.isEmpty) {
        case (false, true):
            "Open two panes and add files to the drop stack."
        case (false, false):
            "Open two panes to copy or move the drop stack there."
        case (true, true):
            "Add files to the drop stack first."
        case (true, false):
            nil
        }
    }

    func workflowRunUnavailableReason(source: SavedWorkflowRunSource) -> String? {
        guard let workflow = SavedWorkflowStore.shared.selectedWorkflow else {
            return "Select or create a workflow first."
        }
        guard !workflow.steps.isEmpty else {
            return "Add at least one step to the selected workflow."
        }
        if workflow.steps.contains(where: \.requiresDualPane), !isDualPane {
            return "Open two panes for this workflow."
        }
        switch source {
        case .selection:
            return hasActiveSelection ? nil : "Select one or more files first."
        case .dropStack:
            return DropStackStore.shared.existingItems.isEmpty
                ? "Add files to the drop stack first."
                : nil
        }
    }

    func canRunSelectedWorkflow(source: SavedWorkflowRunSource) -> Bool {
        workflowRunUnavailableReason(source: source) == nil
    }

    func setFileGridThumbnailSize(_ size: Double, persist: Bool = false) {
        fileGridThumbnailSize = FileGridThumbnailSettings.clampedValue(size)
        if persist {
            persistFileGridThumbnailSize()
        }
    }

    func persistFileGridThumbnailSize() {
        UserDefaults.standard.set(
            FileGridThumbnailSettings.clampedValue(fileGridThumbnailSize),
            forKey: FileGridThumbnailSettings.defaultsKey
        )
    }

    private init() {
        BookmarkStore.shared.restoreAll()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let restored = RestoredFinderState(home: home)
        panes = [
            PaneModel(tabs: restored.paneTabs[0], activeTabIndex: restored.activeTabIndexes[0]),
            PaneModel(tabs: restored.paneTabs[1], activeTabIndex: restored.activeTabIndexes[1]),
        ]
        activePaneIndex = restored.isDualPane ? restored.activePaneIndex : 0
        isDualPane = restored.isDualPane
        showHidden = restored.showHidden
        autoCalculateFolderSizes = restored.autoCalculateFolderSizes
        foldersFirst = restored.foldersFirst
        activeToolPanel = restored.showPreview ? .preview : nil
        panes.forEach { pane in
            pane.showHidden = showHidden
            pane.autoCalculateFolderSizes = autoCalculateFolderSizes
            pane.foldersFirst = foldersFirst
            pane.persistentStateChanged = { [weak self] in
                self?.savePersistentState()
            }
            pane.folderAccessChanged = { [weak self] previousURL, _ in
                guard let self,
                      !self.currentlyAccessedFolderPaths.contains(previousURL.path) else {
                    return
                }
                RecentFolderStore.shared.record(previousURL)
            }
        }
        ClipboardHistoryStore.shared.startMonitoring()
        savePersistentState()
    }

    func toggleDualPane() {
        let folderBeingClosed = isDualPane
            ? panes[1].currentURL.standardizedFileURL
            : nil
        isDualPane.toggle()
        if !isDualPane { activePaneIndex = 0 }
        if let folderBeingClosed,
           !currentlyAccessedFolderPaths.contains(folderBeingClosed.path) {
            RecentFolderStore.shared.record(folderBeingClosed)
        }
    }

    func newTabInActivePane() {
        activePane.newTab()
    }

    func closeActiveTab() {
        activePane.closeCurrentTab()
    }

    func selectNextTab() {
        activePane.selectNextTab()
    }

    func selectPreviousTab() {
        activePane.selectPreviousTab()
    }

    func goHome() {
        activePane.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
    }

    func goTo(path: String) {
        if !activePane.goToFolder(path: path) {
            lastError = "No folder found at “\(path)”."
        }
    }

    func copyPath(of url: URL) {
        ClipboardHistoryStore.shared.copyPaths([url.path])
    }

    // MARK: - Selection actions

    func quickLookSelection() {
        if quickLookURL != nil {
            quickLookURL = nil
            return
        }
        quickLookURL = activePane.selectedItems.first?.url
    }

    func beginScreenshot() {
        let kind = CaptureKind(
            rawValue: UserDefaults.standard.string(forKey: "capture.kind") ?? ""
        ) ?? .screenshot
        beginCaptureTool(kind, togglesExistingPanel: true)
    }

    func beginScreenshotCapture() {
        beginCaptureTool(.screenshot, togglesExistingPanel: true)
    }

    func beginScreenRecording() {
        beginCaptureTool(.recording, togglesExistingPanel: true)
    }

    func selectCaptureKindInPanel(_ kind: CaptureKind) {
        beginCaptureTool(kind, togglesExistingPanel: false)
    }

    func hideCaptureTool() {
        if activeToolPanel == .screenshot || activeToolPanel == .recording {
            activeToolPanel = nil
        }
    }

    func beginAnnotateImage(_ ids: Set<FileItem.ID>? = nil) {
        guard let target = resolvedItems(ids).first(where: \.isImage) else {
            lastError = "Select an image to annotate."
            return
        }
        closeAllTools()
        annotationTarget = target
    }

    func beginEditText(_ ids: Set<FileItem.ID>? = nil) {
        guard textEditorSession == nil else { return }
        let session = TextEditorSession.launch(from: resolvedItems(ids))
        closeAllTools()
        textEditorSession = session
    }

    func annotationDidSave(_ url: URL) {
        annotationTarget = nil
        activePane.selection = [url.path]
        panes.forEach { $0.refresh() }
    }

    /// Hides every docked tool panel and modal tool so only one is visible at a time.
    private func closeAllTools() {
        activeToolPanel = nil
        showCommandPalette = false
        showResizeSheet = false
        showBatchRenameSheet = false
        showConvertSheet = false
        dismissPDFToolSheet()
        showMergeIntoVideoSheet = false
        annotationTarget = nil
        textEditorSession = nil
        showPreviewSlideshow = false
        capturePermissionPrompt = nil
        proToolsPermissionPrompt = nil
    }

    private func closeModalTools() {
        showCommandPalette = false
        showResizeSheet = false
        showBatchRenameSheet = false
        showConvertSheet = false
        dismissPDFToolSheet()
        showMergeIntoVideoSheet = false
        annotationTarget = nil
        textEditorSession = nil
        showPreviewSlideshow = false
    }

    private func presentTool(_ tool: DockedToolPanel) {
        closeModalTools()
        capturePermissionPrompt = nil
        proToolsPermissionPrompt = nil
        activeToolPanel = activeToolPanel == tool ? nil : tool
        if activeToolPanel == .clipboard {
            ClipboardHistoryStore.shared.captureCurrentPasteboard(reportError: false)
            ClipboardHistoryStore.shared.ensureSelection()
        }
    }

    private func beginCaptureTool(_ kind: CaptureKind, togglesExistingPanel: Bool) {
        guard proToolsEnabled else {
            enableProTools()
            return
        }

        let panel = dockedPanel(for: kind)
        UserDefaults.standard.set(kind.rawValue, forKey: "capture.kind")

        if togglesExistingPanel && activeToolPanel == panel {
            activeToolPanel = nil
            return
        }

        let requirementsOnOpen: [CapturePermissionRequirement] = kind == .recording
            ? [.screenRecording]
            : []

        guard !requirementsOnOpen.isEmpty else {
            closeModalTools()
            capturePermissionPrompt = nil
            activeToolPanel = panel
            return
        }

        Task { @MainActor in
            guard await ensureCapturePermissions(
                for: kind,
                required: requirementsOnOpen
            ) else { return }
            closeModalTools()
            capturePermissionPrompt = nil
            activeToolPanel = panel
        }
    }

    @discardableResult
    private func ensureCapturePermissions(
        for kind: CaptureKind,
        required: [CapturePermissionRequirement]? = nil
    ) async -> Bool {
        let required = required ?? requiredCapturePermissions(for: kind)

        permissionsManager.refresh()
        var missing = missingCapturePermissions(from: required)

        if missing.contains(.screenRecording) {
            permissionsManager.requestScreenRecording()
        }
        if missing.contains(.microphone) {
            await permissionsManager.requestMicrophone()
        }

        permissionsManager.refresh()
        missing = missingCapturePermissions(from: required)

        guard missing.isEmpty else {
            activeToolPanel = nil
            closeModalTools()
            capturePermissionPrompt = CapturePermissionPrompt(
                kind: kind,
                required: required,
                missing: missing
            )
            return false
        }

        capturePermissionPrompt = nil
        return true
    }

    func retryCapturePermissions() {
        guard let prompt = capturePermissionPrompt else { return }
        let kind = prompt.kind
        let required = prompt.required
        Task { @MainActor in
            guard await ensureCapturePermissions(for: kind, required: required) else { return }
            closeModalTools()
            activeToolPanel = dockedPanel(for: kind)
        }
    }

    func openCapturePermissionSettings(_ requirement: CapturePermissionRequirement) {
        switch requirement {
        case .screenRecording:
            permissionsManager.openScreenRecordingSettings()
        case .microphone:
            permissionsManager.openMicrophoneSettings()
        }
    }

    func dismissCapturePermissionPrompt() {
        capturePermissionPrompt = nil
    }

    func enableProTools() {
        guard !proToolsEnabled, !isEnablingProTools else { return }

        closeModalTools()
        capturePermissionPrompt = nil
        proToolsPermissionPrompt = nil
        isEnablingProTools = true

        Task { @MainActor [weak self] in
            guard let self else { return }

            permissionsManager.refresh()
            var missing = ProToolsAccessPolicy.missingPermissions(
                screenRecording: permissionsManager.screenRecording,
                microphone: permissionsManager.microphone
            )

            if missing.contains(.screenRecording) {
                permissionsManager.requestScreenRecording()
            }
            if missing.contains(.microphone) {
                await permissionsManager.requestMicrophone()
            }

            permissionsManager.refresh()
            missing = ProToolsAccessPolicy.missingPermissions(
                screenRecording: permissionsManager.screenRecording,
                microphone: permissionsManager.microphone
            )
            isEnablingProTools = false

            if missing.isEmpty {
                proToolsEnabled = true
            } else {
                proToolsPermissionPrompt = ProToolsPermissionPrompt(missing: missing)
            }
        }
    }

    func retryProToolsPermissions() {
        enableProTools()
    }

    func dismissProToolsPermissionPrompt() {
        proToolsPermissionPrompt = nil
    }

    private func missingCapturePermissions(for kind: CaptureKind) -> [CapturePermissionRequirement] {
        missingCapturePermissions(from: requiredCapturePermissions(for: kind))
    }

    private func missingCapturePermissions(
        from required: [CapturePermissionRequirement]
    ) -> [CapturePermissionRequirement] {
        required.filter { requirement in
            switch requirement {
            case .screenRecording:
                permissionsManager.screenRecording != .granted
            case .microphone:
                permissionsManager.microphone != .granted
            }
        }
    }

    private func requiredCapturePermissions(for kind: CaptureKind) -> [CapturePermissionRequirement] {
        switch kind {
        case .screenshot:
            [.screenRecording]
        case .recording:
            [.screenRecording, .microphone]
        }
    }

    private func requiredCapturePermissions(for options: ScreenshotOptions) -> [CapturePermissionRequirement] {
        switch options.kind {
        case .screenshot:
            [.screenRecording]
        case .recording:
            options.includeMicrophone ? [.screenRecording, .microphone] : [.screenRecording]
        }
    }

    private func dockedPanel(for kind: CaptureKind) -> DockedToolPanel {
        switch kind {
        case .screenshot: .screenshot
        case .recording: .recording
        }
    }

    func dismissToolPanel() {
        activeToolPanel = nil
    }

    func togglePreview() {
        presentTool(.preview)
    }

    func showNotes() {
        presentTool(.notes)
    }

    func hideNotes() {
        if activeToolPanel == .notes { activeToolPanel = nil }
    }

    func showCalendarTool() {
        presentTool(.calendar)
    }

    func hideCalendarTool() {
        if activeToolPanel == .calendar { activeToolPanel = nil }
    }

    func showCalculatorTool() {
        presentTool(.calculator)
    }

    func hideCalculatorTool() {
        if activeToolPanel == .calculator { activeToolPanel = nil }
    }

    func showTerminalTool() {
        presentTool(.terminal)
    }

    func hideTerminalTool() {
        if activeToolPanel == .terminal { activeToolPanel = nil }
    }

    func showSnippets() {
        presentTool(.snippets)
    }

    private func openSnippets() {
        closeModalTools()
        capturePermissionPrompt = nil
        activeToolPanel = .snippets
    }

    func createSnippetFromSelection(_ ids: Set<FileItem.ID>? = nil) {
        let urls = resolvedItems(ids)
            .filter { !$0.isDirectory }
            .map(\.url)
        guard !urls.isEmpty else {
            lastError = "Select one or more files to create a snippet."
            return
        }
        openSnippets()
        SnippetStore.shared.createSnippet(withFiles: urls)
    }

    func hideSnippets() {
        if activeToolPanel == .snippets { activeToolPanel = nil }
    }

    func showClipboardHistory() {
        presentTool(.clipboard)
    }

    func hideClipboardHistory() {
        if activeToolPanel == .clipboard { activeToolPanel = nil }
    }

    func openCommandPalette() {
        closeModalTools()
        capturePermissionPrompt = nil
        showCommandPalette = true
    }

    func hideCommandPalette() {
        showCommandPalette = false
    }

    func showDropStack() {
        presentTool(.dropStack)
    }

    func hideDropStack() {
        if activeToolPanel == .dropStack { activeToolPanel = nil }
    }

    func showSavedWorkflows() {
        SavedWorkflowStore.shared.ensureSelection()
        presentTool(.workflows)
    }

    func hideSavedWorkflows() {
        if activeToolPanel == .workflows { activeToolPanel = nil }
    }

    func showAdvancedSearch() {
        presentTool(.advancedSearch)
    }

    func hideAdvancedSearch() {
        if activeToolPanel == .advancedSearch { activeToolPanel = nil }
    }

    func publishAdvancedSearchResultsToActivePane() {
        let store = AdvancedSearchStore.shared
        let items = store.resultItems
        guard !items.isEmpty else {
            lastError = "Run an advanced search first."
            return
        }
        let title = "Search: \(store.options.query.isEmpty ? "Filters" : store.options.query)"
        activePane.showAdvancedSearchResults(items, title: title)
    }

    func openSelection() {
        openItems(activePane.selection, in: activePaneIndex)
    }

    func openItems(_ ids: Set<FileItem.ID>, in paneIndex: Int? = nil) {
        let targetPaneIndex = paneIndex ?? activePaneIndex
        guard panes.indices.contains(targetPaneIndex) else { return }

        activePaneIndex = targetPaneIndex
        let pane = panes[targetPaneIndex]
        let items = pane.resolvedItems(ids)
        if items.count == 1, let item = items.first, item.isArchive {
            pane.selection = [item.id]
            ArchiveBrowserStore.shared.open(item)
            presentTool(.archiveBrowser)
            return
        }

        pane.open(ids)
    }

    func browseArchive(_ ids: Set<FileItem.ID>? = nil) {
        guard let archive = resolvedDisplayItems(ids).first(where: \.isArchive) else {
            lastError = "Select an archive to browse."
            return
        }
        ArchiveBrowserStore.shared.open(archive)
        presentTool(.archiveBrowser)
    }

    func showArchiveBrowser() {
        if let archive = activePane.selectedItems.first(where: \.isArchive) {
            ArchiveBrowserStore.shared.open(archive)
        }
        presentTool(.archiveBrowser)
    }

    func hideArchiveBrowser() {
        if activeToolPanel == .archiveBrowser { activeToolPanel = nil }
    }

    func showCleanupTool() {
        presentTool(.cleanup)
    }

    func hideCleanupTool() {
        if activeToolPanel == .cleanup { activeToolPanel = nil }
    }

    func showDiskSpaceAnalyzer() {
        presentTool(.diskSpace)
    }

    func hideDiskSpaceAnalyzer() {
        if activeToolPanel == .diskSpace { activeToolPanel = nil }
    }

    func showOrganizeTool() {
        presentTool(.organize)
    }

    func organizeFolder(at folder: URL) {
        activePane.navigate(to: folder)
        FolderOrganizerStore.shared.targetScope = .activeFolder
        FolderOrganizerStore.shared.clearPlan()
        presentTool(.organize)
    }

    func cleanUpFolder(at folder: URL) {
        activePane.navigate(to: folder)
        CleanupStore.shared.scanScope = .activeFolder
        presentTool(.cleanup)
        CleanupStore.shared.startScan(activeFolder: folder)
    }

    func hideOrganizeTool() {
        if activeToolPanel == .organize { activeToolPanel = nil }
    }

    func showVoiceRecorderTool() {
        guard proToolsEnabled else {
            enableProTools()
            return
        }
        presentTool(.voiceRecorder)
    }

    func hideVoiceRecorderTool() {
        if activeToolPanel == .voiceRecorder { activeToolPanel = nil }
    }

    func showPomodoroTool() {
        presentTool(.pomodoro)
    }

    func hidePomodoroTool() {
        if activeToolPanel == .pomodoro { activeToolPanel = nil }
    }

    func applyOrganizePlan(
        _ items: [OrganizePlanItem],
        onSuccess: @escaping () -> Void = {}
    ) {
        guard !items.isEmpty else { return }
        FolderOrganizerStore.shared.isApplying = true
        let activityID = addActivity(
            title: "Organize Folder",
            detail: "\(items.count) files",
            supportsConflictPolicy: true
        )
        let task = Task {
            updateActivity(activityID) { activity in
                activity.status = .running
                activity.bytesTotal = 1_000
            }
            do {
                let policy = fileActivities.first(where: { $0.id == activityID })?
                    .conflictPolicy ?? fileOperationConflictPolicy
                let records = try await FolderOrganizerEngine.apply(items, conflictPolicy: policy)
                let undo = FileUndoAction.moveBack(title: "Organize Folder", records: records)
                if !records.isEmpty {
                    undoStack.append(undo)
                }
                updateActivity(activityID) { activity in
                    activity.status = .completed
                    activity.finishedAt = Date()
                    activity.bytesCompleted = activity.bytesTotal
                    activity.undoAction = records.isEmpty ? nil : undo
                    activity.revealURLs = records.map(\.destination)
                }
                FolderOrganizerStore.shared.isApplying = false
                onSuccess()
            } catch is CancellationError {
                updateActivity(activityID) { activity in
                    activity.status = .cancelled
                    activity.finishedAt = Date()
                }
                FolderOrganizerStore.shared.isApplying = false
            } catch {
                updateActivity(activityID) { activity in
                    activity.status = .failed(error.localizedDescription)
                    activity.finishedAt = Date()
                }
                lastError = error.localizedDescription
                FolderOrganizerStore.shared.isApplying = false
            }
            activityTasks[activityID] = nil
            panes.forEach { $0.refresh() }
        }
        activityTasks[activityID] = task
    }

    func trashCleanupSuggestions(
        _ suggestions: [CleanupSuggestion],
        onSuccess: @escaping () -> Void = {}
    ) {
        let urls = suggestions.map(\.url)
        guard !urls.isEmpty else { return }
        let activityID = addActivity(title: "Move to Trash", detail: operationDetail(for: urls))
        let task = Task {
            updateActivity(activityID) { activity in
                activity.status = .running
            }
            do {
                let records = try await FileOperations.trash(urls)
                let undo = FileUndoAction.putBack(title: "Move to Trash", records: records)
                if !records.isEmpty {
                    undoStack.append(undo)
                }
                updateActivity(activityID) { activity in
                    activity.status = .completed
                    activity.finishedAt = Date()
                    activity.bytesCompleted = activity.bytesTotal
                    activity.undoAction = records.isEmpty ? nil : undo
                    activity.revealURLs = records.map(\.trashedURL)
                }
                onSuccess()
            } catch is CancellationError {
                updateActivity(activityID) { activity in
                    activity.status = .cancelled
                    activity.finishedAt = Date()
                }
            } catch {
                updateActivity(activityID) { activity in
                    activity.status = .failed(error.localizedDescription)
                    activity.finishedAt = Date()
                }
                lastError = error.localizedDescription
            }
            activityTasks[activityID] = nil
            panes.forEach { $0.refresh() }
        }
        activityTasks[activityID] = task
    }

    func performScreenshot(options: ScreenshotOptions) {
        Task { @MainActor in
            guard await ensureCapturePermissions(
                for: options.kind,
                required: requiredCapturePermissions(for: options)
            ) else { return }
            startScreenshotActivity(options: options)
        }
    }

    private func startScreenshotActivity(options: ScreenshotOptions) {
        let destinationFolder = activePane.currentURL
        let activityTitle = options.kind == .recording ? "Screen Recording" : "Screenshot"
        let activityDetail = options.selectedWindowTitle ?? options.mode.title
        let activityID = addActivity(title: activityTitle, detail: activityDetail)
        let task = Task {
            updateActivity(activityID) { activity in
                activity.status = .running
                if options.delay > 0 {
                    activity.progressDetail = "\(options.delay)s delay"
                } else if options.kind == .recording && options.recordingDuration > 0 {
                    activity.progressDetail = "\(options.recordingDuration)s recording"
                } else if options.mode == .interactive || options.mode == .selection || options.mode == .window {
                    activity.progressDetail = "Waiting for selection"
                } else if options.kind == .recording {
                    activity.progressDetail = "Recording"
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(250))
                let windowNumber = ScreenshotCapture.keyWindowNumber()
                let result = try await ScreenshotCapture.capture(
                    options: options,
                    destinationFolder: destinationFolder,
                    appWindowNumber: windowNumber
                )
                if let savedURL = result.savedURL {
                    activePane.selection = [savedURL.path]
                    activePane.refresh()
                }
                updateActivity(activityID) { activity in
                    activity.status = .completed
                    activity.finishedAt = Date()
                    activity.bytesCompleted = activity.bytesTotal
                    activity.detail = result.savedURL?.lastPathComponent ?? "Copied to clipboard"
                    activity.progressDetail = options.copyToClipboard ? "Copied to clipboard" : nil
                }
            } catch is CancellationError {
                updateActivity(activityID) { activity in
                    activity.status = .cancelled
                    activity.finishedAt = Date()
                }
            } catch {
                updateActivity(activityID) { activity in
                    activity.status = .failed(error.localizedDescription)
                    activity.finishedAt = Date()
                }
                lastError = error.localizedDescription
            }
            activityTasks[activityID] = nil
            pausedActivityIDs.remove(activityID)
        }
        activityTasks[activityID] = task
    }

    func beginRenameSelection() {
        guard let item = activePane.selectedItems.first else { return }
        beginRename(item, in: activePaneIndex)
    }

    /// Starts keyboard-initiated rename after the Return key event has finished.
    /// Creating and focusing the inline editor during that same event can deliver
    /// the originating Return to the new field, which immediately commits it.
    @discardableResult
    func beginRenameSelectionAfterCurrentEvent(in paneIndex: Int) -> Bool {
        guard renameTarget == nil,
              panes.indices.contains(paneIndex),
              let item = panes[paneIndex].selectedItems.first else { return false }

        activePaneIndex = paneIndex
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.renameTarget == nil,
                  self.panes.indices.contains(paneIndex),
                  self.panes[paneIndex].selection.contains(item.id) else { return }
            self.beginRename(item, in: paneIndex)
        }
        return true
    }

    func beginRename(_ item: FileItem, in paneIndex: Int) {
        guard panes.indices.contains(paneIndex) else { return }
        activePaneIndex = paneIndex
        panes[paneIndex].selection = [item.id]
        renamePaneIndex = paneIndex
        renameTarget = item
    }

    func isRenaming(_ item: FileItem, in paneIndex: Int) -> Bool {
        renamePaneIndex == paneIndex && renameTarget?.id == item.id
    }

    func cancelRename() {
        renameTarget = nil
        renamePaneIndex = nil
    }

    func commitRename(_ item: FileItem, in paneIndex: Int, to newName: String) {
        guard isRenaming(item, in: paneIndex) else { return }
        cancelRename()
        rename(item, to: newName, in: paneIndex)
    }

    func beginBatchRename(_ ids: Set<FileItem.ID>? = nil) {
        let targets = resolvedDisplayItems(ids)
        guard !targets.isEmpty else {
            lastError = "Select one or more files to rename."
            return
        }
        batchRenameTargets = targets
        closeAllTools()
        showBatchRenameSheet = true
    }

    func performBatchRename(options: BatchRenameOptions) {
        let targets = batchRenameTargets
        guard !targets.isEmpty else { return }
        runTracked(title: "Batch Rename", detail: operationDetail(for: targets.map(\.url))) {
            let records = try await BatchRenameEngine.rename(targets, options: options)
            return records.isEmpty ? nil : .moveBack(title: "Batch Rename", records: records)
        }
    }

    func rename(_ item: FileItem, to newName: String, in paneIndex: Int? = nil) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        let targetPane = paneIndex.flatMap { panes.indices.contains($0) ? panes[$0] : nil }
        runTrackedResult(title: "Rename", detail: item.name) {
            let record = try await FileOperations.rename(item.url, to: trimmed)
            if targetPane?.currentURL.standardizedFileURL
                == item.url.deletingLastPathComponent().standardizedFileURL {
                targetPane?.selection = [record.destination.path]
            }
            return .undo(
                .moveBack(title: "Rename", records: [record]),
                reveal: [record.destination]
            )
        }
    }

    func createFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let destination = activePane.currentURL
        let targetPane = activePane
        runTrackedResult(title: "New Folder", detail: trimmed) {
            let createdFolder = try await FileOperations.newFolder(named: trimmed, in: destination)
            guard targetPane.currentURL.standardizedFileURL == destination.standardizedFileURL else {
                return .reveal([createdFolder])
            }
            targetPane.selection = [createdFolder.path]
            return .reveal([createdFolder])
        }
    }

    func beginMoveSelectionIntoNewFolder(_ ids: Set<FileItem.ID>? = nil) {
        let urls = resolvedURLs(ids)
        guard !urls.isEmpty else {
            lastError = "Select one or more items to move."
            return
        }
        moveIntoNewFolderURLs = urls
        moveIntoNewFolderParentURL = activePane.currentURL
        showMoveIntoNewFolderPrompt = true
    }

    func moveSelectionIntoNewFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let parentURL = moveIntoNewFolderParentURL,
              !moveIntoNewFolderURLs.isEmpty else {
            cancelMoveIntoNewFolder()
            return
        }

        let urls = moveIntoNewFolderURLs
        cancelMoveIntoNewFolder()

        runTrackedResult(
            title: "Move to New Folder",
            detail: "\(operationDetail(for: urls)) to \(trimmed)"
        ) {
            let result = try await FileOperations.moveIntoNewFolder(
                urls,
                folderName: trimmed,
                in: parentURL
            )
            let undo = result.records.isEmpty
                ? nil
                : FileUndoAction.moveBack(title: "Move to New Folder", records: result.records)
            return FileActivityResult(undoAction: undo, revealURLs: [result.folder])
        }
    }

    func cancelMoveIntoNewFolder() {
        showMoveIntoNewFolderPrompt = false
        moveIntoNewFolderURLs = []
        moveIntoNewFolderParentURL = nil
    }

    func createTextFile(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Default to a .txt extension when the user doesn't type one.
        let fileName = trimmed.contains(".") ? trimmed : "\(trimmed).txt"
        let destination = activePane.currentURL
        let targetPane = activePane
        runTrackedResult(title: "New Text File", detail: fileName) {
            let createdFile = try await FileOperations.newTextFile(named: fileName, in: destination)
            guard targetPane.currentURL.standardizedFileURL == destination.standardizedFileURL else {
                return .reveal([createdFile])
            }
            targetPane.selection = [createdFile.path]
            return .reveal([createdFile])
        }
    }

    /// Opens Terminal at the given folder (defaults to the active pane's folder).
    func openTerminal(at url: URL? = nil) {
        let folder = url ?? activePane.currentURL
        let workspace = NSWorkspace.shared
        guard let terminal = workspace.urlForApplication(
            withBundleIdentifier: "com.apple.Terminal"
        ) else {
            lastError = "Terminal could not be found on this Mac."
            return
        }
        workspace.open(
            [folder],
            withApplicationAt: terminal,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            if let error {
                Task { @MainActor in self?.lastError = error.localizedDescription }
            }
        }
    }

    func duplicateSelection(_ ids: Set<FileItem.ID>? = nil) {
        let urls = resolvedURLs(ids)
        guard !urls.isEmpty else { return }
        runTrackedResult(title: "Duplicate", detail: operationDetail(for: urls)) {
            let copies = try await FileOperations.duplicate(urls)
            return .reveal(copies)
        }
    }

    func compressSelectionToZip(_ ids: Set<FileItem.ID>? = nil) {
        let items = resolvedDisplayItems(ids)
        guard !items.isEmpty else {
            lastError = "Select one or more items to compress."
            return
        }

        let urls = items.map(\.url)
        runTrackedResult(title: "Compress to ZIP", detail: operationDetail(for: urls)) {
            let archive = try await FileOperations.compressToZip(urls)
            return .reveal([archive])
        }
    }

    func extractArchive(_ ids: Set<FileItem.ID>? = nil) {
        guard let archive = resolvedDisplayItems(ids).first(where: \.isArchive) else {
            lastError = "Select an archive to extract."
            return
        }
        runTrackedResult(title: "Extract Archive", detail: archive.name) {
            let output = try await ArchiveTools.extract(at: archive.url)
            return .reveal([output])
        }
    }

    func showArchiveContents(_ ids: Set<FileItem.ID>? = nil) {
        guard let archive = resolvedDisplayItems(ids).first(where: \.isZipArchive) else {
            lastError = "Select a ZIP archive to view its contents."
            return
        }
        activePane.selection = [archive.id]
        closeModalTools()
        capturePermissionPrompt = nil
        activeToolPanel = .preview
    }

    func copyArchiveFileList(_ ids: Set<FileItem.ID>? = nil) {
        guard let archive = resolvedDisplayItems(ids).first(where: \.isArchive) else {
            lastError = "Select an archive to copy its file list."
            return
        }

        Task {
            do {
                let paths = try await ArchiveTools.entries(in: archive.url).joined(separator: "\n")
                ClipboardHistoryStore.shared.copyText(paths)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func extractArchiveBrowserSelection() {
        let store = ArchiveBrowserStore.shared
        guard let archiveURL = store.archiveURL else {
            lastError = "Open an archive first."
            return
        }

        if store.isZipArchive {
            let paths = store.selectedFilePathsForZipExtraction
            guard !paths.isEmpty else {
                lastError = "Select a file or folder inside the ZIP archive to extract."
                return
            }
            runTrackedResult(
                title: "Extract Archive Items",
                detail: "\(paths.count) item\(paths.count == 1 ? "" : "s")"
            ) {
                var outputs: [URL] = []
                for path in paths {
                    outputs.append(try await FileOperations.extractZipEntry(archiveURL, entryPath: path))
                }
                return .reveal(outputs)
            }
        } else {
            runTrackedResult(
                title: "Extract Archive",
                detail: archiveURL.lastPathComponent
            ) {
                let output = try await ArchiveTools.extract(at: archiveURL)
                return .reveal([output])
            }
        }
    }

    func trashSelection(_ ids: Set<FileItem.ID>? = nil) {
        let urls = resolvedURLs(ids)
        guard !urls.isEmpty else { return }
        runTracked(title: "Move to Trash", detail: operationDetail(for: urls)) {
            let records = try await FileOperations.trash(urls)
            return records.isEmpty ? nil : .putBack(title: "Move to Trash", records: records)
        }
    }

    /// F5 (copy) / F6 (move): send the active pane's selection to the other pane.
    func transferSelection(_ ids: Set<FileItem.ID>? = nil, move: Bool) {
        guard isDualPane else { return }
        let urls = resolvedURLs(ids)
        let destination = inactivePane.currentURL
        guard !urls.isEmpty else { return }
        enqueueTransfer(urls, to: destination, move: move)
    }

    func moveSelectionToParentFolder(_ ids: Set<FileItem.ID>? = nil) {
        let urls = resolvedDisplayItems(ids).map(\.url)
        guard !urls.isEmpty else {
            lastError = "Select one or more files or folders to move."
            return
        }

        runTrackedResult(title: "Move to Parent Folder", detail: operationDetail(for: urls)) {
            let records = try await FileOperations.moveToParentFolder(urls)
            let undo = FileUndoAction.moveBack(title: "Move to Parent Folder", records: records)
            return .undo(undo, reveal: records.map(\.destination))
        }
    }

    func fileDragProvider(for item: FileItem, paneIndex: Int) -> NSItemProvider {
        activePaneIndex = paneIndex
        let pane = panes[paneIndex]
        let dragURLs: [URL]
        if pane.selection.contains(item.id) {
            let visibleSelectedURLs = pane.displayItems
                .filter { pane.selection.contains($0.id) }
                .map(\.url)
            dragURLs = visibleSelectedURLs.isEmpty ? [item.url] : visibleSelectedURLs
        } else {
            dragURLs = [item.url]
        }

        targetedFileDropDestinations.removeAll()
        let sessionID = UUID().uuidString
        currentFileDragSession = FileDragSession(
            id: sessionID,
            urls: dragURLs,
            sourcePaneIndex: paneIndex,
            defaultsToMove: true
        )

        let provider = FileDragItemProvider.make(
            url: item.url,
            suggestedName: item.name,
            sessionID: sessionID,
            internalTypeIdentifier: Self.internalFileDragType.identifier
        )
        DragDropLog.log(
            "DRAG START name=\(item.name) ext=\(item.url.pathExtension) "
                + "urls=\(dragURLs.count) types=\(provider.registeredTypeIdentifiers)"
        )
        return provider
    }

    func dropStackDragProvider(for item: DropStackItem) -> NSItemProvider {
        let store = DropStackStore.shared
        let itemURL = item.url
        let dragURLs: [URL]
        if store.selection.contains(item.id) {
            dragURLs = store.selectedURLs
        } else if FileManager.default.fileExists(atPath: item.path) {
            dragURLs = [itemURL]
        } else {
            dragURLs = []
        }

        guard let firstURL = dragURLs.first else {
            return NSItemProvider(object: item.name as NSString)
        }

        targetedFileDropDestinations.removeAll()
        let sessionID = UUID().uuidString
        currentFileDragSession = FileDragSession(
            id: sessionID,
            urls: dragURLs,
            sourcePaneIndex: activePaneIndex,
            defaultsToMove: false
        )

        return FileDragItemProvider.make(
            url: firstURL,
            suggestedName: dragURLs.count == 1
                ? firstURL.lastPathComponent
                : "\(dragURLs.count) items",
            sessionID: sessionID,
            internalTypeIdentifier: Self.internalFileDragType.identifier
        )
    }

    func dropCurrentFileDrag(to destination: URL, paneIndex: Int) -> Bool {
        guard let session = currentFileDragSession else { return false }
        let accepted = performDrop(
            session.urls,
            to: destination,
            paneIndex: paneIndex,
            isInternalDrag: session.defaultsToMove
        )
        if accepted, currentFileDragSession?.id == session.id {
            currentFileDragSession = nil
        }
        return accepted
    }

    func consumeCurrentFileDragURLs() -> [URL] {
        guard let session = currentFileDragSession else { return [] }
        currentFileDragSession = nil
        return session.urls
    }

    func drop(_ urls: [URL], to destination: URL, paneIndex: Int) -> Bool {
        let expandedSession = expandedCurrentDragSession(matching: urls)
        let accepted = performDrop(
            expandedSession?.urls ?? urls,
            to: destination,
            paneIndex: paneIndex,
            isInternalDrag: expandedSession?.defaultsToMove == true
        )
        if accepted,
           let expandedSession,
           currentFileDragSession?.id == expandedSession.id {
            currentFileDragSession = nil
        }
        return accepted
    }

    private func performDrop(
        _ sourceURLs: [URL],
        to destination: URL,
        paneIndex: Int,
        isInternalDrag: Bool
    ) -> Bool {
        activePaneIndex = paneIndex
        let filtered = sourceURLs.filter { $0.standardizedFileURL != destination.standardizedFileURL }
        guard !filtered.isEmpty else {
            DragDropLog.log("PERFORM_DROP reject=allSourcesEqualDestination dest=\(destination.path)")
            return false
        }
        let move = FileDropOperationPolicy.shouldMove(
            isInternalDrag: isInternalDrag,
            modifiers: NSEvent.modifierFlags
        )
        let transferable = filtered.filter { source in
            !move || source.deletingLastPathComponent().standardizedFileURL
                != destination.standardizedFileURL
        }
        guard !transferable.isEmpty else {
            DragDropLog.log(
                "PERFORM_DROP reject=alreadyInDestination move=\(move) dest=\(destination.path)"
            )
            return false
        }
        DragDropLog.log(
            "PERFORM_DROP accept move=\(move) internal=\(isInternalDrag) "
                + "count=\(transferable.count) dest=\(destination.path)"
        )
        enqueueTransfer(transferable, to: destination, move: move)
        return true
    }

    func updateFileDropTarget(id: UUID, destination: URL, isTargeted: Bool) {
        if isTargeted {
            targetedFileDropDestinations[id] = destination.standardizedFileURL
        } else {
            targetedFileDropDestinations[id] = nil
        }
    }

    func preferredFileDropDestination(fallback: URL) -> URL {
        FileDropDestinationPolicy.preferredDestination(
            fallback: fallback,
            activeDestinations: Array(targetedFileDropDestinations.values)
        )
    }

    func beginResize(_ ids: Set<FileItem.ID>? = nil) {
        let images = resolvedItems(ids).filter(\.isImage)
        guard !images.isEmpty else {
            lastError = "Select one or more images to resize."
            return
        }
        resizeTargets = images
        closeAllTools()
        showResizeSheet = true
    }

    func performResize(options: ImageProcessing.Options) {
        let targets = resizeTargets
        run {
            for target in targets {
                try await ImageProcessing.resize(target.url, options: options)
            }
        }
    }

    func optimizeImages(_ ids: Set<FileItem.ID>? = nil) {
        let urls = resolvedItems(ids).filter(\.isImage).map(\.url)
        guard !urls.isEmpty else {
            lastError = "Select one or more images to optimize."
            return
        }
        run {
            for url in urls {
                try await ImageProcessing.optimize(url)
            }
        }
    }

    func grayscaleImages(_ ids: Set<FileItem.ID>? = nil) {
        let urls = resolvedItems(ids).filter(\.isImage).map(\.url)
        guard !urls.isEmpty else {
            lastError = "Select one or more images to convert to grayscale."
            return
        }
        run {
            for url in urls {
                try await ImageProcessing.grayscale(url)
            }
        }
    }

    func createImageThumbnails(_ ids: Set<FileItem.ID>? = nil) {
        let urls = resolvedItems(ids).filter(\.isImage).map(\.url)
        guard !urls.isEmpty else {
            lastError = "Select one or more images to create thumbnails."
            return
        }
        run {
            for url in urls {
                try await ImageProcessing.createThumbnail(url)
            }
        }
    }

    func beginConvert(_ ids: Set<FileItem.ID>? = nil) {
        let targets = resolvedDisplayItems(ids).filter(MediaConverter.canConvert)
        guard !targets.isEmpty else {
            lastError = "Select one or more images or videos to convert."
            return
        }
        convertTargets = targets
        closeAllTools()
        showConvertSheet = true
    }

    func performConvert(options: MediaConversionOptions) {
        let targets = convertTargets
        guard !targets.isEmpty else { return }
        let total = targets.count
        let activityID = addActivity(title: "Convert", detail: operationDetail(for: targets.map(\.url)))
        let task = Task {
            updateActivity(activityID) { activity in
                activity.status = .running
                activity.bytesTotal = 1_000
                activity.progressDetail = "0 of \(total) files"
            }
            var completed = 0
            var failures: [String] = []
            for target in targets {
                do {
                    try Task.checkCancellation()
                    updateActivity(activityID) { activity in
                        activity.detail = target.name
                    }
                    _ = try await MediaConverter.convert(target, options: options) { [weak self] fileProgress in
                        guard let self else { return }
                        await MainActor.run {
                            self.updateActivity(activityID) { activity in
                                let totalProgress = (Double(completed) + fileProgress) / Double(total)
                                activity.bytesCompleted = Int64((totalProgress * 1_000).rounded())
                                activity.progressDetail = "\(completed) of \(total) files"
                            }
                        }
                    }
                } catch is CancellationError {
                    updateActivity(activityID) { activity in
                        activity.status = .cancelled
                        activity.finishedAt = Date()
                    }
                    activityTasks[activityID] = nil
                    pausedActivityIDs.remove(activityID)
                    panes.forEach { $0.refresh() }
                    return
                } catch {
                    failures.append("\(target.name): \(error.localizedDescription)")
                }
                completed += 1
                updateActivity(activityID) { activity in
                    let totalProgress = Double(completed) / Double(total)
                    activity.bytesCompleted = Int64((totalProgress * 1_000).rounded())
                    activity.progressDetail = "\(completed) of \(total) files"
                }
            }

            if failures.isEmpty {
                updateActivity(activityID) { activity in
                    activity.status = .completed
                    activity.finishedAt = Date()
                    activity.bytesCompleted = activity.bytesTotal
                    activity.detail = operationDetail(for: targets.map(\.url))
                }
            } else {
                updateActivity(activityID) { activity in
                    activity.status = .failed("\(failures.count) conversion\(failures.count == 1 ? "" : "s") failed")
                    activity.finishedAt = Date()
                    activity.detail = "\(completed - failures.count) completed, \(failures.count) failed"
                }
                lastError = failures.prefix(3).joined(separator: "\n")
            }
            activityTasks[activityID] = nil
            pausedActivityIDs.remove(activityID)
            panes.forEach { $0.refresh() }
        }
        activityTasks[activityID] = task
    }

    func showPreviewForSelection(_ ids: Set<FileItem.ID>? = nil) {
        let targets = resolvedDisplayItems(ids).filter(\.isPlayableMedia)
        guard !targets.isEmpty else {
            lastError = "Select one or more audio or video files to preview."
            return
        }
        activePane.selection = Set(targets.map(\.id))
        closeModalTools()
        capturePermissionPrompt = nil
        activeToolPanel = .preview
    }

    func convertAudioToM4A(_ ids: Set<FileItem.ID>? = nil) {
        let targets = resolvedDisplayItems(ids).filter(\.isAudioMedia)
        guard !targets.isEmpty else {
            lastError = "Select one or more audio files to convert."
            return
        }

        let total = targets.count
        let activityID = addActivity(title: "Convert Audio", detail: operationDetail(for: targets.map(\.url)))
        let task = Task {
            updateActivity(activityID) { activity in
                activity.status = .running
                activity.bytesTotal = 1_000
                activity.progressDetail = "0 of \(total) files"
            }

            var completed = 0
            var latestOutput: URL?
            var failures: [String] = []
            for target in targets {
                do {
                    try Task.checkCancellation()
                    updateActivity(activityID) { activity in
                        activity.detail = target.name
                    }
                    let output = try await AudioConverter.convertToM4A(target) { [weak self] progress in
                        guard let self else { return }
                        await MainActor.run {
                            self.updateActivity(activityID) { activity in
                                let totalProgress = (Double(completed) + progress) / Double(total)
                                activity.bytesCompleted = Int64((totalProgress * 1_000).rounded())
                                activity.progressDetail = "\(completed) of \(total) files"
                            }
                        }
                    }
                    latestOutput = output
                } catch is CancellationError {
                    updateActivity(activityID) { activity in
                        activity.status = .cancelled
                        activity.finishedAt = Date()
                    }
                    activityTasks[activityID] = nil
                    pausedActivityIDs.remove(activityID)
                    panes.forEach { $0.refresh() }
                    return
                } catch {
                    failures.append("\(target.name): \(error.localizedDescription)")
                }

                completed += 1
                updateActivity(activityID) { activity in
                    let totalProgress = Double(completed) / Double(total)
                    activity.bytesCompleted = Int64((totalProgress * 1_000).rounded())
                    activity.progressDetail = "\(completed) of \(total) files"
                }
            }

            if failures.isEmpty {
                updateActivity(activityID) { activity in
                    activity.status = .completed
                    activity.finishedAt = Date()
                    activity.bytesCompleted = activity.bytesTotal
                    activity.detail = latestOutput?.lastPathComponent ?? "Converted audio"
                    activity.progressDetail = nil
                }
                if let latestOutput {
                    activePane.selection = [latestOutput.path]
                }
            } else {
                updateActivity(activityID) { activity in
                    activity.status = .failed("\(failures.count) audio conversion\(failures.count == 1 ? "" : "s") failed")
                    activity.finishedAt = Date()
                    activity.detail = "\(completed - failures.count) completed, \(failures.count) failed"
                }
                lastError = failures.prefix(3).joined(separator: "\n")
            }
            activityTasks[activityID] = nil
            pausedActivityIDs.remove(activityID)
            panes.forEach { $0.refresh() }
        }
        activityTasks[activityID] = task
    }

    func convertDocumentToPDF(_ ids: Set<FileItem.ID>? = nil) {
        let documents = resolvedDisplayItems(ids).filter(DocumentPDFConverter.canConvert)
        guard let document = documents.first else {
            lastError = "Select a supported document to convert to PDF."
            return
        }

        let activityID = addActivity(title: "Convert to PDF", detail: document.name)
        let task = Task {
            updateActivity(activityID) { activity in
                activity.status = .running
                activity.bytesTotal = 1_000
                activity.progressDetail = "Preparing document"
            }
            do {
                let output = try await DocumentPDFConverter.convert(document)
                updateActivity(activityID) { activity in
                    activity.status = .completed
                    activity.finishedAt = Date()
                    activity.bytesCompleted = activity.bytesTotal
                    activity.detail = output.lastPathComponent
                    activity.progressDetail = nil
                    activity.revealURLs = [output]
                }
                activePane.selection = [output.path]
            } catch is CancellationError {
                updateActivity(activityID) { activity in
                    activity.status = .cancelled
                    activity.finishedAt = Date()
                }
            } catch {
                updateActivity(activityID) { activity in
                    activity.status = .failed(error.localizedDescription)
                    activity.finishedAt = Date()
                }
                lastError = error.localizedDescription
            }
            activityTasks[activityID] = nil
            pausedActivityIDs.remove(activityID)
            panes.forEach { $0.refresh() }
        }
        activityTasks[activityID] = task
    }

    func openDocumentsInPages(_ ids: Set<FileItem.ID>? = nil) {
        let documents = resolvedDisplayItems(ids).filter(DocumentPDFConverter.canConvert)
        guard !documents.isEmpty else {
            lastError = "Select a supported document to open in Pages."
            return
        }
        guard let pagesURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.iWork.Pages"
        ) else {
            lastError = "Pages is not installed on this Mac."
            return
        }

        NSWorkspace.shared.open(
            documents.map(\.url),
            withApplicationAt: pagesURL,
            configuration: .init(),
            completionHandler: nil
        )
    }

    func copyTextFileContents(_ ids: Set<FileItem.ID>? = nil) {
        guard let textFile = resolvedDisplayItems(ids).first(where: { $0.isText && !$0.isSpreadsheet }) else {
            lastError = "Select a text or code file to copy its contents."
            return
        }

        Task {
            do {
                ClipboardHistoryStore.shared.copyText(try await TextFileTools.readText(at: textFile.url))
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func extractTextFromImages(_ ids: Set<FileItem.ID>? = nil) {
        let images = resolvedDisplayItems(ids).filter(\.isImage)
        guard !images.isEmpty else {
            lastError = "Select one or more images to extract text."
            return
        }

        runTrackedResult(title: "Extract Text", detail: operationDetail(for: images.map(\.url))) {
            let result = try await ImageTextExtractor.extractTextFiles(from: images)
            ClipboardHistoryStore.shared.copyText(result.clipboardText)
            let completionDetail = result.outputURLs.count == 1
                ? "Saved \(result.outputURLs[0].lastPathComponent) and copied text to clipboard."
                : "Saved \(result.outputURLs.count) text files and copied text to clipboard."
            return .reveal(result.outputURLs, completionDetail: completionDetail)
        }
    }

    func formatJSON(_ ids: Set<FileItem.ID>? = nil, minify: Bool) {
        guard let json = resolvedDisplayItems(ids).first(where: \.isJSONFile) else {
            lastError = "Select a JSON file to format."
            return
        }
        runTrackedResult(
            title: minify ? "Minify JSON" : "Format JSON",
            detail: json.name
        ) {
            let output = try await (minify
                ? TextFileTools.minifyJSON(at: json.url)
                : TextFileTools.formatJSON(at: json.url))
            return .reveal([output])
        }
    }

    func validateJSON(_ ids: Set<FileItem.ID>? = nil) {
        guard let json = resolvedDisplayItems(ids).first(where: \.isJSONFile) else {
            lastError = "Select a JSON file to validate."
            return
        }
        runTracked(title: "Validate JSON", detail: json.name) {
            try await TextFileTools.validateJSON(at: json.url)
            return nil
        }
    }

    func openSpreadsheetsInNumbers(_ ids: Set<FileItem.ID>? = nil) {
        let spreadsheets = resolvedDisplayItems(ids).filter(\.isSpreadsheet)
        guard !spreadsheets.isEmpty else {
            lastError = "Select one or more spreadsheets to open in Numbers."
            return
        }
        guard let numbersURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.iWork.Numbers"
        ) else {
            lastError = "Numbers is not installed on this Mac."
            return
        }

        NSWorkspace.shared.open(
            spreadsheets.map(\.url),
            withApplicationAt: numbersURL,
            configuration: .init(),
            completionHandler: nil
        )
    }

    func convertDelimitedSpreadsheet(
        _ ids: Set<FileItem.ID>? = nil,
        to destinationFormat: SpreadsheetDelimitedFormat
    ) {
        guard let spreadsheet = resolvedDisplayItems(ids).first(where: \.isDelimitedSpreadsheet) else {
            lastError = "Select a CSV or TSV file to convert."
            return
        }
        runTrackedResult(title: "Convert to \(destinationFormat.title)", detail: spreadsheet.name) {
            let output = try await SpreadsheetTools.convertDelimitedText(
                at: spreadsheet.url,
                to: destinationFormat
            )
            return .reveal([output])
        }
    }

    func copySpreadsheetSummary(_ ids: Set<FileItem.ID>? = nil) {
        guard let spreadsheet = resolvedDisplayItems(ids).first(where: \.isDelimitedSpreadsheet) else {
            lastError = "Select a CSV or TSV file to inspect."
            return
        }

        Task {
            do {
                let summary = try await SpreadsheetTools.summary(at: spreadsheet.url)
                ClipboardHistoryStore.shared.copyText("\(spreadsheet.name)\n\(summary.text)")
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func exportSpreadsheetToCSV(_ ids: Set<FileItem.ID>? = nil) {
        guard let spreadsheet = resolvedDisplayItems(ids).first(where: \.isSpreadsheet) else {
            lastError = "Select a spreadsheet to export to CSV."
            return
        }
        runTrackedResult(title: "Export Spreadsheet", detail: spreadsheet.name) {
            let output = try await SpreadsheetTools.exportToCSVUsingNumbers(at: spreadsheet.url)
            return .reveal([output])
        }
    }

    func launchApplication(_ ids: Set<FileItem.ID>? = nil) {
        guard let application = resolvedDisplayItems(ids).first(where: \.isApplicationBundle) else {
            lastError = "Select an application to launch."
            return
        }
        guard NSWorkspace.shared.open(application.url) else {
            lastError = "Couldn’t launch “\(application.name)”."
            return
        }
    }

    func showApplicationPackageContents(_ ids: Set<FileItem.ID>? = nil) {
        guard let application = resolvedDisplayItems(ids).first(where: \.isApplicationBundle) else {
            lastError = "Select an application to show its package contents."
            return
        }
        closeAllTools()
        activePane.navigate(to: application.url)
    }

    func copyApplicationDetails(_ ids: Set<FileItem.ID>? = nil) {
        guard let application = resolvedDisplayItems(ids).first(where: \.isApplicationBundle),
              let details = ApplicationBundleTools.details(for: application) else {
            lastError = "Select an application to copy its details."
            return
        }
        ClipboardHistoryStore.shared.copyText(details.clipboardText)
    }

    func mountDiskImage(_ ids: Set<FileItem.ID>? = nil) {
        guard let diskImage = resolvedDisplayItems(ids).first(where: \.isDiskImage) else {
            lastError = "Select a disk image to mount."
            return
        }
        runTracked(title: "Mount Disk Image", detail: diskImage.name) {
            try await DiskImageTools.mount(diskImage.url)
            return nil
        }
    }

    func copyDiskImageChecksum(_ ids: Set<FileItem.ID>? = nil) {
        guard let diskImage = resolvedDisplayItems(ids).first(where: \.isDiskImage) else {
            lastError = "Select a disk image to calculate its checksum."
            return
        }
        Task {
            do {
                let checksum = try await DiskImageTools.sha256(diskImage.url)
                ClipboardHistoryStore.shared.copyText("SHA-256 (\(diskImage.name))\n\(checksum)")
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func openInstallerPackage(_ ids: Set<FileItem.ID>? = nil) {
        guard let installer = resolvedDisplayItems(ids).first(where: \.isInstallerPackage) else {
            lastError = "Select an installer package to open."
            return
        }
        guard NSWorkspace.shared.open(installer.url) else {
            lastError = "Couldn’t open “\(installer.name)”."
            return
        }
    }

    func showInstallerPackageContents(_ ids: Set<FileItem.ID>? = nil) {
        guard let installer = resolvedDisplayItems(ids).first(where: {
            $0.isInstallerPackage && $0.isDirectory
        }) else {
            lastError = "This installer package has no browsable contents."
            return
        }
        closeAllTools()
        activePane.navigate(to: installer.url)
    }

    func copyInstallerDetails(_ ids: Set<FileItem.ID>? = nil) {
        guard let installer = resolvedDisplayItems(ids).first(where: \.isInstallerPackage),
              let details = InstallerTools.details(for: installer) else {
            lastError = "Select an installer package to copy its details."
            return
        }
        ClipboardHistoryStore.shared.copyText(details.clipboardText)
    }

    func openPresentationsInKeynote(_ ids: Set<FileItem.ID>? = nil) {
        let presentations = resolvedDisplayItems(ids).filter(\.isPresentation)
        guard !presentations.isEmpty else {
            lastError = "Select one or more presentations to open in Keynote."
            return
        }
        guard let keynoteURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.iWork.Keynote"
        ) else {
            lastError = "Keynote is not installed on this Mac."
            return
        }
        NSWorkspace.shared.open(
            presentations.map(\.url),
            withApplicationAt: keynoteURL,
            configuration: .init(),
            completionHandler: nil
        )
    }

    func exportPresentationToPDF(_ ids: Set<FileItem.ID>? = nil) {
        guard let presentation = resolvedDisplayItems(ids).first(where: \.isPresentation) else {
            lastError = "Select a presentation to export to PDF."
            return
        }
        runTrackedResult(title: "Export Presentation", detail: presentation.name) {
            let output = try await PresentationTools.exportToPDFUsingKeynote(at: presentation.url)
            return .reveal([output])
        }
    }

    func openFontsInFontBook(_ ids: Set<FileItem.ID>? = nil) {
        let fonts = resolvedDisplayItems(ids).filter(\.isFontFile)
        guard !fonts.isEmpty else {
            lastError = "Select one or more font files to open in Font Book."
            return
        }
        guard let fontBookURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.FontBook"
        ) else {
            lastError = "Font Book is not installed on this Mac."
            return
        }
        NSWorkspace.shared.open(
            fonts.map(\.url),
            withApplicationAt: fontBookURL,
            configuration: .init(),
            completionHandler: nil
        )
    }

    func installFonts(_ ids: Set<FileItem.ID>? = nil) {
        let fonts = resolvedDisplayItems(ids).filter(\.isFontFile)
        guard !fonts.isEmpty else {
            lastError = "Select one or more font files to install."
            return
        }
        runTracked(title: "Install Fonts", detail: operationDetail(for: fonts.map(\.url))) {
            for font in fonts {
                try FontTools.install(at: font.url)
            }
            return nil
        }
    }

    func copyFontDetails(_ ids: Set<FileItem.ID>? = nil) {
        let details = resolvedDisplayItems(ids)
            .filter(\.isFontFile)
            .compactMap(FontTools.details)
        guard !details.isEmpty else {
            lastError = "Select a font file to copy its details."
            return
        }
        ClipboardHistoryStore.shared.copyText(details.map(\.clipboardText).joined(separator: "\n\n"))
    }

    func openEBooksInBooks(_ ids: Set<FileItem.ID>? = nil) {
        let books = resolvedDisplayItems(ids).filter(\.isEPUB)
        guard !books.isEmpty else {
            lastError = "Select one or more EPUB books to open in Books."
            return
        }
        guard let booksURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.iBooksX"
        ) else {
            lastError = "Books is not installed on this Mac."
            return
        }
        NSWorkspace.shared.open(
            books.map(\.url),
            withApplicationAt: booksURL,
            configuration: .init(),
            completionHandler: nil
        )
    }

    func copyEBookDetails(_ ids: Set<FileItem.ID>? = nil) {
        guard let book = resolvedDisplayItems(ids).first(where: \.isEPUB) else {
            lastError = "Select an EPUB book to copy its details."
            return
        }
        Task {
            do {
                let details = try await EBookTools.details(at: book.url)
                ClipboardHistoryStore.shared.copyText(details.clipboardText)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func openContactCardsInContacts(_ ids: Set<FileItem.ID>? = nil) {
        let contacts = resolvedDisplayItems(ids).filter(\.isContactCard)
        guard !contacts.isEmpty else {
            lastError = "Select one or more contact cards to open in Contacts."
            return
        }
        guard let contactsURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.AddressBook"
        ) else {
            lastError = "Contacts is not installed on this Mac."
            return
        }
        NSWorkspace.shared.open(
            contacts.map(\.url),
            withApplicationAt: contactsURL,
            configuration: .init(),
            completionHandler: nil
        )
    }

    func copyContactDetails(_ ids: Set<FileItem.ID>? = nil) {
        guard let contact = resolvedDisplayItems(ids).first(where: \.isContactCard) else {
            lastError = "Select a contact card to copy its details."
            return
        }
        Task {
            do {
                let details = try await ContactCardTools.details(at: contact.url)
                ClipboardHistoryStore.shared.copyText(details.clipboardText)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func mergePDFs(_ ids: Set<FileItem.ID>? = nil) {
        let targets = resolvedDisplayItems(ids).filter(PDFTools.isPDF)
        guard targets.count >= 2 else {
            lastError = "Select at least two PDFs to merge."
            return
        }

        let folder = activePane.currentURL
        performPDFOperation(
            title: "Merge PDFs",
            detail: operationDetail(for: targets.map(\.url))
        ) {
            try await PDFTools.merge(targets.map(\.url), toFolder: folder)
        }
    }

    func splitPDF(_ ids: Set<FileItem.ID>? = nil) {
        guard let target = singlePDFTarget(ids) else { return }
        performPDFOperation(title: "Split PDF", detail: target.name) {
            try await PDFTools.split(target.url)
        }
    }

    func rotatePDF(_ degrees: Int, ids: Set<FileItem.ID>? = nil) {
        guard let target = singlePDFTarget(ids) else { return }
        let title = degrees < 0 ? "Rotate PDF Left" : "Rotate PDF Right"
        performPDFOperation(title: title, detail: target.name) {
            try await PDFTools.rotate(target.url, degrees: degrees)
        }
    }

    func exportPDFPagesAsPNGs(_ ids: Set<FileItem.ID>? = nil) {
        guard let target = singlePDFTarget(ids) else { return }
        performPDFOperation(title: "Export PDF Pages", detail: target.name) {
            try await PDFTools.exportPagesAsPNGs(target.url)
        }
    }

    func optimizePDF(_ ids: Set<FileItem.ID>? = nil) {
        guard let target = singlePDFTarget(ids) else { return }
        performPDFOperation(title: "Optimize PDF", detail: target.name) {
            try PDFTools.optimize(target.url)
        }
    }

    func copyPDFDetails(_ ids: Set<FileItem.ID>? = nil) {
        guard let target = singlePDFTarget(ids) else { return }
        do {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(try PDFTools.details(at: target.url), forType: .string)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func beginPDFTool(_ mode: PDFToolSheetMode, ids: Set<FileItem.ID>? = nil) {
        guard let target = singlePDFTarget(ids) else { return }
        do {
            let pageCount: Int
            if mode == .removePassword {
                _ = try PDFTools.details(at: target.url)
                pageCount = 0
            } else {
                pageCount = try PDFTools.pageCount(at: target.url)
            }
            closeAllTools()
            pdfToolTarget = target
            pdfToolMode = mode
            pdfToolPageCount = pageCount
            showPDFToolSheet = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    func dismissPDFToolSheet() {
        showPDFToolSheet = false
        pdfToolTarget = nil
        pdfToolMode = nil
        pdfToolPageCount = 0
    }

    func extractPDFPages(_ range: String) {
        guard let target = pdfToolTarget else {
            dismissPDFToolSheet()
            return
        }
        do {
            let pages = try PDFTools.parsePageRange(range, pageCount: pdfToolPageCount)
            dismissPDFToolSheet()
            performPDFOperation(title: "Extract PDF Pages", detail: target.name) {
                try await PDFTools.extract(pages, from: target.url)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func addPDFWatermark(_ text: String) {
        guard let target = pdfToolTarget else {
            dismissPDFToolSheet()
            return
        }
        dismissPDFToolSheet()
        performPDFOperation(title: "Watermark PDF", detail: target.name) {
            try await PDFTools.addWatermark(text, to: target.url)
        }
    }

    func protectPDF(_ password: String) {
        guard let target = pdfToolTarget else {
            dismissPDFToolSheet()
            return
        }
        dismissPDFToolSheet()
        performPDFOperation(title: "Protect PDF", detail: target.name) {
            try PDFTools.protect(target.url, password: password)
        }
    }

    func removePDFPassword(_ password: String) {
        guard let target = pdfToolTarget else {
            dismissPDFToolSheet()
            return
        }
        dismissPDFToolSheet()
        performPDFOperation(title: "Remove PDF Password", detail: target.name) {
            try PDFTools.removePassword(password, from: target.url)
        }
    }

    func rateSelection(_ rating: Int, ids: Set<FileItem.ID>? = nil) {
        let clamped = min(max(rating, 0), 5)
        let targets = resolvedDisplayItems(ids).filter { !$0.isDirectory }
        guard !targets.isEmpty else { return }

        let targetIDs = Set(targets.map(\.id))
        panes.forEach { $0.updateRating(for: targetIDs, rating: clamped) }

        let urls = targets.map(\.url)
        Task.detached(priority: .userInitiated) {
            var failures: [String] = []
            for url in urls {
                do {
                    try FileRatingStore.setRating(clamped, for: url)
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            guard !failures.isEmpty else { return }
            let failureText = failures.prefix(3).joined(separator: "\n")
            await MainActor.run {
                self.lastError = failureText
                self.panes.forEach { $0.refresh() }
            }
        }
    }

    func exportContactSheet(_ ids: Set<FileItem.ID>? = nil) {
        let selectedIDs = ids ?? activePane.selection
        let images = activePane.displayItems.filter { selectedIDs.contains($0.id) && $0.isImage }
        guard !images.isEmpty else {
            lastError = "Select one or more images to export a contact sheet."
            return
        }

        let destinationFolder = activePane.currentURL
        let imageCount = images.count
        let activityID = addActivity(
            title: "Contact Sheet",
            detail: operationDetail(for: images.map(\.url))
        )
        let task = Task {
            updateActivity(activityID) { activity in
                activity.status = .running
                activity.bytesTotal = 1_000
                activity.progressDetail = "0 of \(imageCount) images"
            }
            do {
                let output = try await ContactSheetExporter.export(
                    items: images,
                    toFolder: destinationFolder
                ) { progress in
                    await MainActor.run {
                        AppState.shared.updateActivity(activityID) { activity in
                            activity.bytesCompleted = Int64((progress * 1_000).rounded())
                            let completed = min(
                                imageCount,
                                max(0, Int((progress * Double(imageCount)).rounded()))
                            )
                            activity.progressDetail = "\(completed) of \(imageCount) images"
                        }
                    }
                }
                updateActivity(activityID) { activity in
                    activity.status = .completed
                    activity.finishedAt = Date()
                    activity.bytesCompleted = activity.bytesTotal
                    activity.detail = output.lastPathComponent
                    activity.progressDetail = nil
                }
            } catch is CancellationError {
                updateActivity(activityID) { activity in
                    activity.status = .cancelled
                    activity.finishedAt = Date()
                }
            } catch {
                updateActivity(activityID) { activity in
                    activity.status = .failed(error.localizedDescription)
                    activity.finishedAt = Date()
                }
                lastError = error.localizedDescription
            }
            activityTasks[activityID] = nil
            pausedActivityIDs.remove(activityID)
            panes.forEach { $0.refresh() }
        }
        activityTasks[activityID] = task
    }

    func captureVideoFrame(_ item: FileItem, at seconds: Double) {
        guard item.isVideoMedia else {
            lastError = "Select a video to capture a frame."
            return
        }

        let activityID = addActivity(title: "Capture Video Frame", detail: item.name)
        let task = Task {
            updateActivity(activityID) { activity in
                activity.status = .running
                activity.bytesTotal = 1
                activity.progressDetail = "At \(VideoTrimmer.timeText(seconds))"
            }
            do {
                let output = try await VideoFrameCapture.capture(url: item.url, at: seconds)
                updateActivity(activityID) { activity in
                    activity.status = .completed
                    activity.finishedAt = Date()
                    activity.bytesCompleted = activity.bytesTotal
                    activity.detail = output.lastPathComponent
                    activity.progressDetail = nil
                }
            } catch is CancellationError {
                updateActivity(activityID) { activity in
                    activity.status = .cancelled
                    activity.finishedAt = Date()
                }
            } catch {
                updateActivity(activityID) { activity in
                    activity.status = .failed(error.localizedDescription)
                    activity.finishedAt = Date()
                }
                lastError = error.localizedDescription
            }
            activityTasks[activityID] = nil
            pausedActivityIDs.remove(activityID)
            panes.forEach { $0.refresh() }
        }
        activityTasks[activityID] = task
    }

    func captureVideoFrames(_ item: FileItem, every interval: Double) {
        guard item.isVideoMedia else {
            lastError = "Select a video to capture screenshots."
            return
        }
        guard interval.isFinite, interval >= VideoIntervalFrameCapture.minimumInterval else {
            lastError = "The screenshot interval must be at least 100 milliseconds."
            return
        }

        let activityID = addActivity(
            title: "Capture Video Screenshots",
            detail: item.name
        )
        let task = Task {
            updateActivity(activityID) { activity in
                activity.status = .running
                activity.progressDetail = "Preparing folder and copying the original video"
            }
            do {
                let result = try await VideoIntervalFrameCapture.capture(
                    url: item.url,
                    every: interval
                ) { [weak self] completed, total in
                    guard let self else { return }
                    await MainActor.run {
                        self.updateActivity(activityID) { activity in
                            activity.bytesTotal = Int64(total)
                            activity.bytesCompleted = Int64(completed)
                            activity.progressDetail = completed == 0
                                ? "Copying the original video"
                                : "\(completed) of \(total) screenshots"
                        }
                    }
                }
                updateActivity(activityID) { activity in
                    activity.status = .completed
                    activity.finishedAt = Date()
                    activity.bytesCompleted = activity.bytesTotal
                    activity.detail = result.folderURL.lastPathComponent
                    activity.progressDetail =
                        "\(result.screenshotURLs.count) screenshots · Original video copied"
                    activity.revealURLs = [result.folderURL]
                }
            } catch is CancellationError {
                updateActivity(activityID) { activity in
                    activity.status = .cancelled
                    activity.finishedAt = Date()
                }
            } catch {
                updateActivity(activityID) { activity in
                    activity.status = .failed(error.localizedDescription)
                    activity.finishedAt = Date()
                }
                lastError = error.localizedDescription
            }
            activityTasks[activityID] = nil
            pausedActivityIDs.remove(activityID)
            panes.forEach { $0.refresh() }
        }
        activityTasks[activityID] = task
    }

    func exportVideoTrim(
        _ item: FileItem,
        inTime: Double,
        outTime: Double,
        muteAudio: Bool = false
    ) {
        guard item.isVideoMedia else {
            lastError = "Select a video to trim."
            return
        }
        guard outTime - inTime >= 0.1 else {
            lastError = "Trim out point must be after the in point."
            return
        }

        let activityID = addActivity(title: "Trim Video", detail: item.name)
        let task = Task {
            updateActivity(activityID) { activity in
                activity.status = .running
                activity.bytesTotal = 1_000
                activity.progressDetail =
                    "\(VideoTrimmer.timeText(inTime)) to \(VideoTrimmer.timeText(outTime))"
                    + (muteAudio ? " · Audio muted" : "")
            }
            do {
                let output = try await VideoTrimmer.export(
                    url: item.url,
                    inTime: inTime,
                    outTime: outTime,
                    muteAudio: muteAudio
                ) { [weak self] progress in
                    guard let self else { return }
                    await MainActor.run {
                        self.updateActivity(activityID) { activity in
                            activity.bytesCompleted = Int64((progress * 1_000).rounded())
                        }
                    }
                }
                updateActivity(activityID) { activity in
                    activity.status = .completed
                    activity.finishedAt = Date()
                    activity.bytesCompleted = activity.bytesTotal
                    activity.detail = output.lastPathComponent
                }
            } catch is CancellationError {
                updateActivity(activityID) { activity in
                    activity.status = .cancelled
                    activity.finishedAt = Date()
                }
            } catch {
                updateActivity(activityID) { activity in
                    activity.status = .failed(error.localizedDescription)
                    activity.finishedAt = Date()
                }
                lastError = error.localizedDescription
            }
            activityTasks[activityID] = nil
            pausedActivityIDs.remove(activityID)
            panes.forEach { $0.refresh() }
        }
        activityTasks[activityID] = task
    }

    func exportVideoAudio(_ item: FileItem, inTime: Double, outTime: Double) {
        guard item.isVideoMedia else {
            lastError = "Select a video to export its audio."
            return
        }
        guard outTime - inTime >= 0.1 else {
            lastError = "The audio out point must be after the in point."
            return
        }

        let activityID = addActivity(title: "Export Audio", detail: item.name)
        let task = Task {
            updateActivity(activityID) { activity in
                activity.status = .running
                activity.bytesTotal = 1_000
                activity.progressDetail =
                    "\(VideoTrimmer.timeText(inTime)) to \(VideoTrimmer.timeText(outTime)) · M4A"
            }
            do {
                let output = try await AudioRangeExporter.export(
                    url: item.url,
                    inTime: inTime,
                    outTime: outTime,
                    outputSuffix: "audio"
                ) { [weak self] progress in
                    guard let self else { return }
                    await MainActor.run {
                        self.updateActivity(activityID) { activity in
                            activity.bytesCompleted = Int64((progress * 1_000).rounded())
                        }
                    }
                }
                updateActivity(activityID) { activity in
                    activity.status = .completed
                    activity.finishedAt = Date()
                    activity.bytesCompleted = activity.bytesTotal
                    activity.detail = output.lastPathComponent
                    activity.progressDetail = "Audio-only M4A"
                    activity.revealURLs = [output]
                }
            } catch is CancellationError {
                updateActivity(activityID) { activity in
                    activity.status = .cancelled
                    activity.finishedAt = Date()
                }
            } catch {
                updateActivity(activityID) { activity in
                    activity.status = .failed(error.localizedDescription)
                    activity.finishedAt = Date()
                }
                lastError = error.localizedDescription
            }
            activityTasks[activityID] = nil
            pausedActivityIDs.remove(activityID)
            panes.forEach { $0.refresh() }
        }
        activityTasks[activityID] = task
    }

    func exportAudioTrim(_ item: FileItem, inTime: Double, outTime: Double) {
        guard item.isAudioMedia else {
            lastError = "Select an audio file to trim."
            return
        }
        guard outTime - inTime >= 0.1 else {
            lastError = "Trim out point must be after the in point."
            return
        }

        let activityID = addActivity(title: "Trim Audio", detail: item.name)
        let task = Task {
            updateActivity(activityID) { activity in
                activity.status = .running
                activity.bytesTotal = 1_000
                activity.progressDetail =
                    "\(VideoTrimmer.preciseTimeText(inTime)) to "
                    + "\(VideoTrimmer.preciseTimeText(outTime)) · M4A"
            }
            do {
                let output = try await AudioRangeExporter.export(
                    url: item.url,
                    inTime: inTime,
                    outTime: outTime,
                    outputSuffix: "trimmed"
                ) { [weak self] progress in
                    guard let self else { return }
                    await MainActor.run {
                        self.updateActivity(activityID) { activity in
                            activity.bytesCompleted = Int64((progress * 1_000).rounded())
                        }
                    }
                }
                updateActivity(activityID) { activity in
                    activity.status = .completed
                    activity.finishedAt = Date()
                    activity.bytesCompleted = activity.bytesTotal
                    activity.detail = output.lastPathComponent
                    activity.progressDetail = "Trimmed audio · M4A"
                    activity.revealURLs = [output]
                }
            } catch is CancellationError {
                updateActivity(activityID) { activity in
                    activity.status = .cancelled
                    activity.finishedAt = Date()
                }
            } catch {
                updateActivity(activityID) { activity in
                    activity.status = .failed(error.localizedDescription)
                    activity.finishedAt = Date()
                }
                lastError = error.localizedDescription
            }
            activityTasks[activityID] = nil
            pausedActivityIDs.remove(activityID)
            panes.forEach { $0.refresh() }
        }
        activityTasks[activityID] = task
    }

    func findDuplicatesAcrossPanes() {
        guard isDualPane else {
            lastError = "Open two panes to find duplicates across folders."
            return
        }
        let leftFolder = panes[0].currentURL
        let rightFolder = panes[1].currentURL
        let activityID = addActivity(
            title: "Find Duplicates",
            detail: "\(leftFolder.lastPathComponent) and \(rightFolder.lastPathComponent)"
        )
        let task = Task {
            updateActivity(activityID) { activity in
                activity.status = .running
                activity.bytesTotal = 1_000
                activity.progressDetail = "Indexing folders"
            }
            do {
                let result = try await DuplicateFinder.findAcross(
                    leftFolder: leftFolder,
                    rightFolder: rightFolder,
                    includeHidden: showHidden
                ) { progress, detail in
                    await MainActor.run {
                        AppState.shared.updateActivity(activityID) { activity in
                            activity.bytesCompleted = Int64((progress * 1_000).rounded())
                            activity.progressDetail = detail
                        }
                    }
                }
                let setText = "\(result.duplicateGroupCount) duplicate \(result.duplicateGroupCount == 1 ? "set" : "sets")"
                panes[0].showDuplicateResults(
                    result.leftItems,
                    title: setText
                )
                panes[1].showDuplicateResults(
                    result.rightItems,
                    title: setText
                )
                updateActivity(activityID) { activity in
                    activity.status = .completed
                    activity.finishedAt = Date()
                    activity.bytesCompleted = activity.bytesTotal
                    activity.detail = "\(result.duplicateFileCount) duplicate files"
                    activity.progressDetail = setText
                }
            } catch is CancellationError {
                updateActivity(activityID) { activity in
                    activity.status = .cancelled
                    activity.finishedAt = Date()
                }
            } catch {
                updateActivity(activityID) { activity in
                    activity.status = .failed(error.localizedDescription)
                    activity.finishedAt = Date()
                }
                lastError = error.localizedDescription
            }
            activityTasks[activityID] = nil
            pausedActivityIDs.remove(activityID)
        }
        activityTasks[activityID] = task
    }

    func clearDuplicateResults() {
        panes.forEach { $0.clearDuplicateResults() }
    }

    func compareFoldersAcrossPanes() {
        guard isDualPane else {
            lastError = "Open two panes to compare folders."
            return
        }
        let leftFolder = panes[0].currentURL
        let rightFolder = panes[1].currentURL
        guard leftFolder.standardizedFileURL != rightFolder.standardizedFileURL else {
            lastError = "Choose two different folders to compare."
            return
        }

        let activityID = addActivity(
            title: "Compare Folders",
            detail: "\(leftFolder.lastPathComponent) and \(rightFolder.lastPathComponent)"
        )
        let task = Task {
            updateActivity(activityID) { activity in
                activity.status = .running
                activity.bytesTotal = 1_000
                activity.progressDetail = "Scanning"
            }
            do {
                let result = try await FolderCompare.compare(
                    leftFolder: leftFolder,
                    rightFolder: rightFolder,
                    includeHidden: showHidden
                ) { progress, detail in
                    await MainActor.run {
                        AppState.shared.updateActivity(activityID) { activity in
                            activity.bytesCompleted = Int64((progress * 1_000).rounded())
                            activity.progressDetail = detail
                        }
                    }
                }
                applyFolderCompare(result, leftFolder: leftFolder, rightFolder: rightFolder)
                updateActivity(activityID) { activity in
                    activity.status = .completed
                    activity.finishedAt = Date()
                    activity.bytesCompleted = activity.bytesTotal
                    activity.detail = result.summary.title
                    activity.progressDetail = nil
                }
            } catch is CancellationError {
                updateActivity(activityID) { activity in
                    activity.status = .cancelled
                    activity.finishedAt = Date()
                }
            } catch {
                clearFolderCompare()
                updateActivity(activityID) { activity in
                    activity.status = .failed(error.localizedDescription)
                    activity.finishedAt = Date()
                }
                lastError = error.localizedDescription
            }
            activityTasks[activityID] = nil
            pausedActivityIDs.remove(activityID)
        }
        activityTasks[activityID] = task
    }

    func clearFolderCompare() {
        panes.forEach { $0.clearCompare() }
        lastFolderCompareResult = nil
        lastFolderCompareLeftURL = nil
        lastFolderCompareRightURL = nil
    }

    func syncComparedFolders(_ direction: FolderSyncDirection) {
        guard isDualPane else {
            lastError = "Open two panes to sync folders."
            return
        }
        let leftFolder = panes[0].currentURL
        let rightFolder = panes[1].currentURL
        guard leftFolder.standardizedFileURL != rightFolder.standardizedFileURL else {
            lastError = "Choose two different folders to sync."
            return
        }

        let destination = direction == .leftToRight ? rightFolder : leftFolder
        let activityID = addActivity(
            title: "Sync \(direction.title)",
            detail: "Comparing folders",
            supportsConflictPolicy: true
        )
        updateActivity(activityID) { activity in
            activity.conflictPolicy = fileOperationConflictPolicy
        }
        let policy = fileOperationConflictPolicy
        let task = Task {
            updateActivity(activityID) { activity in
                activity.status = .running
                activity.progressDetail = "Comparing"
            }
            do {
                let result: FolderCompareResult
                if let cached = cachedFolderCompare(leftFolder: leftFolder, rightFolder: rightFolder) {
                    result = cached
                } else {
                    updateActivity(activityID) { activity in
                        activity.bytesTotal = 1_000
                    }
                    result = try await FolderCompare.compare(
                        leftFolder: leftFolder,
                        rightFolder: rightFolder,
                        includeHidden: showHidden
                    ) { progress, detail in
                        await MainActor.run {
                            AppState.shared.updateActivity(activityID) { activity in
                                activity.bytesCompleted = Int64((progress * 1_000).rounded())
                                activity.progressDetail = detail
                            }
                        }
                    }
                    applyFolderCompare(result, leftFolder: leftFolder, rightFolder: rightFolder)
                }

                let sources = direction == .leftToRight
                    ? result.leftToRightSources
                    : result.rightToLeftSources
                if sources.isEmpty {
                    updateActivity(activityID) { activity in
                        activity.status = .completed
                        activity.finishedAt = Date()
                        activity.bytesCompleted = activity.bytesTotal
                        activity.detail = "Nothing to sync"
                        activity.progressDetail = nil
                    }
                } else {
                    updateActivity(activityID) { activity in
                        activity.detail = "\(operationDetail(for: sources)) to \(destination.lastPathComponent)"
                        activity.bytesCompleted = 0
                        activity.bytesTotal = 0
                        activity.progressDetail = nil
                    }
                    _ = try await FileOperations.transfer(
                        sources,
                        to: destination,
                        move: false,
                        conflictPolicy: policy,
                        progress: { [weak self] completed, total in
                            guard let self else { return }
                            await MainActor.run {
                                self.updateActivity(activityID) { activity in
                                    activity.bytesCompleted = completed
                                    activity.bytesTotal = total
                                }
                            }
                        },
                        isPaused: { [weak self] in
                            guard let self else { return false }
                            return await MainActor.run {
                                self.pausedActivityIDs.contains(activityID)
                            }
                        }
                    )
                    updateActivity(activityID) { activity in
                        activity.status = .completed
                        activity.finishedAt = Date()
                        activity.bytesCompleted = activity.bytesTotal
                    }
                    clearFolderCompare()
                    panes.forEach { $0.refresh() }
                }
            } catch is CancellationError {
                updateActivity(activityID) { activity in
                    activity.status = .cancelled
                    activity.finishedAt = Date()
                }
            } catch {
                updateActivity(activityID) { activity in
                    activity.status = .failed(error.localizedDescription)
                    activity.finishedAt = Date()
                }
                lastError = error.localizedDescription
            }
            activityTasks[activityID] = nil
            pausedActivityIDs.remove(activityID)
        }
        activityTasks[activityID] = task
    }

    func beginMergeIntoVideo(_ ids: Set<FileItem.ID>? = nil) {
        let selected = resolvedDisplayItems(ids)
        guard selected.count >= 2 else {
            lastError = "Select at least two images or videos to merge."
            return
        }
        guard selected.allSatisfy({ $0.isImage || $0.isVideoMedia }) else {
            lastError = "Merge Into Video supports images and videos only."
            return
        }

        mergeIntoVideoTargets = selected
        closeAllTools()
        showMergeIntoVideoSheet = true
    }

    func performMergeIntoVideo(targets: [FileItem], options: VideoMergeOptions) {
        guard targets.count >= 2,
              targets.allSatisfy({ $0.isImage || $0.isVideoMedia }) else {
            lastError = "Select at least two images or videos to merge."
            return
        }
        mergeIntoVideoTargets = targets
        let sources = targets.map { item in
            item.isImage ? VideoMergeSource.image(item.url) : .video(item.url)
        }
        let imageCount = targets.filter(\.isImage).count
        let videoCount = targets.count - imageCount
        let activityID = addActivity(
            title: "Merge Into Video",
            detail: "\(imageCount) image\(imageCount == 1 ? "" : "s"), "
                + "\(videoCount) video\(videoCount == 1 ? "" : "s")"
        )
        let destinationFolder = activePane.currentURL
        mergeIntoVideoProgress = 0
        let task = Task {
            updateActivity(activityID) { activity in
                activity.status = .running
                activity.bytesTotal = 1_000
                activity.progressDetail = "Preparing media"
            }
            do {
                let output = try await MediaVideoRenderer.merge(
                    sources,
                    outputDirectory: destinationFolder,
                    options: options
                ) { [weak self] progress in
                    guard let self else { return }
                    await MainActor.run {
                        let clampedProgress = min(max(progress, 0), 1)
                        self.mergeIntoVideoProgress = clampedProgress
                        self.updateActivity(activityID) { activity in
                            let percent = Int((clampedProgress * 100).rounded())
                            activity.bytesCompleted = Int64((clampedProgress * 1_000).rounded())
                            activity.progressDetail = "Merging \(percent)%"
                        }
                    }
                }
                updateActivity(activityID) { activity in
                    activity.status = .completed
                    activity.finishedAt = Date()
                    activity.bytesCompleted = activity.bytesTotal
                    activity.detail = output.lastPathComponent
                    activity.progressDetail = nil
                }
                activePane.selection = [output.path]
            } catch is CancellationError {
                updateActivity(activityID) { activity in
                    activity.status = .cancelled
                    activity.finishedAt = Date()
                }
            } catch {
                updateActivity(activityID) { activity in
                    activity.status = .failed(error.localizedDescription)
                    activity.finishedAt = Date()
                }
                lastError = error.localizedDescription
            }
            mergeIntoVideoProgress = nil
            showMergeIntoVideoSheet = false
            mergeIntoVideoTask = nil
            activityTasks[activityID] = nil
            pausedActivityIDs.remove(activityID)
            panes.forEach { $0.refresh() }
        }
        mergeIntoVideoTask = task
        activityTasks[activityID] = task
    }

    func cancelMergeIntoVideo() {
        mergeIntoVideoTask?.cancel()
    }

    func beginPreviewSlideshow(_ ids: Set<FileItem.ID>? = nil) {
        let chosenIDs = ids ?? activePane.selection
        let explicitItems = chosenIDs.isEmpty ? [] : activePane.resolvedItems(chosenIDs)
        var playlist: [FileItem]

        if explicitItems.isEmpty {
            playlist = activePane.displayItems.filter(\.isPreviewable)
        } else {
            playlist = explicitItems.filter(\.isPreviewable)
            for folder in explicitItems where folder.isDirectory {
                playlist.append(contentsOf: previewableChildren(in: folder.url))
            }
            if playlist.isEmpty {
                playlist = activePane.displayItems.filter(\.isPreviewable)
            }
        }

        playlist = uniqueItemsPreservingOrder(playlist)
        guard !playlist.isEmpty else {
            lastError = "Select a folder or one or more media files to play a slideshow."
            return
        }

        previewSlideshowItems = playlist
        closeAllTools()
        showPreviewSlideshow = true
    }

    func transformSelection(_ ids: Set<FileItem.ID>? = nil, operation: ImageProcessing.Transform) {
        let urls = resolvedItems(ids).filter(\.isImage).map(\.url)
        guard !urls.isEmpty else {
            lastError = "Select one or more images to rotate or flip."
            return
        }
        run {
            for url in urls {
                try await ImageProcessing.transform(url, operation)
            }
        }
    }

    /// Applies a preview transform to images in place and exports transformed video copies.
    @discardableResult
    func transformPreviewMedia(
        _ items: [FileItem],
        operation: MediaTransformOperation
    ) -> UUID? {
        let targets = items.filter { $0.isImage || $0.isVideoMedia }
        guard !targets.isEmpty else {
            lastError = "Select one or more images or videos to transform."
            return nil
        }

        let total = targets.count
        let activityID = addActivity(
            title: operation.title,
            detail: operationDetail(for: targets.map(\.url))
        )
        let task = Task { [weak self] in
            guard let self else { return }
            self.updateActivity(activityID) { activity in
                activity.status = .running
                activity.bytesTotal = 1_000
                activity.progressDetail = "0 of \(total) items"
            }

            var completed = 0
            var failures: [String] = []
            var outputNames: [String] = []

            for target in targets {
                do {
                    try Task.checkCancellation()
                    self.updateActivity(activityID) { activity in
                        activity.detail = target.name
                    }

                    if target.isImage {
                        try await ImageProcessing.transform(target.url, operation.imageTransform)
                        outputNames.append(target.name)
                    } else {
                        let completedBeforeCurrent = completed
                        let output = try await VideoTransformer.transform(
                            target.url,
                            operation: operation
                        ) { [weak self] progress in
                            guard let self else { return }
                            await MainActor.run {
                                self.updateActivity(activityID) { activity in
                                    let totalProgress = (
                                        Double(completedBeforeCurrent) + progress
                                    ) / Double(total)
                                    activity.bytesCompleted = Int64((totalProgress * 1_000).rounded())
                                    activity.progressDetail = "\(Int((progress * 100).rounded()))% · \(completedBeforeCurrent + 1) of \(total) items"
                                }
                            }
                        }
                        outputNames.append(output.lastPathComponent)
                    }
                } catch is CancellationError {
                    self.updateActivity(activityID) { activity in
                        activity.status = .cancelled
                        activity.finishedAt = Date()
                    }
                    self.activityTasks[activityID] = nil
                    self.pausedActivityIDs.remove(activityID)
                    self.panes.forEach { $0.refresh() }
                    return
                } catch {
                    failures.append("\(target.name): \(error.localizedDescription)")
                }

                completed += 1
                self.updateActivity(activityID) { activity in
                    let totalProgress = Double(completed) / Double(total)
                    activity.bytesCompleted = Int64((totalProgress * 1_000).rounded())
                    activity.progressDetail = "\(completed) of \(total) items"
                }
            }

            if failures.isEmpty {
                self.updateActivity(activityID) { activity in
                    activity.status = .completed
                    activity.finishedAt = Date()
                    activity.bytesCompleted = activity.bytesTotal
                    activity.detail = outputNames.last ?? operation.title
                    activity.progressDetail = nil
                }
            } else {
                self.updateActivity(activityID) { activity in
                    activity.status = .failed(
                        "\(failures.count) transform\(failures.count == 1 ? "" : "s") failed"
                    )
                    activity.finishedAt = Date()
                    activity.detail = "\(completed - failures.count) completed, \(failures.count) failed"
                }
                self.lastError = failures.prefix(3).joined(separator: "\n")
            }
            self.activityTasks[activityID] = nil
            self.pausedActivityIDs.remove(activityID)
            self.panes.forEach { $0.refresh() }
        }
        activityTasks[activityID] = task
        return activityID
    }

    func addSelectionToDropStack(_ ids: Set<FileItem.ID>? = nil) {
        let urls = resolvedURLs(ids)
        guard !urls.isEmpty else {
            lastError = "Select one or more files to add to the drop stack."
            return
        }
        DropStackStore.shared.add(urls)
        if activeToolPanel != .dropStack {
            activeToolPanel = .dropStack
        }
    }

    func addURLsToDropStack(_ urls: [URL]) {
        DropStackStore.shared.add(urls)
    }

    func transferDropStackToOtherPane(move: Bool) {
        guard isDualPane else {
            lastError = "Open two panes to use the drop stack with the other pane."
            return
        }
        transferDropStack(to: inactivePane.currentURL, move: move)
    }

    func transferDropStackToActiveFolder(move: Bool) {
        transferDropStack(to: activePane.currentURL, move: move)
    }

    func transferDropStack(to destination: URL, move: Bool) {
        let urls = DropStackStore.shared.selectedURLs
        guard !urls.isEmpty else {
            lastError = "Add one or more files to the drop stack first."
            return
        }
        if move {
            DropStackStore.shared.remove(Set(urls.map { $0.standardizedFileURL.path }))
        }
        enqueueTransfer(urls, to: destination, move: move)
    }

    func revealDropStackSelection() {
        let urls = DropStackStore.shared.selectedURLs
        guard !urls.isEmpty else {
            lastError = "Add one or more files to the drop stack first."
            return
        }
        revealInFinder(urls)
    }

    func runSelectedWorkflow(source: SavedWorkflowRunSource) {
        guard let workflow = SavedWorkflowStore.shared.selectedWorkflow else {
            lastError = "Create or select a workflow first."
            return
        }
        runWorkflow(workflow, source: source)
    }

    func runWorkflow(_ workflow: SavedWorkflow, source: SavedWorkflowRunSource) {
        guard !workflow.steps.isEmpty else {
            lastError = "Add at least one step to “\(workflow.name)”."
            return
        }
        if workflow.steps.contains(where: \.requiresDualPane), !isDualPane {
            lastError = "Open two panes before running “\(workflow.name)”."
            return
        }

        let urls = workflowURLs(from: source)
        guard !urls.isEmpty else {
            lastError = source == .dropStack
                ? "Add one or more files to the drop stack first."
                : "Select one or more files first."
            return
        }

        let destination = inactivePane.currentURL
        let activeFolder = activePane.currentURL
        let policy = fileOperationConflictPolicy
        let activityID = addActivity(
            title: "Workflow",
            detail: "\(workflow.name) · \(operationDetail(for: urls))",
            supportsConflictPolicy: workflow.steps.contains { $0 == .copyToOtherPane || $0 == .moveToOtherPane }
        )
        updateActivity(activityID) { activity in
            activity.conflictPolicy = policy
            activity.bytesTotal = 1_000
        }

        let task = Task { [weak self] in
            guard let self else { return }
            self.updateActivity(activityID) { activity in
                activity.status = .running
            }

            var moveRecords: [FileMoveRecord] = []
            var revealURLs: [URL] = []

            do {
                for (offset, step) in workflow.steps.enumerated() {
                    try Task.checkCancellation()
                    let baseProgress = Double(offset) / Double(workflow.steps.count)
                    let stepWeight = 1.0 / Double(workflow.steps.count)
                    self.updateActivity(activityID) { activity in
                        activity.progressDetail = step.title
                        activity.bytesCompleted = Int64((baseProgress * 1_000).rounded())
                    }

                    switch step {
                    case .optimizeImages:
                        for item in self.workflowItems(from: urls).filter(\.isImage) {
                            try await ImageProcessing.optimize(item.url)
                        }
                    case .createThumbnails:
                        for item in self.workflowItems(from: urls).filter(\.isImage) {
                            let output = try await ImageProcessing.createThumbnail(item.url)
                            revealURLs.append(output)
                        }
                    case .grayscaleImages:
                        for item in self.workflowItems(from: urls).filter(\.isImage) {
                            let output = try await ImageProcessing.grayscale(item.url)
                            revealURLs.append(output)
                        }
                    case .contactSheetPDF:
                        let images = self.workflowItems(from: urls).filter(\.isImage)
                        if !images.isEmpty {
                            let output = try await ContactSheetExporter.export(
                                items: images,
                                toFolder: activeFolder
                            ) { progress in
                                await MainActor.run {
                                    self.updateActivity(activityID) { activity in
                                        let total = baseProgress + (progress * stepWeight)
                                        activity.bytesCompleted = Int64((total * 1_000).rounded())
                                    }
                                }
                            }
                            revealURLs.append(output)
                        }
                    case .copyPaths:
                        ClipboardHistoryStore.shared.copyPaths(urls.map(\.path))
                    case .copyNames:
                        ClipboardHistoryStore.shared.copyNames(urls.map(\.lastPathComponent))
                    case .createSnippets:
                        let files = self.workflowItems(from: urls)
                            .filter { !$0.isDirectory }
                            .map(\.url)
                        if !files.isEmpty {
                            SnippetStore.shared.createSnippet(withFiles: files)
                        }
                    case .rateThreeStars:
                        try self.applyWorkflowRating(3, urls: urls)
                    case .rateFiveStars:
                        try self.applyWorkflowRating(5, urls: urls)
                    case .copyToOtherPane:
                        _ = try await FileOperations.transfer(
                            urls,
                            to: destination,
                            move: false,
                            conflictPolicy: policy,
                            progress: { completed, total in
                                await MainActor.run {
                                    self.updateActivity(activityID) { activity in
                                        guard total > 0 else { return }
                                        let fileProgress = Double(completed) / Double(total)
                                        let totalProgress = baseProgress + (fileProgress * stepWeight)
                                        activity.bytesCompleted = Int64((totalProgress * 1_000).rounded())
                                    }
                                }
                            },
                            isPaused: { [weak self] in
                                guard let self else { return false }
                                return await MainActor.run {
                                    self.pausedActivityIDs.contains(activityID)
                                }
                            }
                        )
                        revealURLs.append(destination)
                    case .moveToOtherPane:
                        let records = try await FileOperations.transfer(
                            urls,
                            to: destination,
                            move: true,
                            conflictPolicy: policy,
                            progress: { completed, total in
                                await MainActor.run {
                                    self.updateActivity(activityID) { activity in
                                        guard total > 0 else { return }
                                        let fileProgress = Double(completed) / Double(total)
                                        let totalProgress = baseProgress + (fileProgress * stepWeight)
                                        activity.bytesCompleted = Int64((totalProgress * 1_000).rounded())
                                    }
                                }
                            },
                            isPaused: { [weak self] in
                                guard let self else { return false }
                                return await MainActor.run {
                                    self.pausedActivityIDs.contains(activityID)
                                }
                            }
                        )
                        moveRecords.append(contentsOf: records)
                        revealURLs.append(contentsOf: records.map(\.destination))
                    }

                    self.updateActivity(activityID) { activity in
                        let completed = Double(offset + 1) / Double(workflow.steps.count)
                        activity.bytesCompleted = Int64((completed * 1_000).rounded())
                    }
                }

                let undo = moveRecords.isEmpty
                    ? nil
                    : FileUndoAction.moveBack(title: workflow.name, records: moveRecords)
                if let undo {
                    self.undoStack.append(undo)
                }
                if source == .dropStack, !moveRecords.isEmpty {
                    DropStackStore.shared.remove(Set(moveRecords.map { $0.source.standardizedFileURL.path }))
                }

                self.updateActivity(activityID) { activity in
                    activity.status = .completed
                    activity.finishedAt = Date()
                    activity.bytesCompleted = activity.bytesTotal
                    activity.progressDetail = nil
                    activity.undoAction = undo
                    activity.revealURLs = revealURLs.isEmpty ? self.defaultRevealURLs(for: undo) : revealURLs
                }
            } catch is CancellationError {
                self.updateActivity(activityID) { activity in
                    activity.status = .cancelled
                    activity.finishedAt = Date()
                }
            } catch {
                self.updateActivity(activityID) { activity in
                    activity.status = .failed(error.localizedDescription)
                    activity.finishedAt = Date()
                }
                self.lastError = error.localizedDescription
            }

            self.activityTasks[activityID] = nil
            self.pausedActivityIDs.remove(activityID)
            self.panes.forEach { $0.refresh() }
        }
        activityTasks[activityID] = task
    }

    func copyPathOfSelection(_ ids: Set<FileItem.ID>? = nil) {
        let paths = resolvedURLs(ids).map(\.path)
        guard !paths.isEmpty else { return }
        ClipboardHistoryStore.shared.copyPaths(paths)
    }

    func copyNamesOfSelection(_ ids: Set<FileItem.ID>? = nil) {
        let names = resolvedItems(ids).map(\.name)
        guard !names.isEmpty else { return }
        ClipboardHistoryStore.shared.copyNames(names)
    }

    func copyFilesOfSelection(_ ids: Set<FileItem.ID>? = nil) {
        let urls = resolvedURLs(ids)
        guard !urls.isEmpty else { return }
        ClipboardHistoryStore.shared.copyFiles(urls)
    }

    func cutFilesOfSelection(_ ids: Set<FileItem.ID>? = nil) {
        let urls = resolvedURLs(ids)
        guard !urls.isEmpty else { return }
        ClipboardHistoryStore.shared.cutFiles(urls)
    }

    func shareSelectionViaAirDrop(_ ids: Set<FileItem.ID>? = nil) {
        let urls = resolvedURLs(ids)
        guard !urls.isEmpty else {
            lastError = "Select one or more files to share."
            return
        }
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            lastError = "AirDrop is not available on this Mac."
            return
        }
        let items = urls.map { $0 as NSURL }
        guard service.canPerform(withItems: items) else {
            lastError = "AirDrop cannot share the selected item."
            return
        }
        service.perform(withItems: items)
    }

    func pasteClipboardFiles(to destination: URL, move: Bool? = nil) {
        let pasteboard = NSPasteboard.general
        let urls = FilePasteboard.fileURLs(from: pasteboard)
        guard !urls.isEmpty else {
            lastError = "Copy or cut one or more files first."
            return
        }
        let shouldMove = move ?? (FilePasteboard.operation(from: pasteboard) == .cut)
        enqueueTransfer(urls, to: destination, move: shouldMove)
    }

    func pasteClipboardFilesToActiveFolder(move: Bool? = nil) {
        pasteClipboardFiles(to: activePane.currentURL, move: move)
    }

    func pasteClipboardHistoryFiles(_ entry: ClipboardHistoryEntry, move: Bool) {
        guard entry.kind == .files else {
            ClipboardHistoryStore.shared.restoreToPasteboard(entry)
            return
        }
        let urls = entry.existingFileURLs
        guard !urls.isEmpty else {
            lastError = "The selected clipboard files are no longer available."
            return
        }
        enqueueTransfer(urls, to: activePane.currentURL, move: move)
    }

    func revealSelectionInFinder(_ ids: Set<FileItem.ID>? = nil) {
        NSWorkspace.shared.activateFileViewerSelecting(resolvedURLs(ids))
    }

    func revealInFinder(_ urls: [URL]) {
        let existingURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existingURLs.isEmpty else {
            lastError = "The selected item is no longer available."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(existingURLs)
    }

    func unmountDevice(at url: URL) {
        let deviceURL = url.standardizedFileURL
        let name = deviceURL.lastPathComponent.isEmpty ? deviceURL.path : deviceURL.lastPathComponent
        Task {
            let isMounted = await Task.detached(priority: .userInitiated) {
                MountedVolumeSupport.isMounted(deviceURL)
            }.value
            guard isMounted else {
                completeDeviceUnmount(at: deviceURL)
                return
            }

            do {
                try await Task.detached(priority: .userInitiated) {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: deviceURL)
                }.value
                completeDeviceUnmount(at: deviceURL)
            } catch {
                // Physical removal can race with this call. If macOS no longer
                // reports the volume as mounted, the requested end state has
                // already been reached and there is no error to present.
                let isStillMounted = await Task.detached(priority: .userInitiated) {
                    MountedVolumeSupport.isMounted(deviceURL)
                }.value
                guard isStillMounted else {
                    completeDeviceUnmount(at: deviceURL)
                    return
                }
                lastError = "Couldn’t unmount “\(name)”: \(error.localizedDescription)"
            }
        }
    }

    private func completeDeviceUnmount(at deviceURL: URL) {
        let fallback = FileManager.default.homeDirectoryForCurrentUser
        panes.forEach {
            $0.recoverFromUnavailableVolume(deviceURL, fallback: fallback)
        }
        if lastError?.hasPrefix("Couldn’t unmount “") == true {
            lastError = nil
        }
        NotificationCenter.default.post(
            name: .workbenchMountedVolumesChanged,
            object: deviceURL
        )
    }

    func reportProblem() {
        WorkbenchSupportActions.openSupportEmail()
    }

    func copySupportDiagnostics() {
        WorkbenchSupportActions.copyDiagnostics()
    }

    func revealWorkbenchSupportFolder() {
        WorkbenchSupportActions.revealSupportFolder()
    }

    func exportWorkbenchDataBackup() {
        let panel = NSSavePanel()
        panel.title = "Export Workbench Data"
        panel.message = "Save a backup of Workbench notes, snippets, clipboard history, disk analysis cache, and preferences."
        panel.nameFieldStringValue = WorkbenchDataBackup.suggestedFilename()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let activityID = addActivity(title: "Export Workbench Data", detail: destination.lastPathComponent)
        let task = Task {
            updateActivity(activityID) { activity in
                activity.status = .running
            }
            do {
                let output = try await WorkbenchDataBackup.export(to: destination)
                updateActivity(activityID) { activity in
                    activity.detail = output.lastPathComponent
                    activity.status = .completed
                    activity.finishedAt = Date()
                    activity.bytesCompleted = 1
                    activity.bytesTotal = 1
                    activity.revealURLs = [output]
                }
            } catch is CancellationError {
                updateActivity(activityID) { activity in
                    activity.status = .cancelled
                    activity.finishedAt = Date()
                }
            } catch {
                updateActivity(activityID) { activity in
                    activity.status = .failed(error.localizedDescription)
                    activity.finishedAt = Date()
                }
                lastError = error.localizedDescription
            }
            activityTasks[activityID] = nil
        }
        activityTasks[activityID] = task
    }

    func importWorkbenchDataBackup() {
        let panel = NSOpenPanel()
        panel.title = "Import Workbench Data"
        panel.message = "Choose a Workbench backup ZIP to restore notes, snippets, clipboard history, disk analysis cache, and preferences."
        panel.allowedContentTypes = [.zip]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK,
              let source = panel.url,
              confirmImportWorkbenchData(from: source) else {
            return
        }

        let activityID = addActivity(title: "Import Workbench Data", detail: source.lastPathComponent)
        let task = Task {
            updateActivity(activityID) { activity in
                activity.status = .running
            }
            do {
                let result = try await WorkbenchDataBackup.importBackup(from: source)
                reloadWorkbenchStoresAfterImport()
                updateActivity(activityID) { activity in
                    activity.detail = result.summary
                    activity.status = .completed
                    activity.finishedAt = Date()
                    activity.bytesCompleted = 1
                    activity.bytesTotal = 1
                    activity.revealURLs = [result.safetyBackupURL].compactMap { $0 }
                    if result.restoredPreferences {
                        activity.progressDetail = "Restart Workbench to apply restored preferences."
                    }
                }
            } catch is CancellationError {
                updateActivity(activityID) { activity in
                    activity.status = .cancelled
                    activity.finishedAt = Date()
                }
            } catch {
                updateActivity(activityID) { activity in
                    activity.status = .failed(error.localizedDescription)
                    activity.finishedAt = Date()
                }
                lastError = error.localizedDescription
            }
            activityTasks[activityID] = nil
        }
        activityTasks[activityID] = task
    }

    func exportWorkbenchDiagnostics() {
        let panel = NSSavePanel()
        panel.title = "Export Workbench Diagnostics"
        panel.message = "Save a support ZIP with version info, recent Workbench logs, crash reports, and activity history."
        panel.nameFieldStringValue = WorkbenchDiagnostics.suggestedFilename()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let activityDiagnostics = fileActivities.map { WorkbenchActivityDiagnostic(activity: $0) }
        let activityID = addActivity(title: "Export Diagnostics", detail: destination.lastPathComponent)
        let task = Task {
            updateActivity(activityID) { activity in
                activity.status = .running
            }
            do {
                let output = try await WorkbenchDiagnostics.export(
                    to: destination,
                    activities: activityDiagnostics
                )
                updateActivity(activityID) { activity in
                    activity.detail = output.lastPathComponent
                    activity.status = .completed
                    activity.finishedAt = Date()
                    activity.bytesCompleted = 1
                    activity.bytesTotal = 1
                    activity.revealURLs = [output]
                }
            } catch is CancellationError {
                updateActivity(activityID) { activity in
                    activity.status = .cancelled
                    activity.finishedAt = Date()
                }
            } catch {
                updateActivity(activityID) { activity in
                    activity.status = .failed(error.localizedDescription)
                    activity.finishedAt = Date()
                }
                lastError = error.localizedDescription
            }
            activityTasks[activityID] = nil
        }
        activityTasks[activityID] = task
    }

    func moveItemsToExternalDrive(_ urls: [URL], destination: URL) {
        let existingURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existingURLs.isEmpty else {
            lastError = "The selected item is no longer available."
            return
        }
        enqueueTransfer(existingURLs, to: destination, move: true)
    }

    func undoLastFileOperation() {
        guard let action = undoStack.popLast() else {
            NSSound.beep()
            return
        }
        markUndoActionConsumed(action)
        performUndo(action)
    }

    func canUndoActivity(_ id: UUID) -> Bool {
        guard let action = fileActivities.first(where: { $0.id == id })?.undoAction else {
            return false
        }
        return undoStack.contains(action)
    }

    func undoActivity(_ id: UUID) {
        guard let action = fileActivities.first(where: { $0.id == id })?.undoAction,
              let stackIndex = undoStack.lastIndex(of: action) else {
            NSSound.beep()
            return
        }
        undoStack.remove(at: stackIndex)
        markUndoActionConsumed(action)
        performUndo(action)
    }

    func canRevealActivity(_ id: UUID) -> Bool {
        guard let activity = fileActivities.first(where: { $0.id == id }) else { return false }
        return activity.revealURLs.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    func revealActivity(_ id: UUID) {
        guard let urls = fileActivities.first(where: { $0.id == id })?.revealURLs,
              urls.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            NSSound.beep()
            return
        }
        revealInFinder(urls)
    }

    private func performUndo(_ action: FileUndoAction) {
        let title = action.title
        let activityID = addActivity(title: "Undo \(title)", detail: "Restoring files")
        let task = Task {
            updateActivity(activityID) { activity in
                activity.status = .running
            }
            do {
                try await FileOperations.undo(action)
                updateActivity(activityID) { activity in
                    activity.status = .completed
                    activity.finishedAt = Date()
                    activity.bytesCompleted = activity.bytesTotal
                }
            } catch {
                undoStack.append(action)
                updateActivity(activityID) { activity in
                    activity.status = .failed(error.localizedDescription)
                    activity.finishedAt = Date()
                }
                lastError = error.localizedDescription
            }
            activityTasks[activityID] = nil
            panes.forEach { $0.refresh() }
        }
        activityTasks[activityID] = task
    }

    private func markUndoActionConsumed(_ action: FileUndoAction) {
        for index in fileActivities.indices where fileActivities[index].undoAction == action {
            fileActivities[index].undoAction = nil
        }
    }

    func togglePauseActivity(_ id: UUID) {
        guard let index = fileActivities.firstIndex(where: { $0.id == id }) else { return }
        if pausedActivityIDs.contains(id) {
            pausedActivityIDs.remove(id)
            if !fileActivities[index].status.isTerminal {
                fileActivities[index].status = .running
            }
        } else {
            pausedActivityIDs.insert(id)
            if !fileActivities[index].status.isTerminal {
                fileActivities[index].status = .paused
            }
        }
    }

    func cancelActivity(_ id: UUID) {
        activityTasks[id]?.cancel()
        activityTasks[id] = nil
        pausedActivityIDs.remove(id)
        updateActivity(id) { activity in
            activity.status = .cancelled
            activity.finishedAt = Date()
        }
    }

    func clearCompletedActivities() {
        fileActivities.removeAll { $0.status.isTerminal }
    }

    // MARK: - Helpers

    private func confirmImportWorkbenchData(from source: URL) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Import Workbench Data?"
        alert.informativeText = """
        This will restore data from “\(source.lastPathComponent)” and replace the current Workbench notes, snippets, clipboard history, disk analysis cache, and preferences included in the backup.

        Workbench will first create a pre-import safety backup.
        """
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func reloadWorkbenchStoresAfterImport() {
        NotesStore.shared.load()
        SnippetStore.shared.reloadFromDisk()
        ClipboardHistoryStore.shared.reloadFromDisk()
        DiskSpaceAnalyzerStore.shared.reloadSavedSnapshot()
        panes.forEach { $0.refresh() }
    }

    private func applyFolderCompare(
        _ result: FolderCompareResult,
        leftFolder: URL,
        rightFolder: URL
    ) {
        guard panes[0].currentURL.standardizedFileURL == leftFolder.standardizedFileURL,
              panes[1].currentURL.standardizedFileURL == rightFolder.standardizedFileURL else {
            return
        }
        panes[0].showCompare(markers: result.leftMarkers, title: result.summary.title)
        panes[1].showCompare(markers: result.rightMarkers, title: result.summary.title)
        lastFolderCompareResult = result
        lastFolderCompareLeftURL = leftFolder
        lastFolderCompareRightURL = rightFolder
    }

    private func cachedFolderCompare(leftFolder: URL, rightFolder: URL) -> FolderCompareResult? {
        guard panes[0].isCompareActive,
              panes[1].isCompareActive,
              lastFolderCompareLeftURL?.standardizedFileURL == leftFolder.standardizedFileURL,
              lastFolderCompareRightURL?.standardizedFileURL == rightFolder.standardizedFileURL else {
            return nil
        }
        return lastFolderCompareResult
    }

    private func resolvedItems(_ ids: Set<FileItem.ID>?) -> [FileItem] {
        if let ids {
            return activePane.resolvedItems(ids)
        }
        return activePane.selectedItems
    }

    private func resolvedDisplayItems(_ ids: Set<FileItem.ID>?) -> [FileItem] {
        let selectedIDs = ids ?? activePane.selection
        let visible = activePane.displayItems.filter { selectedIDs.contains($0.id) }
        let visibleIDs = Set(visible.map(\.id))
        let missing = selectedIDs.subtracting(visibleIDs).compactMap(PaneModel.itemIfReachable)
        return visible + missing
    }

    private func resolvedURLs(_ ids: Set<FileItem.ID>?) -> [URL] {
        resolvedItems(ids).map(\.url)
    }

    private func expandedCurrentDragSession(matching droppedURLs: [URL]) -> FileDragSession? {
        guard let session = currentFileDragSession else { return nil }
        let droppedPaths = Set(droppedURLs.map { $0.standardizedFileURL.path })
        let sessionPaths = Set(session.urls.map { $0.standardizedFileURL.path })
        guard !droppedPaths.isDisjoint(with: sessionPaths) else { return nil }
        return session
    }

    private func previewableChildren(in folder: URL) -> [FileItem] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: FileItem.resourceKeys,
            options: []
        ) else {
            return []
        }
        var items = urls.map(FileItem.make)
        if !showHidden {
            items = items.filter { !$0.isHidden }
        }
        return items
            .filter(\.isPreviewable)
            .sorted { left, right in
                left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
    }

    private func uniqueItemsPreservingOrder(_ items: [FileItem]) -> [FileItem] {
        var seen = Set<FileItem.ID>()
        var result: [FileItem] = []
        for item in items where !seen.contains(item.id) {
            seen.insert(item.id)
            result.append(item)
        }
        return result
    }

    private func workflowURLs(from source: SavedWorkflowRunSource) -> [URL] {
        switch source {
        case .selection:
            resolvedURLs(nil)
        case .dropStack:
            DropStackStore.shared.selectedURLs
        }
    }

    private func workflowItems(from urls: [URL]) -> [FileItem] {
        urls.compactMap { PaneModel.itemIfReachable(id: $0.standardizedFileURL.path) }
    }

    private func applyWorkflowRating(_ rating: Int, urls: [URL]) throws {
        let items = workflowItems(from: urls).filter { !$0.isDirectory }
        guard !items.isEmpty else { return }

        let clamped = min(max(rating, 0), 5)
        let ids = Set(items.map(\.id))
        panes.forEach { $0.updateRating(for: ids, rating: clamped) }

        for item in items {
            try FileRatingStore.setRating(clamped, for: item.url)
        }
    }

    private func fileURLsFromPasteboard() -> [URL] {
        FilePasteboard.fileURLs(from: NSPasteboard.general)
    }

    private func enqueueTransfer(_ urls: [URL], to destination: URL, move: Bool) {
        let title = move ? "Move" : "Copy"
        let detail = "\(operationDetail(for: urls)) to \(destination.lastPathComponent)"
        let policy = fileOperationConflictPolicy
        let activityID = addActivity(title: title, detail: detail, supportsConflictPolicy: true)
        updateActivity(activityID) { activity in
            activity.conflictPolicy = policy
        }

        let task = Task {
            updateActivity(activityID) { activity in
                activity.status = .running
            }
            do {
                let records = try await FileOperations.transfer(
                    urls,
                    to: destination,
                    move: move,
                    conflictPolicy: policy,
                    progress: { [weak self] completed, total in
                        guard let self else { return }
                        await MainActor.run {
                            self.updateActivity(activityID) { activity in
                                activity.bytesCompleted = completed
                                activity.bytesTotal = total
                            }
                        }
                    },
                    isPaused: { [weak self] in
                        guard let self else { return false }
                        return await MainActor.run {
                            self.pausedActivityIDs.contains(activityID)
                        }
                    }
                )
                if move, !records.isEmpty {
                    let undo = FileUndoAction.moveBack(title: "Move", records: records)
                    undoStack.append(undo)
                    updateActivity(activityID) { activity in
                        activity.undoAction = undo
                        activity.revealURLs = records.map(\.destination)
                    }
                } else if !move {
                    updateActivity(activityID) { activity in
                        activity.revealURLs = [destination]
                    }
                }
                updateActivity(activityID) { activity in
                    activity.status = .completed
                    activity.finishedAt = Date()
                    activity.bytesCompleted = activity.bytesTotal
                }
            } catch is CancellationError {
                updateActivity(activityID) { activity in
                    activity.status = .cancelled
                    activity.finishedAt = Date()
                }
            } catch {
                updateActivity(activityID) { activity in
                    activity.status = .failed(error.localizedDescription)
                    activity.finishedAt = Date()
                }
                lastError = error.localizedDescription
            }
            activityTasks[activityID] = nil
            pausedActivityIDs.remove(activityID)
            panes.forEach { $0.refresh() }
        }
        activityTasks[activityID] = task
    }

    private func singlePDFTarget(_ ids: Set<FileItem.ID>? = nil) -> FileItem? {
        let targets = resolvedDisplayItems(ids).filter(PDFTools.isPDF)
        guard targets.count == 1 else {
            lastError = "Select one PDF to use this tool."
            return nil
        }
        return targets[0]
    }

    private func performPDFOperation(
        title: String,
        detail: String,
        operation: @escaping () async throws -> URL
    ) {
        let activityID = addActivity(title: title, detail: detail)
        let task = Task {
            updateActivity(activityID) { activity in
                activity.status = .running
                activity.bytesTotal = 1_000
                activity.progressDetail = "Preparing PDF"
            }
            do {
                let output = try await operation()
                updateActivity(activityID) { activity in
                    activity.status = .completed
                    activity.finishedAt = Date()
                    activity.bytesCompleted = activity.bytesTotal
                    activity.detail = output.lastPathComponent
                    activity.progressDetail = nil
                }
                activePane.selection = [output.path]
            } catch is CancellationError {
                updateActivity(activityID) { activity in
                    activity.status = .cancelled
                    activity.finishedAt = Date()
                }
            } catch {
                updateActivity(activityID) { activity in
                    activity.status = .failed(error.localizedDescription)
                    activity.finishedAt = Date()
                }
                lastError = error.localizedDescription
            }
            activityTasks[activityID] = nil
            pausedActivityIDs.remove(activityID)
            panes.forEach { $0.refresh() }
        }
        activityTasks[activityID] = task
    }

    private func runTracked(
        title: String,
        detail: String,
        operation: @escaping () async throws -> FileUndoAction?
    ) {
        runTrackedResult(title: title, detail: detail) {
            if let undo = try await operation() {
                return .undo(undo)
            }
            return .none
        }
    }

    private func runTrackedResult(
        title: String,
        detail: String,
        operation: @escaping () async throws -> FileActivityResult
    ) {
        let activityID = addActivity(title: title, detail: detail)
        let task = Task {
            updateActivity(activityID) { activity in
                activity.status = .running
            }
            do {
                let result = try await operation()
                if let undo = result.undoAction {
                    undoStack.append(undo)
                }
                let revealURLs = result.revealURLs.isEmpty
                    ? defaultRevealURLs(for: result.undoAction)
                    : result.revealURLs
                updateActivity(activityID) { activity in
                    activity.status = .completed
                    activity.finishedAt = Date()
                    activity.bytesCompleted = activity.bytesTotal
                    activity.undoAction = result.undoAction
                    activity.revealURLs = revealURLs
                    if let completionDetail = result.completionDetail {
                        activity.progressDetail = completionDetail
                    }
                }
            } catch is CancellationError {
                updateActivity(activityID) { activity in
                    activity.status = .cancelled
                    activity.finishedAt = Date()
                }
            } catch {
                updateActivity(activityID) { activity in
                    activity.status = .failed(error.localizedDescription)
                    activity.finishedAt = Date()
                }
                lastError = error.localizedDescription
            }
            activityTasks[activityID] = nil
            panes.forEach { $0.refresh() }
        }
        activityTasks[activityID] = task
    }

    private func addActivity(
        title: String,
        detail: String,
        supportsConflictPolicy: Bool = false
    ) -> UUID {
        let activity = FileActivity(
            id: UUID(),
            title: title,
            detail: detail,
            bytesCompleted: 0,
            bytesTotal: 0,
            status: .queued,
            startedAt: Date(),
            finishedAt: nil,
            conflictPolicy: fileOperationConflictPolicy,
            supportsConflictPolicy: supportsConflictPolicy,
            progressDetail: nil,
            undoAction: nil,
            revealURLs: []
        )
        fileActivities.insert(activity, at: 0)
        return activity.id
    }

    private func updateActivity(_ id: UUID, mutate: (inout FileActivity) -> Void) {
        guard let index = fileActivities.firstIndex(where: { $0.id == id }) else { return }
        mutate(&fileActivities[index])
    }

    private func operationDetail(for urls: [URL]) -> String {
        if urls.count == 1 {
            return urls[0].lastPathComponent
        }
        return "\(urls.count) items"
    }

    private func defaultRevealURLs(for undoAction: FileUndoAction?) -> [URL] {
        guard let undoAction else { return [] }
        switch undoAction {
        case let .moveBack(_, records):
            return records.map(\.destination)
        case let .putBack(_, records):
            return records.map(\.trashedURL)
        }
    }

    /// Runs a file operation, surfaces any error, and refreshes both panes.
    private func run(_ operation: @escaping () async throws -> Void) {
        Task {
            do {
                try await operation()
            } catch {
                self.lastError = error.localizedDescription
            }
            self.panes.forEach { $0.refresh() }
        }
    }

    private func savePersistentState() {
        let defaults = UserDefaults.standard
        defaults.set(isDualPane, forKey: RestoredFinderState.Key.isDualPane)
        defaults.set(activePaneIndex, forKey: RestoredFinderState.Key.activePaneIndex)
        defaults.set(showHidden, forKey: RestoredFinderState.Key.showHidden)
        defaults.set(
            autoCalculateFolderSizes,
            forKey: RestoredFinderState.Key.autoCalculateFolderSizes
        )
        defaults.set(foldersFirst, forKey: RestoredFinderState.Key.foldersFirst)
        defaults.set(activeToolPanel == .preview, forKey: RestoredFinderState.Key.showPreview)
        for (index, pane) in panes.enumerated() {
            defaults.set(pane.currentURL.path, forKey: RestoredFinderState.Key.url(index))
            defaults.set(pane.viewMode.rawValue, forKey: RestoredFinderState.Key.viewMode(index))
            defaults.set(
                pane.tabs.map { $0.url.path },
                forKey: RestoredFinderState.Key.tabURLs(index)
            )
            defaults.set(
                pane.tabs.map { $0.viewMode.rawValue },
                forKey: RestoredFinderState.Key.tabViewModes(index)
            )
            defaults.set(pane.activeTabIndex, forKey: RestoredFinderState.Key.activeTabIndex(index))
        }
    }
}

private struct RestoredFinderState {
    enum Key {
        static let isDualPane = "finderState.isDualPane"
        static let activePaneIndex = "finderState.activePaneIndex"
        static let showHidden = "finderState.showHidden"
        static let autoCalculateFolderSizes = "finderState.autoCalculateFolderSizes"
        static let foldersFirst = "finderState.foldersFirst"
        static let showPreview = "finderState.showPreview"

        static func url(_ index: Int) -> String {
            "finderState.pane.\(index).url"
        }

        static func viewMode(_ index: Int) -> String {
            "finderState.pane.\(index).viewMode"
        }

        static func tabURLs(_ index: Int) -> String {
            "finderState.pane.\(index).tabURLs"
        }

        static func tabViewModes(_ index: Int) -> String {
            "finderState.pane.\(index).tabViewModes"
        }

        static func activeTabIndex(_ index: Int) -> String {
            "finderState.pane.\(index).activeTabIndex"
        }
    }

    let activePaneIndex: Int
    let isDualPane: Bool
    let showHidden: Bool
    let autoCalculateFolderSizes: Bool
    let foldersFirst: Bool
    let showPreview: Bool
    let paneTabs: [[PaneTab]]
    let activeTabIndexes: [Int]

    init(home: URL) {
        let defaults = UserDefaults.standard
        activePaneIndex = Self.clampedPaneIndex(
            defaults.object(forKey: Key.activePaneIndex) as? Int ?? 0
        )
        isDualPane = defaults.object(forKey: Key.isDualPane) as? Bool ?? true
        showHidden = defaults.object(forKey: Key.showHidden) as? Bool ?? false
        autoCalculateFolderSizes =
            defaults.object(forKey: Key.autoCalculateFolderSizes) as? Bool ?? false
        foldersFirst = defaults.object(forKey: Key.foldersFirst) as? Bool ?? true
        showPreview = defaults.object(forKey: Key.showPreview) as? Bool ?? false
        let restoredPaneTabs = (0..<2).map {
            Self.restoredTabs(for: $0, home: home, defaults: defaults)
        }
        paneTabs = restoredPaneTabs
        activeTabIndexes = (0..<2).map { index in
            let value = defaults.object(forKey: Key.activeTabIndex(index)) as? Int ?? 0
            return min(max(value, 0), max(restoredPaneTabs[index].count - 1, 0))
        }
    }

    private static func clampedPaneIndex(_ index: Int) -> Int {
        (0..<2).contains(index) ? index : 0
    }

    private static func restoredURL(for index: Int, home: URL, defaults: UserDefaults) -> URL {
        guard let path = defaults.string(forKey: Key.url(index)), !path.isEmpty else {
            return home
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return url
        }
        return home
    }

    private static func restoredViewMode(for index: Int, defaults: UserDefaults) -> PaneViewMode {
        guard let rawValue = defaults.string(forKey: Key.viewMode(index)),
              let mode = PaneViewMode(rawValue: rawValue) else {
            return .list
        }
        return mode
    }

    private static func restoredTabs(
        for index: Int,
        home: URL,
        defaults: UserDefaults
    ) -> [PaneTab] {
        let paths = defaults.stringArray(forKey: Key.tabURLs(index)) ?? []
        let modeRawValues = defaults.stringArray(forKey: Key.tabViewModes(index)) ?? []
        let tabs = paths.enumerated().compactMap { offset, path -> PaneTab? in
            guard let url = validDirectoryURL(path: path) else { return nil }
            let mode: PaneViewMode
            if offset < modeRawValues.count, let restoredMode = PaneViewMode(rawValue: modeRawValues[offset]) {
                mode = restoredMode
            } else {
                mode = .list
            }
            return PaneTab(url: url, viewMode: mode)
        }
        if !tabs.isEmpty {
            return tabs
        }
        return [PaneTab(
            url: restoredURL(for: index, home: home, defaults: defaults),
            viewMode: restoredViewMode(for: index, defaults: defaults)
        )]
    }

    private static func validDirectoryURL(path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return url
    }
}
