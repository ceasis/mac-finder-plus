import QuickLook
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    @State private var newFolderName = "untitled folder"
    @State private var goToPath = ""
    @State private var renameText = ""

    var body: some View {
        @Bindable var appState = appState
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        } detail: {
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 0) {
                    HSplitView {
                        PaneView(paneIndex: 0)
                        if appState.isDualPane {
                            PaneView(paneIndex: 1)
                        }
                        if appState.showPreview {
                            PreviewPane()
                        }
                    }
                    Divider()
                    StatusBarView()
                }
                if !appState.fileActivities.isEmpty {
                    FileActivityPanel()
                        .padding(12)
                }
            }
        }
        .quickLookPreview($appState.quickLookURL)
        .toolbar { toolbarContent }
        .sheet(isPresented: $appState.showResizeSheet) {
            ResizeSheet(targets: appState.resizeTargets)
        }
        .sheet(isPresented: $appState.showBatchRenameSheet) {
            BatchRenameSheet(targets: appState.batchRenameTargets)
        }
        .sheet(isPresented: $appState.showConvertSheet) {
            ConvertSheet(targets: appState.convertTargets)
        }
        .sheet(isPresented: $appState.showSlideshowSheet) {
            SlideshowSheet(targets: appState.slideshowTargets)
        }
        .sheet(isPresented: $appState.showScreenshotSheet) {
            ScreenshotSheet()
        }
        .sheet(isPresented: $appState.showNotesSheet) {
            NotesPanelView()
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Picker("View", selection: Binding(
                get: { appState.activePane.viewMode },
                set: { appState.activePane.viewMode = $0 }
            )) {
                ForEach(PaneViewMode.allCases) { mode in
                    Image(systemName: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("List or icon view (⌘1 / ⌘2)")

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
                appState.beginScreenshot()
            } label: {
                Label("Screenshot", systemImage: "camera.viewfinder")
            }
            .help("Screenshot (⌥⌘5)")

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
                appState.showPreview.toggle()
            } label: {
                Label(
                    "Preview",
                    systemImage: appState.showPreview ? "sidebar.right" : "photo"
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
