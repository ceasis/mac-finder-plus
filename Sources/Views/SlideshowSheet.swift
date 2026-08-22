import SwiftUI

/// Options sheet for creating an MP4 from an ordered selection of images and videos.
/// Switches to a progress view (with cancel) while rendering.
struct MergeIntoVideoSheet: View {
    @Environment(AppState.self) private var appState
    let targets: [FileItem]

    @State private var orderedTargets: [FileItem]
    @State private var orderPreset = VideoMergeOrder.fileView
    @State private var hasCustomOrder = false
    @AppStorage("videoMerge.secondsPerImage") private var secondsPerImage = 2.0
    @AppStorage("videoMerge.sizeChoice") private var sizeChoiceRawValue =
        SizeChoice.landscape1080.rawValue
    @AppStorage("videoMerge.fillFrame") private var fill = false
    @AppStorage("videoMerge.includeAudio") private var includeAudio = true

    init(targets: [FileItem]) {
        self.targets = targets
        _orderedTargets = State(initialValue: targets)
    }

    enum SizeChoice: String, CaseIterable, Identifiable {
        case landscape1080 = "1080p Landscape (1920×1080)"
        case portrait1080 = "1080p Portrait (1080×1920)"
        case square1080 = "Square (1080×1080)"
        case landscape4K = "4K Landscape (3840×2160)"

        var id: String { rawValue }

        var size: CGSize {
            switch self {
            case .landscape1080: CGSize(width: 1920, height: 1080)
            case .portrait1080: CGSize(width: 1080, height: 1920)
            case .square1080: CGSize(width: 1080, height: 1080)
            case .landscape4K: CGSize(width: 3840, height: 2160)
            }
        }
    }

    private var imageCount: Int { orderedTargets.filter(\.isImage).count }
    private var videoCount: Int { orderedTargets.count - imageCount }
    private var sizeChoice: SizeChoice {
        SizeChoice(rawValue: sizeChoiceRawValue) ?? .landscape1080
    }

    private var mediaSummary: String {
        let images = imageCount == 0 ? nil : "\(imageCount) image\(imageCount == 1 ? "" : "s")"
        let videos = videoCount == 0 ? nil : "\(videoCount) video\(videoCount == 1 ? "" : "s")"
        return [images, videos].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Merge Into Video")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text(mediaSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let progress = appState.mergeIntoVideoProgress {
                ProgressView(value: progress) {
                    Text("Merging media…")
                }
                HStack {
                    Spacer()
                    Button("Cancel") { appState.cancelMergeIntoVideo() }
                        .keyboardShortcut(.cancelAction)
                        .help("Cancel video merge")
                }
            } else {
                GroupBox("Order Preview") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Picker("Arrange", selection: $orderPreset) {
                                ForEach(VideoMergeOrder.allCases) { order in
                                    Text(order.rawValue).tag(order)
                                }
                            }
                            .frame(maxWidth: 310)
                            .onChange(of: orderPreset) { _, newPreset in
                                orderedTargets = newPreset.arrange(targets)
                                hasCustomOrder = false
                            }

                            if hasCustomOrder {
                                Text("Custom order")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                orderedTargets.reverse()
                                hasCustomOrder = true
                            } label: {
                                Label("Reverse", systemImage: "arrow.up.arrow.down")
                            }
                            .help("Reverse the current merge order")
                        }

                        Text(
                            "Only the selected files are included. They start in the same order "
                                + "as the current file view. Drag rows or use the arrows to adjust."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        List {
                            ForEach(Array(orderedTargets.enumerated()), id: \.element.id) { index, item in
                                MergeOrderRow(
                                    item: item,
                                    number: index + 1,
                                    canMoveUp: index > 0,
                                    canMoveDown: index < orderedTargets.count - 1,
                                    moveUp: { moveTarget(at: index, by: -1) },
                                    moveDown: { moveTarget(at: index, by: 1) }
                                )
                            }
                            .onMove { source, destination in
                                orderedTargets.move(fromOffsets: source, toOffset: destination)
                                hasCustomOrder = true
                            }
                        }
                        .listStyle(.inset)
                        .frame(height: min(max(CGFloat(orderedTargets.count) * 56, 150), 250))
                    }
                }

                GroupBox("Output Options") {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                        if imageCount > 0 {
                            GridRow {
                                Text("Image duration")
                                Picker("", selection: $secondsPerImage) {
                                    Text("1 second").tag(1.0)
                                    Text("2 seconds").tag(2.0)
                                    Text("3 seconds").tag(3.0)
                                    Text("5 seconds").tag(5.0)
                                }
                                .labelsHidden()
                                .help("Choose how long each image appears")
                            }
                        }

                        GridRow {
                            Text("Video size")
                            Picker("", selection: $sizeChoiceRawValue) {
                                ForEach(SizeChoice.allCases) { choice in
                                    Text(choice.rawValue).tag(choice.rawValue)
                                }
                            }
                            .labelsHidden()
                            .help("Choose the merged video size")
                        }

                        GridRow {
                            Text("Scaling")
                            Picker("", selection: $fill) {
                                Text("Fit (black bars)").tag(false)
                                Text("Fill (crop)").tag(true)
                            }
                            .labelsHidden()
                            .help("Choose whether media fits or fills the frame")
                        }

                        if videoCount > 0 {
                            GridRow {
                                Text("Audio")
                                Toggle("Keep audio from video clips", isOn: $includeAudio)
                                    .help("Preserve the original audio tracks in the merged video")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text(
                    "The video is saved in this folder as “Merged Video.mp4”."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button("Cancel") { appState.showMergeIntoVideoSheet = false }
                        .keyboardShortcut(.cancelAction)
                        .help("Cancel video merge")
                    Button("Merge Into Video") {
                        appState.performMergeIntoVideo(
                            targets: orderedTargets,
                            options: .init(
                                secondsPerImage: secondsPerImage,
                                size: sizeChoice.size,
                                fill: fill,
                                includeAudio: includeAudio
                            )
                        )
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .help("Merge the selected media into a video")
                }
            }
        }
        .padding(20)
        .frame(width: 620)
        .interactiveDismissDisabled(appState.mergeIntoVideoProgress != nil)
    }

    private func moveTarget(at index: Int, by offset: Int) {
        let destination = index + offset
        guard orderedTargets.indices.contains(index),
              orderedTargets.indices.contains(destination) else {
            return
        }
        let item = orderedTargets.remove(at: index)
        orderedTargets.insert(item, at: destination)
        hasCustomOrder = true
    }
}

private struct MergeOrderRow: View {
    let item: FileItem
    let number: Int
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void

    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)

            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(nsImage: item.icon)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                }
            }
            .frame(width: 54, height: 36)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.isImage ? "Image" : "Video")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 3) {
                Button(action: moveUp) {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveUp)
                .help("Move earlier")

                Button(action: moveDown) {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveDown)
                .help("Move later")
            }
        }
        .padding(.vertical, 3)
        .task(id: "\(item.id)|\(item.modified.timeIntervalSince1970)") {
            thumbnail = nil
            thumbnail = await ThumbnailLoader.thumbnail(for: item, pixelSize: 96)
        }
    }
}
