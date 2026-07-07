import SwiftUI

/// Options sheet for combining selected photos into an MP4 slideshow.
/// Switches to a progress view (with cancel) while rendering.
struct SlideshowSheet: View {
    @Environment(AppState.self) private var appState
    let targets: [FileItem]

    @State private var secondsPerPhoto = 2.0
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Slideshow from \(targets.count) Photos")
                .font(.headline)

            if let progress = appState.slideshowProgress {
                ProgressView(value: progress) {
                    Text("Creating video…")
                }
                HStack {
                    Spacer()
                    Button("Cancel") { appState.cancelSlideshow() }
                        .keyboardShortcut(.cancelAction)
                        .help("Cancel video creation")
                }
            } else {
                Picker("Each photo shows for", selection: $secondsPerPhoto) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("3 seconds").tag(3.0)
                    Text("5 seconds").tag(5.0)
                }
                .help("Choose how long each photo appears")
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
                .help("Choose whether photos fit or fill the frame")
                Text(
                    "Photos appear in the pane’s current sort order. "
                        + "The video is saved in this folder as “Slideshow.mp4”."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button("Cancel") { appState.showSlideshowSheet = false }
                        .keyboardShortcut(.cancelAction)
                        .help("Cancel slideshow export")
                    Button("Create Video") {
                        appState.performSlideshow(options: .init(
                            secondsPerPhoto: secondsPerPhoto,
                            size: sizeChoice.size,
                            fill: fill
                        ))
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .help("Create slideshow video")
                }
            }
        }
        .padding(20)
        .frame(width: 400)
        .interactiveDismissDisabled(appState.slideshowProgress != nil)
    }
}
