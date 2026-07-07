import SwiftUI
import UniformTypeIdentifiers

extension View {
    func fileDragSource(_ item: FileItem, paneIndex: Int, appState: AppState) -> some View {
        onDrag {
            appState.fileDragProvider(for: item, paneIndex: paneIndex)
        }
    }

    func fileDropTarget(
        to destination: URL,
        paneIndex: Int,
        appState: AppState,
        isEnabled: Bool = true
    ) -> some View {
        modifier(FileDropTargetModifier(
            destination: destination,
            paneIndex: paneIndex,
            appState: appState,
            isEnabled: isEnabled
        ))
    }
}

private struct FileDropTargetModifier: ViewModifier {
    let destination: URL
    let paneIndex: Int
    let appState: AppState
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .dropDestination(for: URL.self) { urls, _ in
                    appState.drop(urls, to: destination, paneIndex: paneIndex)
                }
                .onDrop(of: [AppState.internalFileDragType], isTargeted: nil) { _ in
                    appState.dropCurrentFileDrag(to: destination, paneIndex: paneIndex)
                }
        } else {
            content
        }
    }
}
