import AppKit
import Foundation
import Observation

/// App-wide state: the two panes, which one is active, global toggles, and the
/// entry points that menu commands and toolbar buttons call.
@Observable
@MainActor
final class AppState {
    static let shared = AppState()

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

    var lastError: String?
    var quickLookURL: URL?
    var showNewFolderPrompt = false
    var showGoToPrompt = false
    var renameTarget: FileItem?
    var showPreview = false {
        didSet { savePersistentState() }
    }
    var showResizeSheet = false
    var resizeTargets: [FileItem] = []
    var showBatchRenameSheet = false
    var batchRenameTargets: [FileItem] = []
    var showConvertSheet = false
    var convertTargets: [FileItem] = []
    var showSlideshowSheet = false
    var slideshowTargets: [FileItem] = []
    var showScreenshotSheet = false
    var showNotesSheet = false
    /// Non-nil while a slideshow render is in flight (0…1).
    var slideshowProgress: Double?
    private var slideshowTask: Task<Void, Never>?
    var fileActivities: [FileActivity] = []
    var fileOperationConflictPolicy: FileConflictPolicy = .keepBoth
    var undoStack: [FileUndoAction] = []
    @ObservationIgnored private var activityTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pausedActivityIDs = Set<UUID>()
    @ObservationIgnored private var lastFolderCompareResult: FolderCompareResult?
    @ObservationIgnored private var lastFolderCompareLeftURL: URL?
    @ObservationIgnored private var lastFolderCompareRightURL: URL?
    /// Incremented by the ⌘F command; the active pane's search field focuses on change.
    var searchFocusTick = 0

    var activePane: PaneModel { panes[activePaneIndex] }
    var inactivePane: PaneModel { panes[activePaneIndex == 0 ? 1 : 0] }
    var canUndoFileOperation: Bool { !undoStack.isEmpty }
    var undoFileOperationTitle: String {
        undoStack.last.map { "Undo \($0.title)" } ?? "Undo"
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
        showPreview = restored.showPreview
        panes.forEach { pane in
            pane.showHidden = showHidden
            pane.autoCalculateFolderSizes = autoCalculateFolderSizes
            pane.persistentStateChanged = { [weak self] in
                self?.savePersistentState()
            }
        }
        savePersistentState()
    }

    func toggleDualPane() {
        isDualPane.toggle()
        if !isDualPane { activePaneIndex = 0 }
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
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            lastError = "No folder found at “\(path)”."
            return
        }
        activePane.navigate(to: URL(fileURLWithPath: expanded))
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
        showScreenshotSheet = true
    }

    func showNotes() {
        showNotesSheet = true
    }

    func performScreenshot(options: ScreenshotOptions) {
        let destinationFolder = activePane.currentURL
        showScreenshotSheet = false
        let activityID = addActivity(title: "Screenshot", detail: options.mode.title)
        let task = Task {
            updateActivity(activityID) { activity in
                activity.status = .running
                if options.delay > 0 {
                    activity.progressDetail = "\(options.delay)s delay"
                } else if options.mode == .interactive || options.mode == .selection || options.mode == .window {
                    activity.progressDetail = "Waiting for selection"
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
        renameTarget = activePane.selectedItems.first
    }

    func beginBatchRename(_ ids: Set<FileItem.ID>? = nil) {
        let targets = resolvedDisplayItems(ids)
        guard !targets.isEmpty else {
            lastError = "Select one or more files to rename."
            return
        }
        batchRenameTargets = targets
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

    func rename(_ item: FileItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        runTracked(title: "Rename", detail: item.name) {
            let record = try await FileOperations.rename(item.url, to: trimmed)
            return .moveBack(title: "Rename", records: [record])
        }
    }

    func createFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let destination = activePane.currentURL
        runTracked(title: "New Folder", detail: trimmed) {
            try await FileOperations.newFolder(named: trimmed, in: destination)
            return nil
        }
    }

    func duplicateSelection(_ ids: Set<FileItem.ID>? = nil) {
        let urls = resolvedURLs(ids)
        guard !urls.isEmpty else { return }
        runTracked(title: "Duplicate", detail: operationDetail(for: urls)) {
            try await FileOperations.duplicate(urls)
            return nil
        }
    }

    func extractArchive(_ ids: Set<FileItem.ID>? = nil) {
        guard let archive = resolvedItems(ids).first(where: \.isZipArchive) else {
            lastError = "Select a ZIP archive to extract."
            return
        }
        runTracked(title: "Extract ZIP", detail: archive.name) {
            try await FileOperations.extractZip(archive.url)
            return nil
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

    func drop(_ urls: [URL], to destination: URL, paneIndex: Int) -> Bool {
        activePaneIndex = paneIndex
        let filtered = urls.filter { $0.standardizedFileURL != destination.standardizedFileURL }
        guard !filtered.isEmpty else { return false }
        let move = NSEvent.modifierFlags.contains(.command)
        enqueueTransfer(filtered, to: destination, move: move)
        return true
    }

    func beginResize(_ ids: Set<FileItem.ID>? = nil) {
        let images = resolvedItems(ids).filter(\.isImage)
        guard !images.isEmpty else {
            lastError = "Select one or more images to resize."
            return
        }
        resizeTargets = images
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

    func beginConvert(_ ids: Set<FileItem.ID>? = nil) {
        let targets = resolvedDisplayItems(ids).filter(MediaConverter.canConvert)
        guard !targets.isEmpty else {
            lastError = "Select one or more images or videos to convert."
            return
        }
        convertTargets = targets
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
                        await MainActor.run {
                            self?.updateActivity(activityID) { activity in
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

    func exportVideoTrim(_ item: FileItem, inTime: Double, outTime: Double) {
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
            }
            do {
                let output = try await VideoTrimmer.exportLossless(
                    url: item.url,
                    inTime: inTime,
                    outTime: outTime
                ) { [weak self] progress in
                    await MainActor.run {
                        self?.updateActivity(activityID) { activity in
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
        let activityID = addActivity(title: "Sync \(direction.title)", detail: "Comparing folders")
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
                            await MainActor.run {
                                self?.updateActivity(activityID) { activity in
                                    activity.bytesCompleted = completed
                                    activity.bytesTotal = total
                                }
                            }
                        },
                        isPaused: { [weak self] in
                            await MainActor.run {
                                self?.pausedActivityIDs.contains(activityID) == true
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

    func beginSlideshow(_ ids: Set<FileItem.ID>? = nil) {
        let chosen = ids ?? activePane.selection
        // Use display order so the video follows the pane's current sort.
        let images = activePane.displayItems.filter { chosen.contains($0.id) && $0.isImage }
        guard images.count >= 2 else {
            lastError = "Select at least two images to make a slideshow."
            return
        }
        slideshowTargets = images
        showSlideshowSheet = true
    }

    func performSlideshow(options: SlideshowRenderer.Options) {
        let sources = slideshowTargets.map(\.url)
        let destination = FileOperations.uniqueDestination(
            for: activePane.currentURL.appendingPathComponent("Slideshow.mp4")
        )
        slideshowProgress = 0
        slideshowTask = Task {
            do {
                try await SlideshowRenderer.render(
                    images: sources, to: destination, options: options
                ) { value in
                    Task { @MainActor in AppState.shared.slideshowProgress = value }
                }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: destination)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                self.lastError = error.localizedDescription
            }
            self.slideshowProgress = nil
            self.showSlideshowSheet = false
            self.panes.forEach { $0.refresh() }
        }
    }

    func cancelSlideshow() {
        slideshowTask?.cancel()
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

    func copyPathOfSelection(_ ids: Set<FileItem.ID>? = nil) {
        let paths = resolvedURLs(ids).map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    func revealSelectionInFinder(_ ids: Set<FileItem.ID>? = nil) {
        NSWorkspace.shared.activateFileViewerSelecting(resolvedURLs(ids))
    }

    func undoLastFileOperation() {
        guard let action = undoStack.popLast() else {
            NSSound.beep()
            return
        }
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
            return activePane.visibleSource.filter { ids.contains($0.id) }
        }
        return activePane.selectedItems
    }

    private func resolvedDisplayItems(_ ids: Set<FileItem.ID>?) -> [FileItem] {
        let selectedIDs = ids ?? activePane.selection
        return activePane.displayItems.filter { selectedIDs.contains($0.id) }
    }

    private func resolvedURLs(_ ids: Set<FileItem.ID>?) -> [URL] {
        resolvedItems(ids).map(\.url)
    }

    private func enqueueTransfer(_ urls: [URL], to destination: URL, move: Bool) {
        let title = move ? "Move" : "Copy"
        let detail = "\(operationDetail(for: urls)) to \(destination.lastPathComponent)"
        let policy = fileOperationConflictPolicy
        let activityID = addActivity(title: title, detail: detail)
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
                        await MainActor.run {
                            self?.updateActivity(activityID) { activity in
                                activity.bytesCompleted = completed
                                activity.bytesTotal = total
                            }
                        }
                    },
                    isPaused: { [weak self] in
                        await MainActor.run {
                            self?.pausedActivityIDs.contains(activityID) == true
                        }
                    }
                )
                if move, !records.isEmpty {
                    undoStack.append(.moveBack(title: "Move", records: records))
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

    private func runTracked(
        title: String,
        detail: String,
        operation: @escaping () async throws -> FileUndoAction?
    ) {
        let activityID = addActivity(title: title, detail: detail)
        let task = Task {
            updateActivity(activityID) { activity in
                activity.status = .running
            }
            do {
                if let undo = try await operation() {
                    undoStack.append(undo)
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
            panes.forEach { $0.refresh() }
        }
        activityTasks[activityID] = task
    }

    private func addActivity(title: String, detail: String) -> UUID {
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
            progressDetail: nil
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
        defaults.set(showPreview, forKey: RestoredFinderState.Key.showPreview)
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
