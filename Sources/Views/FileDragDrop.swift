import Foundation
import SwiftUI
import UniformTypeIdentifiers
import os

/// Temporary diagnostics for the drag-to-folder path. Read with:
///   log show --predicate 'subsystem == "com.qnsub.workbench"' --last 10m --info
enum DragDropLog {
    private static let logger = Logger(subsystem: "com.qnsub.workbench", category: "dragdrop")

    static func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }
}

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
        isEnabled: Bool = true,
        destinationResolver: ((CGPoint) -> URL?)? = nil
    ) -> some View {
        modifier(FileDropTargetModifier(
            destination: destination,
            paneIndex: paneIndex,
            appState: appState,
            isEnabled: isEnabled,
            destinationResolver: destinationResolver
        ))
    }
}

private struct FileDropTargetModifier: ViewModifier {
    let destination: URL
    let paneIndex: Int
    let appState: AppState
    let isEnabled: Bool
    let destinationResolver: ((CGPoint) -> URL?)?
    @State private var isTargeted = false
    @State private var targetID = UUID()

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            isTargeted ? Color.accentColor.opacity(0.65) : Color.clear,
                            lineWidth: 2
                        )
                        .allowsHitTesting(false)
                }
                .onDrop(
                    of: [AppState.internalFileDragType, .fileURL],
                    delegate: FileDropTargetDelegate(
                        destination: destination,
                        paneIndex: paneIndex,
                        appState: appState,
                        targetID: targetID,
                        isTargeted: $isTargeted,
                        destinationResolver: destinationResolver
                    )
                )
                .onChange(of: isTargeted) { _, isTargeted in
                    appState.updateFileDropTarget(
                        id: targetID,
                        destination: destination,
                        isTargeted: isTargeted
                    )
                }
                .onDisappear {
                    appState.updateFileDropTarget(
                        id: targetID,
                        destination: destination,
                        isTargeted: false
                    )
                }
        } else {
            content
        }
    }
}

private struct FileDropTargetDelegate: DropDelegate {
    let destination: URL
    let paneIndex: Int
    let appState: AppState
    let targetID: UUID
    @Binding var isTargeted: Bool
    let destinationResolver: ((CGPoint) -> URL?)?

    func validateDrop(info: DropInfo) -> Bool {
        !info.itemProviders(for: [AppState.internalFileDragType, .fileURL]).isEmpty
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: FileDropOperationPolicy.shouldMove(
            isInternalDrag: appState.hasCurrentFileDragSession,
            modifiers: NSEvent.modifierFlags
        ) ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let providers = info.itemProviders(for: [AppState.internalFileDragType, .fileURL])
        guard !providers.isEmpty else { return false }
        return handleDrop(providers, at: info.location)
    }

    private func handleDrop(_ providers: [NSItemProvider], at point: CGPoint) -> Bool {
        let resolved = destinationResolver?(point)
        let resolvedDestination = appState.preferredFileDropDestination(
            fallback: resolved ?? destination
        )
        let isInternal = providers.contains(where: {
            $0.hasItemConformingToTypeIdentifier(AppState.internalFileDragType.identifier)
        })
        DragDropLog.log(
            "HANDLE_DROP providers=\(providers.count) internal=\(isInternal) "
                + "target=\(destination.lastPathComponent) "
                + "resolver=\(resolved?.lastPathComponent ?? "nil") "
                + "final=\(resolvedDestination.lastPathComponent) "
                + "hasSession=\(appState.hasCurrentFileDragSession)"
        )
        if isInternal {
            return appState.dropCurrentFileDrag(
                to: resolvedDestination,
                paneIndex: paneIndex
            )
        }

        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        let collector = FileDropURLCollector()
        let group = DispatchGroup()
        for (index, provider) in fileProviders.enumerated() {
            group.enter()
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { item, _ in
                if let url = FileDropPayload.fileURL(from: item) {
                    collector.insert(url.standardizedFileURL, at: index)
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let urls = collector.urls
            guard !urls.isEmpty else {
                appState.lastError = "No usable files were dropped."
                return
            }
            _ = appState.drop(
                urls,
                to: resolvedDestination,
                paneIndex: paneIndex
            )
        }
        return true
    }
}

enum FileDropDestinationPolicy {
    static func preferredDestination(fallback: URL, activeDestinations: [URL]) -> URL {
        let fallback = fallback.standardizedFileURL
        return activeDestinations
            .map(\.standardizedFileURL)
            .filter { isSameOrDescendant($0, of: fallback) }
            .max { pathDepth($0) < pathDepth($1) }
            ?? fallback
    }

    private static func isSameOrDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let candidateComponents = candidate.pathComponents
        let ancestorComponents = ancestor.pathComponents
        guard candidateComponents.count >= ancestorComponents.count else { return false }
        return candidateComponents.prefix(ancestorComponents.count).elementsEqual(ancestorComponents)
    }

    private static func pathDepth(_ url: URL) -> Int {
        url.pathComponents.count
    }
}

enum FileDropPayload {
    nonisolated static func fileURL(from item: NSSecureCoding?) -> URL? {
        let url: URL?
        if let data = item as? Data {
            url = URL(dataRepresentation: data, relativeTo: nil)
        } else if let value = item as? URL {
            url = value
        } else if let value = item as? NSURL {
            url = value as URL
        } else if let value = item as? String {
            url = URL(string: value)
        } else if let value = item as? NSString {
            url = URL(string: value as String)
        } else {
            url = nil
        }
        return url?.isFileURL == true ? url : nil
    }
}

private final class FileDropURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Int: URL] = [:]

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return entries.sorted { $0.key < $1.key }.map(\.value)
    }

    func insert(_ url: URL, at index: Int) {
        lock.lock()
        entries[index] = url
        lock.unlock()
    }
}
