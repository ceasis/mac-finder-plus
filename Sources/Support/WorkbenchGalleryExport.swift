#if DEBUG
import AppKit
import SwiftUI

/// Export real Workbench views without sampling the desktop. Only runs with
/// an explicitly validated, disposable UI-test fixture and the export flag.
@MainActor
enum WorkbenchGalleryExport {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--export-workbench-gallery"),
              let fixture = WorkbenchUITestConfiguration.current else { return }
        Task { @MainActor in
            let state = AppState.shared
            let model = state.panes[0]
            let files = (try? FileManager.default.contentsOfDirectory(at: fixture.browser,
                includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            model.items = files.map { FileItem.make(url: $0) }
            for (name, file) in [("image-preview", "Studio Moodboard.webp"),
                                 ("csv-preview", "Asset Inventory.csv"),
                                 ("markdown-editor", "Project Brief.md")] {
                guard let item = model.items.first(where: { $0.name == file }) else { continue }
                model.selection = [item.id]
                let content = HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Label("Studio Atlas", systemImage: "folder")
                            .font(.headline).padding(16)
                        Divider()
                        FileGridView(model: model, paneIndex: 0)
                    }
                    .frame(width: 425)
                    Divider()
                    PreviewPane()
                        .frame(maxWidth: .infinity)
                }
                .frame(width: 1180, height: 640)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(state)
                .defaultAppStorage(fixture.defaults)
                .preferredColorScheme(.light)

                let frame = NSRect(x: -4000, y: -4000, width: 1180, height: 640)
                let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .aqua)
                window.isReleasedWhenClosed = false
                window.isExcludedFromWindowsMenu = true
                let host = NSHostingView(rootView: content)
                host.frame = NSRect(origin: .zero, size: frame.size)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(750))
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        try? data.write(to: fixture.root.appendingPathComponent("\(name).png"), options: .atomic)
                    }
                }
                window.close()
            }
            NSApp.terminate(nil)
        }
    }
}
#endif
