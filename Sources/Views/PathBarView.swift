import SwiftUI

/// Back/forward/up controls, clickable breadcrumbs, and the per-pane search field.
struct PathBarView: View {
    @Environment(AppState.self) private var appState
    @Bindable var model: PaneModel
    let isActive: Bool
    @FocusState private var searchFocused: Bool
    @FocusState private var pathFocused: Bool
    @State private var isEditingPath = false
    @State private var editablePath = ""

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                navigationControls
                quickDateFilterStrip
                Divider().frame(height: 14)
                quickSizeFilterStrip
                Divider().frame(height: 14)
                quickItemKindFilterStrip
                Divider().frame(height: 14)
                clearQuickFiltersButton
                Spacer(minLength: 8)
                viewAndSearchControls
            }

            HStack(spacing: 6) {
                pathFilterControls
                Divider()
                    .frame(height: 14)
                pathControls
                resultBadges
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .onChange(of: appState.searchFocusTick) { _, _ in
            if isActive { searchFocused = true }
        }
        .onChange(of: model.currentURL) { _, _ in
            if isEditingPath {
                isEditingPath = false
                pathFocused = false
            }
        }
    }

    private var navigationControls: some View {
        HStack(spacing: 6) {
            navigationButton(
                systemImage: "chevron.left",
                isEnabled: model.canGoBack,
                help: "Back (⌘[)",
                action: model.goBack
            )

            navigationButton(
                systemImage: "chevron.right",
                isEnabled: model.canGoForward,
                help: "Forward (⌘])",
                action: model.goForward
            )

            navigationButton(
                systemImage: "arrow.up",
                isEnabled: model.canGoUp,
                help: "Enclosing Folder (⌘↑)",
                action: model.goUp
            )
        }
    }

    private func navigationButton(
        systemImage: String,
        isEnabled: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 30, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
        .disabled(!isEnabled)
        .help(help)
        .clickableCursor(isEnabled)
    }

    private var pathControls: some View {
        HStack(spacing: 6) {
            Group {
                if isEditingPath {
                    TextField("Path (e.g. ~/Downloads)", text: $editablePath)
                        .textFieldStyle(.plain)
                        .focused($pathFocused)
                        .onSubmit { commitPathEdit() }
                        .onExitCommand { cancelPathEdit() }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(breadcrumbs, id: \.self) { crumb in
                                Button {
                                    model.navigate(to: crumb)
                                } label: {
                                    Text(displayName(for: crumb))
                                        .lineLimit(1)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(
                                    crumb == model.currentURL ? .primary : .secondary
                                )
                                .help("Go to \(displayName(for: crumb))")
                                .clickableCursor()
                                if crumb != breadcrumbs.last {
                                    Image(systemName: "chevron.compact.right")
                                        .foregroundStyle(.tertiary)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                    .defaultScrollAnchor(.leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        beginPathEdit()
                    }
                    .contextMenu {
                        Button("Copy Path") {
                            appState.copyPath(of: model.currentURL)
                        }
                        Button("Edit Path…") {
                            beginPathEdit()
                        }
                    }
                }
            }
            .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)

            Button {
                appState.copyPath(of: model.currentURL)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy path")
            .clickableCursor()

            Button {
                if isEditingPath {
                    commitPathEdit()
                } else {
                    beginPathEdit()
                }
            } label: {
                Image(systemName: isEditingPath ? "return" : "pencil")
            }
            .help(isEditingPath ? "Go to path" : "Edit path")
            .clickableCursor()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pathFilterControls: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("Media Filter", selection: $model.typePreset) {
                    ForEach(FileTypePreset.allCases) { preset in
                        Label(preset.rawValue, systemImage: preset.systemImage)
                            .tag(preset)
                    }
                }
                .pickerStyle(.inline)

                Divider()

                Toggle("Include Subfolders", isOn: $model.searchSubfolders)
            } label: {
                pathFilterLabel(
                    title: "Media Filter",
                    systemImage: "photo.on.rectangle.angled",
                    isActive: mediaFilterActive
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Filter by media type and choose whether to include subfolders")
            .clickableCursor()

            Divider()
                .frame(height: 14)

            Menu {
                Picker("Ratings", selection: $model.ratingFilter) {
                    ForEach(StarRatingFilter.allCases) { filter in
                        Text(filter.rawValue)
                            .tag(filter)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                pathFilterLabel(
                    title: "Ratings",
                    systemImage: "star",
                    isActive: ratingFilterActive
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Filter by rating")
            .clickableCursor()
        }
    }

    private func pathFilterLabel(
        title: String,
        systemImage: String,
        isActive: Bool
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(title)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .font(.caption)
        .foregroundStyle(isActive ? Color.accentColor : Color.primary)
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.10))
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var resultBadges: some View {
        if let title = model.advancedSearchResultsTitle {
            resultBadge(title, systemImage: "magnifyingglass", clear: model.clearAdvancedSearchResults)
        }
        if let title = model.duplicateResultsTitle {
            resultBadge(title, systemImage: "doc.on.doc", clear: model.clearDuplicateResults)
        }
        if let title = model.compareTitle {
            resultBadge(title, systemImage: "rectangle.split.2x1", clear: model.clearCompare)
        }
    }

    private func resultBadge(
        _ title: String,
        systemImage: String,
        clear: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 4) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
            Button(action: clear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear \(title)")
            .clickableCursor()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private var viewAndSearchControls: some View {
        HStack(spacing: 6) {
            Picker("View", selection: $model.viewMode) {
                ForEach(PaneViewMode.allCases) { mode in
                    Image(systemName: mode.systemImage)
                        .tag(mode)
                        .help(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("List, icon, or column view (⌘1 / ⌘2 / ⌘3)")
            .clickableCursor()

            HStack(spacing: 4) {
                TextField(model.searchSubfolders ? "Search" : "Filter", text: $model.filterText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onExitCommand {
                        model.filterText = ""
                        searchFocused = false
                    }

                if model.isSearching {
                    ProgressView()
                        .controlSize(.mini)
                } else if !model.filterText.isEmpty {
                    Button {
                        model.filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Clear filter")
                    .clickableCursor()
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .frame(minWidth: 140, idealWidth: 195, maxWidth: 195)
        }
    }

    private func beginPathEdit() {
        editablePath = pathString(for: model.currentURL)
        isEditingPath = true
        pathFocused = true
    }

    private func commitPathEdit() {
        if model.goToFolder(path: editablePath) {
            isEditingPath = false
            pathFocused = false
        } else {
            appState.lastError = "No folder found at “\(editablePath)”."
        }
    }

    private func cancelPathEdit() {
        isEditingPath = false
        pathFocused = false
    }

    private func pathString(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private var mediaFilterActive: Bool {
        model.typePreset != .all
            || model.searchSubfolders
    }

    private var ratingFilterActive: Bool {
        model.ratingFilter != .all
    }

    private var quickDateFilterStrip: some View {
        let now = Date()
        return HStack(spacing: 3) {
            quickDateFilterButton(.withinHour, count: model.dateMatchCount(for: .withinHour, now: now))
            quickDateFilterButton(.today, count: model.dateMatchCount(for: .today, now: now))
            quickDateFilterButton(.withinWeek, count: model.dateMatchCount(for: .withinWeek, now: now))
            quickDateFilterButton(.withinMonth, count: model.dateMatchCount(for: .withinMonth, now: now))
            quickDateFilterButton(
                .olderThanOneYear,
                count: model.dateMatchCount(for: .olderThanOneYear, now: now)
            )
            quickDateFilterButton(
                .olderThanTwoYears,
                count: model.dateMatchCount(for: .olderThanTwoYears, now: now)
            )
        }
        .fixedSize()
    }

    private func quickDateFilterButton(_ filter: ModifiedDateFilter, count: Int) -> some View {
        let isActive = model.modifiedDateFilter == filter
        let countText = count > 99 ? "99+" : "\(count)"
        return Button {
            model.modifiedDateFilter = isActive ? .all : filter
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(filter.shortTitle)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .allowsTightening(true)

                if count > 0 {
                    Text(countText)
                        .font(.system(size: 7.35, weight: .bold, design: .monospaced))
                        .foregroundStyle(isActive ? Color.white.opacity(0.9) : Color.accentColor)
                        .baselineOffset(5)
                } else {
                    Color.clear
                        .frame(width: 13, height: 1)
                }
            }
            .frame(width: quickDateFilterWidth(filter), height: 24)
            .padding(.leading, quickDateFilterLeadingPadding(filter))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.10))
        )
        .help(quickDateFilterHelp(filter, count: count))
        .accessibilityLabel(filter.helpText)
        .accessibilityValue(count > 0 ? "\(count) matching files" : "No matching files")
        .clickableCursor()
    }

    private func quickDateFilterWidth(_ filter: ModifiedDateFilter) -> CGFloat {
        switch filter {
        case .withinHour, .withinWeek, .olderThanOneYear: 44
        case .today, .olderThanTwoYears: 52
        case .withinMonth: 56
        case .all: 0
        }
    }

    private func quickDateFilterLeadingPadding(_ filter: ModifiedDateFilter) -> CGFloat {
        switch filter {
        case .withinHour, .today, .withinWeek: 3
        default: 0
        }
    }

    private func quickDateFilterHelp(_ filter: ModifiedDateFilter, count: Int) -> String {
        guard count > 0 else { return "\(filter.helpText). No matching files." }
        return "\(filter.helpText). \(count) matching file\(count == 1 ? "" : "s")."
    }

    private var quickSizeFilterStrip: some View {
        HStack(spacing: 3) {
            quickSizeFilterButton(.upToOneMegabyte)
            quickSizeFilterButton(.oneToTenMegabytes)
            quickSizeFilterButton(.tenToHundredMegabytes)
            quickSizeFilterButton(.hundredMegabytesToOneGigabyte)
        }
        .fixedSize()
    }

    private var quickItemKindFilterStrip: some View {
        HStack(spacing: 3) {
            quickItemKindFilterButton(.files)
            quickItemKindFilterButton(.folders)
        }
        .fixedSize()
    }

    private var clearQuickFiltersButton: some View {
        Button(action: model.clearQuickFilters) {
            HStack(spacing: 3) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                Text("CLEAR")
                    .font(.system(size: 9, weight: .semibold))
            }
            .frame(width: 50, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.hasQuickFilters ? Color.primary : Color.secondary)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
        .fixedSize()
        .layoutPriority(2)
        .help("Clear date, size, and kind filters")
        .accessibilityLabel("Clear filters")
        .clickableCursor()
    }

    private func quickSizeFilterButton(_ filter: FileSizeFilter) -> some View {
        let isActive = model.fileSizeFilter == filter
        return Button {
            model.fileSizeFilter = isActive ? .all : filter
        } label: {
            Text(filter.shortTitle)
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
                .allowsTightening(true)
                .frame(width: quickSizeFilterWidth(filter), height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.10))
        )
        .help(filter.helpText)
        .accessibilityLabel(filter.helpText)
        .clickableCursor()
    }

    private func quickSizeFilterWidth(_ filter: FileSizeFilter) -> CGFloat {
        switch filter {
        case .upToOneMegabyte, .hundredMegabytesToOneGigabyte: 38
        case .oneToTenMegabytes: 44
        case .tenToHundredMegabytes: 50
        case .all, .oneGigabyteOrLarger: 0
        }
    }

    private func quickItemKindFilterButton(_ filter: ItemKindFilter) -> some View {
        let isActive = model.itemKindFilter == filter
        return Button {
            model.itemKindFilter = isActive ? .all : filter
        } label: {
            Text(filter.shortTitle)
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
                .allowsTightening(true)
                .frame(width: filter == .files ? 38 : 50, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.10))
        )
        .help(filter.helpText)
        .accessibilityLabel(filter.helpText)
        .clickableCursor()
    }

    private var breadcrumbs: [URL] {
        var chain: [URL] = []
        var url = model.currentURL.standardizedFileURL
        while true {
            chain.append(url)
            if url.path == "/" { break }
            let parent = url.deletingLastPathComponent().standardizedFileURL
            if parent.path == url.path { break }
            url = parent
        }
        return chain.reversed()
    }

    private func displayName(for url: URL) -> String {
        url.path == "/" ? "Macintosh HD" : url.lastPathComponent
    }
}
