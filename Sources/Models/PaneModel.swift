import AppKit
import Foundation
import Observation

enum PaneViewMode: String, CaseIterable, Identifiable {
    case list = "List"
    case icons = "Icons"
    case columns = "Columns"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .list: "list.bullet"
        case .icons: "square.grid.2x2"
        case .columns: "rectangle.split.3x1"
        }
    }
}

enum ModifiedDateFilter: String, Identifiable, Sendable {
    case all
    case withinHour
    case today
    case withinWeek
    case withinMonth
    case olderThanOneYear
    case olderThanTwoYears

    var id: Self { self }

    var shortTitle: String {
        switch self {
        case .all: "All"
        case .withinHour: "HOUR"
        case .today: "TODAY"
        case .withinWeek: "WEEK"
        case .withinMonth: "MONTH"
        case .olderThanOneYear: "+1YR"
        case .olderThanTwoYears: "+2YRs"
        }
    }

    var helpText: String {
        switch self {
        case .all: "All creation and modification dates"
        case .withinHour: "Created or modified within the last hour"
        case .today: "Created or modified within the last 24 hours"
        case .withinWeek: "Created or modified within the last 7 days"
        case .withinMonth: "Created or modified within the last month"
        case .olderThanOneYear: "Created or modified more than 1 year ago"
        case .olderThanTwoYears: "Created or modified more than 2 years ago"
        }
    }

    func matches(
        created: Date,
        modified: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        matches(date: created, now: now, calendar: calendar)
            || matches(date: modified, now: now, calendar: calendar)
    }

    func matches(
        modified: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        matches(date: modified, now: now, calendar: calendar)
    }

    private func matches(
        date: Date,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        switch self {
        case .all:
            return true
        case .withinHour:
            guard let cutoff = calendar.date(byAdding: .hour, value: -1, to: now) else { return false }
            return date >= cutoff && date <= now
        case .today:
            guard let cutoff = calendar.date(byAdding: .hour, value: -24, to: now) else { return false }
            return date >= cutoff && date <= now
        case .withinWeek:
            guard let cutoff = calendar.date(byAdding: .day, value: -7, to: now) else { return false }
            return date >= cutoff && date <= now
        case .withinMonth:
            guard let cutoff = calendar.date(byAdding: .month, value: -1, to: now) else { return false }
            return date >= cutoff && date <= now
        case .olderThanOneYear:
            guard let cutoff = calendar.date(byAdding: .year, value: -1, to: now) else { return false }
            return date < cutoff
        case .olderThanTwoYears:
            guard let cutoff = calendar.date(byAdding: .year, value: -2, to: now) else { return false }
            return date < cutoff
        }
    }
}

enum FileSizeFilter: String, Identifiable, Sendable {
    case all
    case upToOneMegabyte
    case oneToTenMegabytes
    case tenToHundredMegabytes
    case hundredMegabytesToOneGigabyte
    case oneGigabyteOrLarger

    var id: Self { self }

    var shortTitle: String {
        switch self {
        case .all: "All"
        case .upToOneMegabyte: "~1MB"
        case .oneToTenMegabytes: "~10MB"
        case .tenToHundredMegabytes: "~100MB"
        case .hundredMegabytesToOneGigabyte: "~1GB"
        case .oneGigabyteOrLarger: ">1GB"
        }
    }

    var helpText: String {
        switch self {
        case .all: "All file sizes"
        case .upToOneMegabyte: "Files around 1 MB (512 KB to 1.5 MB)"
        case .oneToTenMegabytes: "Files around 10 MB (5 MB to 15 MB)"
        case .tenToHundredMegabytes: "Files around 100 MB (50 MB to 150 MB)"
        case .hundredMegabytesToOneGigabyte: "Files and folders 400 MB or larger"
        case .oneGigabyteOrLarger: "Files larger than 1 GB"
        }
    }

    func matches(size: Int64) -> Bool {
        let megabyte: Int64 = 1_024 * 1_024
        let gigabyte = megabyte * 1_024
        guard size >= 0 else { return false }

        return switch self {
        case .all:
            true
        case .upToOneMegabyte:
            size >= megabyte / 2 && size <= megabyte * 3 / 2
        case .oneToTenMegabytes:
            size >= megabyte * 5 && size <= megabyte * 15
        case .tenToHundredMegabytes:
            size >= megabyte * 50 && size <= megabyte * 150
        case .hundredMegabytesToOneGigabyte:
            size >= megabyte * 400
        case .oneGigabyteOrLarger:
            size > gigabyte
        }
    }
}

enum ItemKindFilter: String, Identifiable, Sendable {
    case all
    case files
    case folders

    var id: Self { self }

    var shortTitle: String {
        switch self {
        case .all: "All"
        case .files: "FILE"
        case .folders: "FOLDER"
        }
    }

    var helpText: String {
        switch self {
        case .all: "Show files and folders"
        case .files: "Show files only"
        case .folders: "Show folders only. With a size filter, only folders containing a matching file are shown."
        }
    }

    func matches(isDirectory: Bool) -> Bool {
        switch self {
        case .all: true
        case .files: !isDirectory
        case .folders: isDirectory
        }
    }
}

struct PaneTab: Identifiable, Hashable {
    let id: UUID
    var url: URL
    var viewMode: PaneViewMode
    var backStack: [URL]
    var forwardStack: [URL]
    var filterText: String
    var typePreset: FileTypePreset
    var ratingFilter: StarRatingFilter
    var modifiedDateFilter: ModifiedDateFilter
    var fileSizeFilter: FileSizeFilter
    var itemKindFilter: ItemKindFilter
    var searchSubfolders: Bool

    init(
        id: UUID = UUID(),
        url: URL,
        viewMode: PaneViewMode = .list,
        backStack: [URL] = [],
        forwardStack: [URL] = [],
        filterText: String = "",
        typePreset: FileTypePreset = .all,
        ratingFilter: StarRatingFilter = .all,
        modifiedDateFilter: ModifiedDateFilter = .all,
        fileSizeFilter: FileSizeFilter = .all,
        itemKindFilter: ItemKindFilter = .all,
        searchSubfolders: Bool = false
    ) {
        self.id = id
        self.url = url
        self.viewMode = viewMode
        self.backStack = backStack
        self.forwardStack = forwardStack
        self.filterText = filterText
        self.typePreset = typePreset
        self.ratingFilter = ratingFilter
        self.modifiedDateFilter = modifiedDateFilter
        self.fileSizeFilter = fileSizeFilter
        self.itemKindFilter = itemKindFilter
        self.searchSubfolders = searchSubfolders
    }

    var title: String {
        url.path == "/" ? "Macintosh HD" : url.lastPathComponent
    }
}

/// State for one browser pane: current folder, listing, history, sort, filter,
/// selection, and recursive search.
@Observable
@MainActor
final class PaneModel {
    var currentURL: URL {
        didSet { activeBrowsingStateChanged() }
    }
    var viewMode: PaneViewMode = .list {
        didSet { activeBrowsingStateChanged() }
    }
    var items: [FileItem] = [] {
        didSet {
            if !isUpdatingFolderSize {
                scheduleSizeFilteredFolderScan()
            }
            rebuildDisplayItems()
        }
    }
    var selection = Set<FileItem.ID>() {
        didSet { rebuildSelectedItems() }
    }
    var sortOrder: [KeyPathComparator<FileItem>] = [KeyPathComparator(\.name)] {
        didSet { rebuildDisplayItems() }
    }
    var showHidden = false {
        didSet {
            scheduleSizeFilteredFolderScan()
            rebuildDisplayItems()
        }
    }
    var foldersFirst = true { didSet { rebuildDisplayItems() } }
    var autoCalculateFolderSizes = false {
        didSet {
            if autoCalculateFolderSizes {
                calculateAllFolderSizes()
            } else {
                cancelFolderSizeCalculation()
            }
        }
    }
    var isLoading = false
    var loadError: String?
    var needsAccessGrant = false
    var isCalculatingFolderSizes = false

    var filterText = "" { didSet { searchCriteriaChanged() } }
    var typePreset: FileTypePreset = .all { didSet { searchCriteriaChanged() } }
    var ratingFilter: StarRatingFilter = .all { didSet { searchCriteriaChanged() } }
    var modifiedDateFilter: ModifiedDateFilter = .all { didSet { searchCriteriaChanged() } }
    var fileSizeFilter: FileSizeFilter = .all { didSet { searchCriteriaChanged() } }
    var itemKindFilter: ItemKindFilter = .all { didSet { itemKindFilterChanged() } }
    var searchSubfolders = false { didSet { searchCriteriaChanged() } }
    var searchResults: [FileItem] = [] { didSet { rebuildDisplayItems() } }
    var isSearching = false
    private var searchTask: Task<Void, Never>?
    private var duplicateResults: [FileItem] = []
    private(set) var duplicateResultsTitle: String?
    private(set) var tabs: [PaneTab]
    private(set) var activeTabID: PaneTab.ID
    private(set) var compareMarkers: [FileItem.ID: FolderCompareMarker] = [:]
    private(set) var compareTitle: String?

    /// Sorted + filtered rows for display. Stored, not computed: SwiftUI reads
    /// this many times per render, so it's rebuilt only when an input changes.
    private(set) var displayItems: [FileItem] = []
    /// Selected rows resolved once when selection or listing changes, not during every render.
    private(set) var selectedItems: [FileItem] = []
    /// Volume free space, refreshed once per folder load instead of per render.
    private(set) var freeSpaceText: String?

    @ObservationIgnored private var visibleItemsByID: [FileItem.ID: FileItem] = [:]
    @ObservationIgnored var persistentStateChanged: (() -> Void)?
    @ObservationIgnored private var folderSizeTask: Task<Void, Never>?
    @ObservationIgnored private var folderSizeRunID = UUID()
    @ObservationIgnored private var sizeFilteredFolderScanTask: Task<Void, Never>?
    @ObservationIgnored private var sizeFilteredFolderScanRunID = UUID()
    @ObservationIgnored private var sizeMatchingFolderIDs = Set<FileItem.ID>()
    @ObservationIgnored private var isUpdatingFolderSize = false
    @ObservationIgnored private var isApplyingTabState = false

    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var hasLoaded = false

    init(url: URL, viewMode: PaneViewMode = .list) {
        let tab = PaneTab(url: url, viewMode: viewMode)
        self.tabs = [tab]
        self.activeTabID = tab.id
        self.currentURL = url
        self.viewMode = viewMode
    }

    init(tabs restoredTabs: [PaneTab], activeTabIndex: Int = 0) {
        let usableTabs = restoredTabs.isEmpty
            ? [PaneTab(url: FileManager.default.homeDirectoryForCurrentUser)]
            : restoredTabs
        let index = min(max(activeTabIndex, 0), usableTabs.count - 1)
        let activeTab = usableTabs[index]
        self.tabs = usableTabs
        self.activeTabID = activeTab.id
        self.currentURL = activeTab.url
        self.viewMode = activeTab.viewMode
        self.backStack = activeTab.backStack
        self.forwardStack = activeTab.forwardStack
        self.filterText = activeTab.filterText
        self.typePreset = activeTab.typePreset
        self.ratingFilter = activeTab.ratingFilter
        self.modifiedDateFilter = activeTab.modifiedDateFilter
        self.fileSizeFilter = activeTab.fileSizeFilter
        self.itemKindFilter = activeTab.itemKindFilter
        self.searchSubfolders = activeTab.searchSubfolders
    }

    /// True when the pane is showing recursive search results instead of a folder listing.
    var isRecursiveSearchActive: Bool {
        !isDuplicateResultsActive && searchSubfolders && !filterText.isEmpty
    }

    var isDuplicateResultsActive: Bool {
        duplicateResultsTitle != nil
    }

    var isCompareActive: Bool {
        compareTitle != nil
    }

    /// The collection the table's selection IDs refer to.
    var visibleSource: [FileItem] {
        if isDuplicateResultsActive { return duplicateResults }
        return isRecursiveSearchActive ? searchResults : items
    }

    private func rebuildDisplayItems() {
        var out: [FileItem]
        if isDuplicateResultsActive {
            out = duplicateResults
            if !filterText.isEmpty {
                out = out.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
            }
            if typePreset != .all {
                out = out.filter { typePreset.matches($0) }
            }
            if ratingFilter != .all {
                out = out.filter { ratingFilter.matches($0) }
            }
        } else if isRecursiveSearchActive {
            out = searchResults
            if ratingFilter != .all {
                out = out.filter { ratingFilter.matches($0) }
            }
        } else {
            out = items
            if !showHidden {
                out = out.filter { !$0.isHidden }
            }
            if !filterText.isEmpty {
                out = out.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
            }
            if typePreset != .all {
                // Keep folders visible while browsing so navigation still works.
                out = out.filter { $0.isDirectory || typePreset.matches($0) }
            }
            if ratingFilter != .all {
                out = out.filter { ratingFilter.matches($0) }
            }
        }
        if modifiedDateFilter != .all {
            out = out.filter {
                modifiedDateFilter.matches(created: $0.created, modified: $0.modified)
            }
        }
        if itemKindFilter != .all {
            out = out.filter { itemKindFilter.matches(isDirectory: $0.isDirectory) }
        }
        if fileSizeFilter != .all {
            out = out.filter { item in
                if item.isDirectory {
                    if itemKindFilter == .folders {
                        return fileSizeFilter.matches(size: item.size)
                    }
                    return !isRecursiveSearchActive && sizeMatchingFolderIDs.contains(item.id)
                }
                return fileSizeFilter.matches(size: item.size)
            }
        }
        out.sort(using: sortOrder)
        if foldersFirst {
            out = out.filter(\.isDirectory) + out.filter { !$0.isDirectory }
        }
        visibleItemsByID = Dictionary(uniqueKeysWithValues: out.map { ($0.id, $0) })
        displayItems = out
        rebuildSelectedItems()
    }

    private func rebuildSelectedItems() {
        if selection.count <= 1 {
            selectedItems = selection.compactMap { visibleItemsByID[$0] ?? Self.itemIfReachable(id: $0) }
        } else {
            let visible = visibleSource.filter { selection.contains($0.id) }
            let visibleIDs = Set(visible.map(\.id))
            let missing = selection.subtracting(visibleIDs).compactMap(Self.itemIfReachable)
            selectedItems = visible + missing
        }
    }

    func dateMatchCount(for filter: ModifiedDateFilter, now: Date = Date()) -> Int {
        visibleSource.lazy.filter { item in
            !item.isDirectory
                && (self.showHidden || !item.isHidden)
                && filter.matches(created: item.created, modified: item.modified, now: now)
        }.count
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { currentURL.standardizedFileURL.path != "/" }
    var activeTabIndex: Int {
        tabs.firstIndex { $0.id == activeTabID } ?? 0
    }

    // MARK: - Navigation

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        load()
    }

    func navigate(to url: URL) {
        guard url.standardizedFileURL != currentURL.standardizedFileURL else {
            refresh()
            return
        }
        resetDuplicateResults()
        resetCompare()
        backStack.append(currentURL)
        forwardStack.removeAll()
        currentURL = url
        selection.removeAll()
        filterText = ""
        searchSubfolders = false
        load()
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        resetDuplicateResults()
        resetCompare()
        forwardStack.append(currentURL)
        currentURL = previous
        selection.removeAll()
        load()
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        resetDuplicateResults()
        resetCompare()
        backStack.append(currentURL)
        currentURL = next
        selection.removeAll()
        load()
    }

    func goUp() {
        guard canGoUp else { return }
        navigate(to: currentURL.deletingLastPathComponent().standardizedFileURL)
    }

    @discardableResult
    func goToFolder(path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let expanded = (trimmed as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        navigate(to: URL(fileURLWithPath: expanded, isDirectory: true))
        return true
    }

    func refresh() {
        resetDuplicateResults()
        resetCompare()
        load()
    }

    // MARK: - Tabs

    func newTab(at url: URL? = nil) {
        syncActiveTabState()
        let tab = PaneTab(url: (url ?? currentURL).standardizedFileURL, viewMode: viewMode)
        tabs.append(tab)
        selectTab(tab.id)
    }

    func closeCurrentTab() {
        closeTab(activeTabID)
    }

    func closeTab(_ id: PaneTab.ID) {
        guard tabs.count > 1, let closingIndex = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }

        let wasActive = id == activeTabID
        var nextID: PaneTab.ID?
        if wasActive {
            let fallbackIndex = closingIndex == tabs.count - 1 ? closingIndex - 1 : closingIndex + 1
            nextID = tabs[fallbackIndex].id
        }
        tabs.remove(at: closingIndex)

        if let nextID {
            selectTab(nextID)
        } else {
            persistentStateChanged?()
        }
    }

    func selectTab(_ id: PaneTab.ID) {
        guard let tab = tabs.first(where: { $0.id == id }), id != activeTabID else { return }
        syncActiveTabState()
        activeTabID = id
        apply(tab: tab)
    }

    func selectNextTab() {
        guard tabs.count > 1 else { return }
        let nextIndex = (activeTabIndex + 1) % tabs.count
        selectTab(tabs[nextIndex].id)
    }

    func selectPreviousTab() {
        guard tabs.count > 1 else { return }
        let previousIndex = (activeTabIndex - 1 + tabs.count) % tabs.count
        selectTab(tabs[previousIndex].id)
    }

    private func apply(tab: PaneTab) {
        searchTask?.cancel()
        cancelFolderSizeCalculation()
        isApplyingTabState = true
        currentURL = tab.url
        viewMode = tab.viewMode
        filterText = tab.filterText
        typePreset = tab.typePreset
        ratingFilter = tab.ratingFilter
        modifiedDateFilter = tab.modifiedDateFilter
        fileSizeFilter = tab.fileSizeFilter
        itemKindFilter = tab.itemKindFilter
        searchSubfolders = tab.searchSubfolders
        backStack = tab.backStack
        forwardStack = tab.forwardStack
        selection.removeAll()
        searchResults = []
        isSearching = false
        resetDuplicateResults()
        resetCompare()
        isApplyingTabState = false
        persistentStateChanged?()
        searchStateChanged()
        rebuildDisplayItems()
        load()
    }

    private func searchCriteriaChanged() {
        guard !isApplyingTabState else { return }
        syncActiveTabState()
        scheduleSizeFilteredFolderScan()
        searchStateChanged()
        rebuildDisplayItems()
    }

    private func itemKindFilterChanged() {
        guard !isApplyingTabState else { return }
        syncActiveTabState()
        scheduleSizeFilteredFolderScan()
        rebuildDisplayItems()
    }

    private func activeBrowsingStateChanged() {
        guard !isApplyingTabState else { return }
        syncActiveTabState()
        persistentStateChanged?()
    }

    private func syncActiveTabState() {
        guard !tabs.isEmpty,
              let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        tabs[index].url = currentURL
        tabs[index].viewMode = viewMode
        tabs[index].backStack = backStack
        tabs[index].forwardStack = forwardStack
        tabs[index].filterText = filterText
        tabs[index].typePreset = typePreset
        tabs[index].ratingFilter = ratingFilter
        tabs[index].modifiedDateFilter = modifiedDateFilter
        tabs[index].fileSizeFilter = fileSizeFilter
        tabs[index].itemKindFilter = itemKindFilter
        tabs[index].searchSubfolders = searchSubfolders
    }

    /// Double-click / ⌘↓: descend into a single folder, otherwise open with default apps.
    func open(_ ids: Set<FileItem.ID>) {
        let targets = resolvedItems(ids)
        if targets.count == 1, let only = targets.first, only.isDirectory {
            navigate(to: only.url)
        } else {
            for item in targets {
                NSWorkspace.shared.open(item.url)
            }
        }
    }

    func resolvedItems(_ ids: Set<FileItem.ID>) -> [FileItem] {
        let visible = visibleSource.filter { ids.contains($0.id) }
        let visibleIDs = Set(visible.map(\.id))
        let missing = ids.subtracting(visibleIDs).compactMap(Self.itemIfReachable)
        return visible + missing
    }

    nonisolated static func itemIfReachable(id: FileItem.ID) -> FileItem? {
        guard !id.isEmpty else { return nil }
        let url = URL(fileURLWithPath: id).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return FileItem.make(url: url)
    }

    // MARK: - Listing

    func load() {
        resetDuplicateResults()
        resetCompare()
        let url = currentURL
        cancelFolderSizeCalculation()
        isLoading = true
        loadError = nil
        needsAccessGrant = false
        Task {
            do {
                let listed = try await Self.list(directory: url)
                let freeSpace = await Self.freeSpace(for: url)
                guard url == self.currentURL else { return }
                self.items = listed
                self.freeSpaceText = freeSpace
                self.isLoading = false
                self.calculateAllFolderSizes()
            } catch {
                guard url == self.currentURL else { return }
                self.items = []
                self.isLoading = false
                let nsError = error as NSError
                let permissionCodes = [NSFileReadNoPermissionError, NSFileReadUnknownError]
                if nsError.domain == NSCocoaErrorDomain && permissionCodes.contains(nsError.code) {
                    self.needsAccessGrant = true
                } else {
                    self.loadError = error.localizedDescription
                }
            }
        }
    }

    nonisolated private static func freeSpace(for url: URL) async -> String? {
        guard let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let capacity = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file)
    }

    nonisolated private static func list(directory: URL) async throws -> [FileItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: FileItem.resourceKeys, options: []
        )
        return urls.map { FileItem.make(url: $0) }
    }

    nonisolated static func folderContainsMatchingFile(
        in folder: URL,
        filter: FileSizeFilter,
        includeHidden: Bool
    ) async throws -> Bool {
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: options
        ) else {
            return false
        }

        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            guard values?.isDirectory != true,
                  let size = values?.fileSize else {
                continue
            }
            if filter.matches(size: Int64(size)) {
                return true
            }
        }
        return false
    }

    private func scheduleSizeFilteredFolderScan() {
        sizeFilteredFolderScanTask?.cancel()
        sizeFilteredFolderScanTask = nil
        let runID = UUID()
        sizeFilteredFolderScanRunID = runID
        sizeMatchingFolderIDs.removeAll()

        guard fileSizeFilter != .all,
              !isRecursiveSearchActive,
              itemKindFilter == .all else {
            return
        }
        let folders = items.filter(\.isDirectory)
        guard !folders.isEmpty else { return }

        let filter = fileSizeFilter
        let includeHidden = showHidden
        let loadedURL = currentURL
        sizeFilteredFolderScanTask = Task { [weak self] in
            var matchingIDs = Set<FileItem.ID>()

            for folder in folders {
                guard !Task.isCancelled else { return }
                do {
                    if try await Self.folderContainsMatchingFile(
                        in: folder.url,
                        filter: filter,
                        includeHidden: includeHidden
                    ) {
                        matchingIDs.insert(folder.id)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    continue
                }

            }

            guard let self,
                  !Task.isCancelled,
                  self.sizeFilteredFolderScanRunID == runID,
                  self.currentURL == loadedURL else {
                return
            }
            self.sizeMatchingFolderIDs = matchingIDs
            self.rebuildDisplayItems()
            self.sizeFilteredFolderScanTask = nil
        }
    }

    // MARK: - Recursive search

    private func searchStateChanged() {
        searchTask?.cancel()
        if isDuplicateResultsActive {
            searchResults = []
            isSearching = false
            rebuildDisplayItems()
            return
        }
        guard isRecursiveSearchActive else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        let root = currentURL
        let query = filterText
        let preset = typePreset
        let ratingFilter = ratingFilter
        let modifiedDateFilter = modifiedDateFilter
        let fileSizeFilter = fileSizeFilter
        let includeHidden = showHidden
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let results = await Self.search(
                root: root,
                query: query,
                preset: preset,
                ratingFilter: ratingFilter,
                modifiedDateFilter: modifiedDateFilter,
                fileSizeFilter: fileSizeFilter,
                includeHidden: includeHidden
            )
            guard !Task.isCancelled else { return }
            self.searchResults = results
            self.isSearching = false
        }
    }

    nonisolated private static func search(
        root: URL,
        query: String,
        preset: FileTypePreset,
        ratingFilter: StarRatingFilter,
        modifiedDateFilter: ModifiedDateFilter,
        fileSizeFilter: FileSizeFilter,
        includeHidden: Bool
    ) async -> [FileItem] {
        let maxResults = 2000
        var results: [FileItem] = []
        let options: FileManager.DirectoryEnumerationOptions =
            includeHidden ? [] : [.skipsHiddenFiles]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: FileItem.resourceKeys, options: options
        ) else { return [] }
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { return results }
            guard url.lastPathComponent.localizedCaseInsensitiveContains(query) else { continue }
            let item = FileItem.make(url: url)
            guard preset.matches(item) else { continue }
            guard ratingFilter.matches(item) else { continue }
            guard modifiedDateFilter.matches(created: item.created, modified: item.modified) else { continue }
            if fileSizeFilter != .all {
                guard !item.isDirectory, fileSizeFilter.matches(size: item.size) else { continue }
            }
            results.append(item)
            if results.count >= maxResults { break }
        }
        return results
    }

    // MARK: - Duplicate results

    func showDuplicateResults(_ results: [FileItem], title: String) {
        searchTask?.cancel()
        resetCompare()
        searchResults = []
        isSearching = false
        selection.removeAll()
        filterText = ""
        searchSubfolders = false
        typePreset = .all
        ratingFilter = .all
        modifiedDateFilter = .all
        fileSizeFilter = .all
        itemKindFilter = .all
        duplicateResultsTitle = title
        duplicateResults = results
        rebuildDisplayItems()
    }

    func updateRating(for ids: Set<FileItem.ID>, rating: Int) {
        guard !ids.isEmpty else { return }
        updateRating(in: &items, ids: ids, rating: rating)
        updateRating(in: &searchResults, ids: ids, rating: rating)
        updateRating(in: &duplicateResults, ids: ids, rating: rating)
        rebuildDisplayItems()
    }

    private func updateRating(in list: inout [FileItem], ids: Set<FileItem.ID>, rating: Int) {
        for index in list.indices where ids.contains(list[index].id) {
            list[index].rating = rating
        }
    }

    func clearDuplicateResults() {
        guard isDuplicateResultsActive else { return }
        resetDuplicateResults()
        selection.removeAll()
        rebuildDisplayItems()
    }

    private func resetDuplicateResults() {
        duplicateResultsTitle = nil
        duplicateResults = []
    }

    // MARK: - Folder compare

    func showCompare(markers: [FileItem.ID: FolderCompareMarker], title: String) {
        compareMarkers = markers
        compareTitle = title
    }

    func clearCompare() {
        guard isCompareActive else { return }
        resetCompare()
    }

    func compareMarker(for item: FileItem) -> FolderCompareMarker? {
        compareMarkers[item.id]
    }

    private func resetCompare() {
        compareMarkers = [:]
        compareTitle = nil
    }

    // MARK: - Folder sizes

    func calculateSizes(_ ids: Set<FileItem.ID>) {
        calculateFolderSizes(resolvedItems(ids).filter(\.isDirectory))
    }

    private func calculateAllFolderSizes() {
        guard autoCalculateFolderSizes else { return }
        calculateFolderSizes(items.filter(\.isDirectory))
    }

    private func calculateFolderSizes(_ folders: [FileItem]) {
        folderSizeTask?.cancel()
        let runID = UUID()
        folderSizeRunID = runID
        guard !folders.isEmpty else {
            isCalculatingFolderSizes = false
            return
        }

        isCalculatingFolderSizes = true
        let loadedURL = currentURL
        folderSizeTask = Task {
            for (folderOffset, folder) in folders.enumerated() {
                if folderOffset > 0 {
                    do {
                        try await Task.sleep(for: .seconds(2))
                    } catch is CancellationError {
                        break
                    } catch {
                        break
                    }
                }
                guard !Task.isCancelled,
                      folderSizeRunID == runID,
                      loadedURL == currentURL else { break }
                do {
                    let total = try await Self.folderSize(folder.url)
                    guard !Task.isCancelled,
                          folderSizeRunID == runID,
                          loadedURL == currentURL,
                          let index = items.firstIndex(where: { $0.id == folder.id }) else {
                        break
                    }
                    isUpdatingFolderSize = true
                    items[index].size = total
                    isUpdatingFolderSize = false
                } catch is CancellationError {
                    break
                } catch {
                    continue
                }
            }

            if folderSizeRunID == runID {
                isCalculatingFolderSizes = false
                folderSizeTask = nil
            }
        }
    }

    private func cancelFolderSizeCalculation() {
        folderSizeRunID = UUID()
        folderSizeTask?.cancel()
        folderSizeTask = nil
        isCalculatingFolderSizes = false
    }

    nonisolated private static func folderSize(_ url: URL) async throws -> Int64 {
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]
        )
        while let entry = enumerator?.nextObject() as? URL {
            try Task.checkCancellation()
            total += Int64((try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0)
        }
        return total
    }
}
