import Foundation
import SwiftUI

/// Only enabled by the UI-test runner, and only for a marked disposable folder.
/// This keeps interaction tests away from saved tabs, bookmarks, notes, and the
/// system clipboard. Release builds do not include the fixture scene.
enum WorkbenchUITestConfiguration {
    static var isRequested: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--workbench-ui-testing")
        #else
        return false
        #endif
    }

    struct Fixture {
        let root: URL
        let token: String
        let previewFilename: String?

        var browser: URL { root.appendingPathComponent("Browser", isDirectory: true) }
        var sidebar: URL { root.appendingPathComponent("Sidebar Destination", isDirectory: true) }
        var defaultsSuiteName: String { "com.qnsub.workbench.uitests.\(token)" }
        var defaults: UserDefaults {
            UserDefaults(suiteName: defaultsSuiteName)!
        }
    }

    static let current: Fixture? = {
        #if DEBUG
        let process = ProcessInfo.processInfo
        guard isRequested,
              let path = process.environment["WORKBENCH_UI_TEST_ROOT"],
              let token = process.environment["WORKBENCH_UI_TEST_TOKEN"],
              UUID(uuidString: token) != nil else { return nil }
        let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        let fileManager = FileManager.default
        let runnerBundleID = "\(Bundle.main.bundleIdentifier ?? "com.qnsub.workbench.app").uitests.xctrunner"
        let runnerTemporaryDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(runnerBundleID)/Data/tmp", isDirectory: true)
            .resolvingSymlinksInPath()
        // Xcode's UI runner is sandboxed even though Workbench itself is not.
        // Accept only its exact container tmp folder, our own canonical tmp
        // folder for nonsandboxed runners, or the original local /private/tmp.
        let allowedParents = [
            runnerTemporaryDirectory,
            fileManager.temporaryDirectory.resolvingSymlinksInPath(),
            URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath(),
        ]
        guard allowedParents.contains(where: { $0.path == root.deletingLastPathComponent().path }),
              root.lastPathComponent == "workbench-ui-tests-\(token)",
              (try? String(contentsOf: root.appendingPathComponent(".fixture"), encoding: .utf8)) == token
        else { return nil }
        return Fixture(root: root, token: token, previewFilename: process.environment["WORKBENCH_UI_TEST_PREVIEW"])
        #else
        return nil
        #endif
    }()

    static var defaults: UserDefaults { current?.defaults ?? .standard }
}

#if DEBUG
/// The real interaction surfaces, with disposable data and no onboarding,
/// permission prompts, background stores, or restoration of the user's window.
struct WorkbenchUIRegressionView: View {
    let fixture: WorkbenchUITestConfiguration.Fixture
    let appState: AppState
    @State private var selectedPreview = false

    var body: some View {
        HStack(spacing: 0) {
            List {
                Section("Favorites") {
                    SidebarReorderableLabelRow(
                        title: fixture.sidebar.lastPathComponent,
                        systemImage: "folder",
                        isReordering: false,
                        dragHandle: { EmptyView() }
                    )
                    .modifier(SidebarFolderDropTargetModifier(
                        url: fixture.sidebar,
                        paneIndex: 0,
                        appState: appState
                    ))
                }
            }
            .listStyle(.sidebar)
            .frame(width: 220)
            Divider()
            VStack(spacing: 0) {
                FileGridView(model: appState.panes[0], paneIndex: 0)
                Text(appState.lastError ?? "")
                    .accessibilityIdentifier("ui-test-last-error")
                    .font(.caption)
            }
            .frame(minWidth: 380)
            if fixture.previewFilename != nil {
                Divider()
                PreviewPane()
                    .frame(width: 720)
            }
        }
        .environment(appState)
        .defaultAppStorage(fixture.defaults)
        .frame(width: fixture.previewFilename == nil ? 1020 : 1340, height: 780)
        .onAppear {
            fixture.defaults.set(true, forKey: "previewVideo.showsControls")
            fixture.defaults.set(true, forKey: VideoPreviewPlaybackPreferences.mutedKey)
            appState.panes[0].startMonitoring()
        }
        .onChange(of: appState.panes[0].items.map(\.id)) { _, _ in
            guard !selectedPreview, let name = fixture.previewFilename,
                  let item = appState.panes[0].items.first(where: { $0.name == name }) else { return }
            selectedPreview = true
            appState.panes[0].selection = [item.id]
        }
        .onDisappear { appState.panes[0].stopMonitoring() }
    }
}
#endif
