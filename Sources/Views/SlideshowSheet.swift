import SwiftUI

/// Options sheet for creating an MP4 from an ordered selection of images and videos.
/// Switches to a progress view (with cancel) while rendering.
struct MergeIntoVideoSheet: View {
    @Environment(AppState.self) private var appState
    let targets: [FileItem]

    @State private var secondsPerImage = 2.0
    @State private var sizeChoice = SizeChoice.landscape1080
    @State private var fill = false

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

    private var imageCount: Int { targets.filter(\.isImage).count }
    private var videoCount: Int { targets.count - imageCount }

    private var mediaSummary: String {
        let images = imageCount == 0 ? nil : "\(imageCount) image\(imageCount == 1 ? "" : "s")"
        let videos = videoCount == 0 ? nil : "\(videoCount) video\(videoCount == 1 ? "" : "s")"
        return [images, videos].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Merge Into Video")
                .font(.headline)
            Text(mediaSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)

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
                if imageCount > 0 {
                    Picker("Each image shows for", selection: $secondsPerImage) {
                        Text("1 second").tag(1.0)
                        Text("2 seconds").tag(2.0)
                        Text("3 seconds").tag(3.0)
                        Text("5 seconds").tag(5.0)
                    }
                    .help("Choose how long each image appears")
                }
                Picker("Video size", selection: $sizeChoice) {
                    ForEach(SizeChoice.allCases) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .help("Choose the slideshow video size")
                Picker("Scaling", selection: $fill) {
                    Text("Fit (black bars)").tag(false)
                    Text("Fill (crop)").tag(true)
                }
                .help("Choose whether media fits or fills the frame")
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
                        appState.performMergeIntoVideo(options: .init(
                            secondsPerImage: secondsPerImage,
                            size: sizeChoice.size,
                            fill: fill
                        ))
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .help("Merge the selected media into a video")
                }
            }
        }
        .padding(20)
        .frame(width: 400)
        .interactiveDismissDisabled(appState.mergeIntoVideoProgress != nil)
    }
}
