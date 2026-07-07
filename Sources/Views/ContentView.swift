import QuickLook
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    @State private var newFolderName = "untitled folder"
    @State private var newFileName = "Untitled.txt"
    @State private var goToPath = ""
    @State private var renameText = ""
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("rightPanelWidthFraction") private var rightPanelWidthFraction = 0.5

    var body: some View {
        @Bindable var appState = appState
        ZStack {
            mainContent
            utilityModalLayer
        }
        .quickLookPreview($appState.quickLookURL)
        .toolbar { toolbarContent }
        .sheet(isPresented: $appState.showPreviewSlideshow) {
            PreviewSlideshowView(items: appState.previewSlideshowItems)
        }
        .sheet(isPresented: $appState.showOnboarding, onDismiss: { hasCompletedOnboarding = true }) {
            OnboardingView(isPresented: $appState.showOnboarding)
                .interactiveDismissDisabled()
        }
        .task {
            if !hasCompletedOnboarding { appState.showOnboarding = true }
        }
        .alert("Error", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.lastError ?? "")
        }
        .alert("New Folder", isPresented: $appState.showNewFolderPrompt) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                appState.createFolder(named: newFolderName)
                newFolderName = "untitled folder"
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Text File", isPresented: $appState.showNewFilePrompt) {
            TextField("Name", text: $newFileName)
            Button("Create") {
                appState.createTextFile(named: newFileName)
                newFileName = "Untitled.txt"
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Go to Folder", isPresented: $appState.showGoToPrompt) {
            TextField("Path (e.g. ~/Downloads)", text: $goToPath)
            Button("Go") { appState.goTo(path: goToPath) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: renamePresented) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let target = appState.renameTarget {
                    appState.rename(target, to: renameText)
                }
                appState.renameTarget = nil
            }
            Button("Cancel", role: .cancel) { appState.renameTarget = nil }
        }
        .onChange(of: appState.renameTarget) { _, target in
            if let target { renameText = target.name }
        }
    }

    private func rightPanelWidth(totalWidth: CGFloat) -> CGFloat {
        let minWidth: CGFloat = 320
        let maxFraction = 0.75
        let fraction = rightPanelWidthFraction > 0 ? rightPanelWidthFraction : 0.5
        let clampedFraction = min(max(fraction, Double(minWidth / max(totalWidth, 1))), maxFraction)
        return totalWidth * clampedFraction
    }

    private func usesRightDockedPanel(_ panel: DockedToolPanel?) -> Bool {
        switch panel {
        case .notes, .screenshot, .recording:
            true
        default:
            false
        }
    }

    @ViewBuilder
    private func rightDockedPanelContent(for panel: DockedToolPanel) -> some View {
        switch panel {
        case .notes:
            NotesPanelView()
        case .screenshot, .recording:
            CapturePanelView()
        default:
            EmptyView()
        }
    }

    private var mainBrowserColumn: some View {
        VStack(spacing: 0) {
            HSplitView {
                PaneView(paneIndex: 0)
                if appState.isDualPane {
                    PaneView(paneIndex: 1)
                }
                if appState.activeToolPanel == .preview {
                    PreviewPane()
                }
            }
            Divider()
            StatusBarView()
        }
    }

    private var mainContent: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        } detail: {
            GeometryReader { geometry in
                let totalWidth = geometry.size.width
                let rightPanel = usesRightDockedPanel(appState.activeToolPanel)
                    ? appState.activeToolPanel
                    : nil
                let rightWidth = rightPanel != nil ? rightPanelWidth(totalWidth: totalWidth) : 0
                let mainWidth = max(totalWidth - rightWidth, 360)

                ZStack(alignment: .bottomTrailing) {
                    HStack(spacing: 0) {
                        if rightPanel == nil {
                            if appState.activeToolPanel == .cleanup {
                                CleanupPanelView()
                            } else if appState.activeToolPanel == .clipboard {
                                ClipboardHistoryColumnView()
                            } else if appState.activeToolPanel == .organize {
                                FolderOrganizerPanelView()
                            }
                        }

                        mainBrowserColumn
                            .modifier(MainColumnWidthModifier(
                                isFixed: rightPanel != nil,
                                width: mainWidth
                            ))

                        if let rightPanel {
                            ResizableSidePanelContainer(
                                availableWidth: totalWidth,
                                widthFraction: $rightPanelWidthFraction
                            ) {
                                rightDockedPanelContent(for: rightPanel)
                            }
                            .frame(width: rightWidth)
                        }
                    }
                    if !appState.fileActivities.isEmpty {
                        FileActivityPanel()
                            .padding(12)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .onChange(of: appState.activeToolPanel) { _, panel in
                    if usesRightDockedPanel(panel), rightPanelWidthFraction < 0.45 {
                        rightPanelWidthFraction = 0.5
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var utilityModalLayer: some View {
        if let prompt = appState.capturePermissionPrompt {
            DismissibleToolModal {
                appState.dismissCapturePermissionPrompt()
            } content: {
                CapturePermissionPromptView(prompt: prompt)
            }
        } else if appState.showResizeSheet {
            DismissibleToolModal {
                appState.showResizeSheet = false
            } content: {
                ResizeSheet(targets: appState.resizeTargets)
            }
        } else if appState.showBatchRenameSheet {
            DismissibleToolModal {
                appState.showBatchRenameSheet = false
            } content: {
                BatchRenameSheet(targets: appState.batchRenameTargets)
            }
        } else if appState.showConvertSheet {
            DismissibleToolModal {
                appState.showConvertSheet = false
            } content: {
                ConvertSheet(targets: appState.convertTargets)
            }
        } else if appState.showSlideshowSheet {
            DismissibleToolModal(
                isDismissable: appState.slideshowProgress == nil,
                onDismiss: {
                    if appState.slideshowProgress == nil {
                        appState.showSlideshowSheet = false
                    }
                },
                content: {
                    SlideshowSheet(targets: appState.slideshowTargets)
                }
            )
        } else if let target = appState.annotationTarget {
            DismissibleToolModal(showsCloseButton: false) {
                appState.annotationTarget = nil
            } content: {
                ImageAnnotationEditorView(target: target)
            }
        } else if let target = appState.editingTextFile {
            // Not outside/Esc-dismissable: the editor guards unsaved changes on
            // close via its own Close button.
            DismissibleToolModal(isDismissable: false, showsCloseButton: false) {
                appState.editingTextFile = nil
            } content: {
                TextEditorView(target: target)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Picker("View", selection: Binding(
                get: { appState.activePane.viewMode },
                set: { appState.activePane.viewMode = $0 }
            )) {
                ForEach(PaneViewMode.allCases) { mode in
                    Image(systemName: mode.systemImage)
                        .tag(mode)
                        .help(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .help("List, icon, or column view (⌘1 / ⌘2 / ⌘3)")

            Button {
                appState.showNewFolderPrompt = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .help("New Folder (⇧⌘N)")

            Button {
                appState.transferSelection(move: false)
            } label: {
                Label("Copy to Other Pane", systemImage: "doc.on.doc")
            }
            .help("Copy selection to the other pane (F5)")
            .disabled(!appState.isDualPane)

            Button {
                appState.transferSelection(move: true)
            } label: {
                Label("Move to Other Pane", systemImage: "arrow.right.doc.on.clipboard")
            }
            .help("Move selection to the other pane (F6)")
            .disabled(!appState.isDualPane)

            Spacer()

            Button {
                appState.showNotes()
            } label: {
                Label("Notes", systemImage: "note.text")
            }
            .help("Notes (⌥⌘N)")

            Button {
                appState.showClipboardHistory()
            } label: {
                Label("Clipboard", systemImage: "clipboard")
            }
            .help("Clipboard history (⌥⌘V)")

            Button {
                appState.beginScreenshot()
            } label: {
                Label("Capture", systemImage: "record.circle")
            }
            .help("Capture screenshot or recording (⌥⌘5)")

            Button {
                appState.beginAnnotateImage()
            } label: {
                Label("Annotate", systemImage: "pencil")
            }
            .help("Annotate selected image (⌥⌘A)")
            .disabled(!appState.activePane.selectedItems.contains(where: \.isImage))

            Button {
                appState.showHidden.toggle()
            } label: {
                Label(
                    "Hidden Files",
                    systemImage: appState.showHidden ? "eye" : "eye.slash"
                )
            }
            .help("Show or hide hidden files (⇧⌘.)")

            Toggle(isOn: Binding(
                get: { appState.autoCalculateFolderSizes },
                set: { appState.autoCalculateFolderSizes = $0 }
            )) {
                Label("Folder Sizes", systemImage: "sum")
            }
            .toggleStyle(.button)
            .help("Auto calculate folder sizes")

            Button {
                appState.toggleDualPane()
            } label: {
                Label(
                    "Dual Pane",
                    systemImage: appState.isDualPane
                        ? "rectangle.split.2x1.fill" : "rectangle.split.2x1"
                )
            }
            .help("Toggle dual pane (⇧⌘D)")

            Button {
                appState.togglePreview()
            } label: {
                Label(
                    "Preview",
                    systemImage: appState.activeToolPanel == .preview ? "sidebar.right" : "photo"
                )
            }
            .help("Toggle media preview pane (⌥⌘P)")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { appState.lastError != nil },
            set: { if !$0 { appState.lastError = nil } }
        )
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { appState.renameTarget != nil },
            set: { if !$0 { appState.renameTarget = nil } }
        )
    }
}

private struct CapturePermissionPromptView: View {
    @Environment(AppState.self) private var appState

    let prompt: CapturePermissionPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            VStack(spacing: 10) {
                ForEach(prompt.required) { requirement in
                    permissionRow(requirement)
                }
            }

            Divider()

            HStack {
                Button("Cancel") {
                    appState.dismissCapturePermissionPrompt()
                }
                Spacer()
                Button("Check Again") {
                    appState.retryCapturePermissions()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(prompt.title, systemImage: prompt.kind.systemImage)
                .font(.title3.bold())

            Text("Workbench checks capture permissions before opening this tool. Grant the missing permissions, then check again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionRow(_ requirement: CapturePermissionRequirement) -> some View {
        let isMissing = prompt.missing.contains(requirement)

        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: requirement.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isMissing ? .orange : .green)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(requirement.title)
                    .font(.callout.weight(.semibold))
                Text(requirement.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if isMissing {
                Button("Open Settings") {
                    appState.openCapturePermissionSettings(requirement)
                }
                .controlSize(.small)
            } else {
                Label("OK", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(isMissing ? 0.12 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isMissing ? Color.orange.opacity(0.28) : Color.green.opacity(0.22), lineWidth: 1)
        )
    }
}

/// Shared chrome for every tool panel: a dimmed backdrop, a capped/centered
/// card, and one uniform way to close — click outside, press Esc, or the close
/// button in the top-trailing corner. All three are gated by `isDismissable`
/// (off while a job like a slideshow render is in progress). Editors that carry
/// their own top toolbar (annotation) set `showsCloseButton: false`.
private struct DismissibleToolModal<Content: View>: View {
    var isDismissable = true
    var showsCloseButton = true
    let onDismiss: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        // Cap the modal to the window so a tool panel can never overflow the
        // window edges and clip (e.g. Notes' wide attachments column). The
        // panel expands to fill this space and shrinks to fit a small window.
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.10)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isDismissable {
                            onDismiss()
                        }
                    }

                content()
                    .frame(
                        maxWidth: max(geo.size.width - 48, 320),
                        maxHeight: max(geo.size.height - 48, 240)
                    )
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                    .onTapGesture {}
                    .overlay(alignment: .topTrailing) {
                        if isDismissable && showsCloseButton {
                            closeButton
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.22), radius: 28, x: 0, y: 14)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .transition(.opacity)
        .zIndex(100)
        // Esc closes, uniformly, for any dismissable modal. Disabled (so the
        // shortcut is inactive and falls through) while a job is in progress.
        .background(
            Button("", action: onDismiss)
                .keyboardShortcut(.cancelAction)
                .disabled(!isDismissable)
                .opacity(0)
                .accessibilityHidden(true)
        )
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(12)
        .help("Close (Esc)")
    }
}

private struct MainColumnWidthModifier: ViewModifier {
    let isFixed: Bool
    let width: CGFloat

    func body(content: Content) -> some View {
        if isFixed {
            content
                .frame(width: width)
                .frame(maxHeight: .infinity)
        } else {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
