import AppKit
import SwiftUI

struct StatusBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let pane = appState.activePane
        HStack(spacing: 4) {
            Text(
                pane.isDuplicateResultsActive
                    ? "\(pane.displayItems.count) duplicates"
                    : pane.isRecursiveSearchActive
                    ? "\(pane.displayItems.count) results"
                    : "\(pane.displayItems.count) items"
            )
            if !pane.selection.isEmpty {
                Text("· \(pane.selection.count) selected")
            }
            if pane.isSearching {
                Text("· searching…")
            }
            if let compareTitle = pane.compareTitle {
                Text("· \(compareTitle)")
            }
            if pane.isCalculatingFolderSizes {
                Text("· calculating sizes…")
            }
            if pane.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.leading, 4)
            }
            if pane.isCalculatingFolderSizes {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.leading, 4)
            }
            Spacer()
            if pane.viewMode == .icons {
                ThumbnailSizeControl(
                    size: Binding(
                        get: { appState.fileGridThumbnailSize },
                        set: { appState.setFileGridThumbnailSize($0) }
                    ),
                    onCommit: {
                        appState.persistFileGridThumbnailSize()
                    }
                )
                    .padding(.trailing, pane.freeSpaceText == nil ? 0 : 8)
            }
            if let free = pane.freeSpaceText {
                Text("\(free) available")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }
}

private struct ThumbnailSizeControl: View {
    @Binding var size: Double
    let onCommit: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.caption2)
                .foregroundStyle(.secondary)
            NativeThumbnailSlider(value: $size, onCommit: onCommit)
                .frame(width: 122, height: 22)
                .horizontalResizeCursor()
        }
        .help("Resize thumbnails")
        .accessibilityLabel("Thumbnail Size")
        .accessibilityValue("\(Int(FileGridThumbnailSettings.clampedValue(size))) pixels")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                setSize(size + 8)
            case .decrement:
                setSize(size - 8)
            @unknown default:
                break
            }
        }
        .onAppear {
            setSize(size)
        }
        .onDisappear(perform: onCommit)
    }

    private func setSize(_ newSize: Double) {
        let clamped = FileGridThumbnailSettings.clampedValue(newSize)
        guard abs(size - clamped) >= 0.5 else { return }
        size = clamped
        onCommit()
    }
}

private struct NativeThumbnailSlider: NSViewRepresentable {
    @Binding var value: Double
    let onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value, onCommit: onCommit)
    }

    func makeNSView(context: Context) -> TrackingThumbnailSlider {
        let slider = TrackingThumbnailSlider(
            value: FileGridThumbnailSettings.clampedValue(value),
            minValue: FileGridThumbnailSettings.range.lowerBound,
            maxValue: FileGridThumbnailSettings.range.upperBound,
            target: context.coordinator,
            action: #selector(Coordinator.valueChanged(_:))
        )
        slider.onEndTracking = onCommit
        slider.isContinuous = true
        slider.controlSize = .small
        slider.sliderType = .linear
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        return slider
    }

    func updateNSView(_ slider: TrackingThumbnailSlider, context: Context) {
        context.coordinator.value = $value
        context.coordinator.onCommit = onCommit
        slider.onEndTracking = onCommit
        let clamped = FileGridThumbnailSettings.clampedValue(value)
        if abs(slider.doubleValue - clamped) > 0.25 {
            slider.doubleValue = clamped
        }
    }

    static func dismantleNSView(_ slider: TrackingThumbnailSlider, coordinator: Coordinator) {
        coordinator.onCommit()
    }

    final class Coordinator: NSObject {
        var value: Binding<Double>
        var onCommit: () -> Void

        init(value: Binding<Double>, onCommit: @escaping () -> Void) {
            self.value = value
            self.onCommit = onCommit
        }

        @MainActor @objc func valueChanged(_ sender: NSSlider) {
            let clamped = FileGridThumbnailSettings.clampedValue(sender.doubleValue)
            guard abs(value.wrappedValue - clamped) >= 0.25 else { return }
            value.wrappedValue = clamped
            if NSApp.currentEvent?.type == .keyDown {
                onCommit()
            }
        }
    }
}

private final class TrackingThumbnailSlider: NSSlider {
    var onEndTracking: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onEndTracking?()
    }
}
