import SwiftUI

struct ConvertSheet: View {
    @Environment(AppState.self) private var appState
    let targets: [FileItem]

    @State private var options = MediaConversionOptions()

    private var imageCount: Int { targets.filter(\.isImage).count }
    private var videoCount: Int { targets.filter(\.isVideoMedia).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(targets.count == 1 ? "Convert 1 File" : "Convert \(targets.count) Files")
                .font(.headline)

            if imageCount > 0 {
                Picker("Images", selection: $options.imageFormat) {
                    ForEach(MediaImageOutputFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
            }

            if videoCount > 0 {
                Picker("Video", selection: $options.videoCodec) {
                    ForEach(MediaVideoOutputCodec.allCases) { codec in
                        Text(codec.rawValue).tag(codec)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                if imageCount > 0 {
                    Label("\(imageCount) image\(imageCount == 1 ? "" : "s")", systemImage: "photo")
                }
                if videoCount > 0 {
                    Label("\(videoCount) video\(videoCount == 1 ? "" : "s")", systemImage: "film")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") {
                    appState.showConvertSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Convert") {
                    appState.performConvert(options: options)
                    appState.showConvertSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(targets.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
