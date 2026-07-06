import SwiftUI

/// Options sheet for resizing the selected images. Copies are written next to
/// the originals with a dimension suffix; originals are never modified.
struct ResizeSheet: View {
    @Environment(AppState.self) private var appState
    let targets: [FileItem]

    @State private var useMaxDimension = true
    @State private var maxDimension = 1920
    @State private var percent = 50
    @State private var format: ImageProcessing.Format = .original

    private let dimensionPresets = [640, 1024, 1280, 1920, 2560, 3840]
    private let percentPresets = [10, 25, 50, 75]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                targets.count == 1
                    ? "Resize “\(targets[0].name)”"
                    : "Resize \(targets.count) Images"
            )
            .font(.headline)

            Picker("Mode", selection: $useMaxDimension) {
                Text("Longest Side").tag(true)
                Text("Percentage").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if useMaxDimension {
                Picker("Longest side", selection: $maxDimension) {
                    ForEach(dimensionPresets, id: \.self) { value in
                        Text("\(value) px").tag(value)
                    }
                }
            } else {
                Picker("Scale to", selection: $percent) {
                    ForEach(percentPresets, id: \.self) { value in
                        Text("\(value) %").tag(value)
                    }
                }
            }

            Picker("Save as", selection: $format) {
                ForEach(ImageProcessing.Format.allCases) { format in
                    Text(format.rawValue).tag(format)
                }
            }

            Text("Resized copies are saved next to the originals — nothing is overwritten.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") {
                    appState.showResizeSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Resize") {
                    let mode: ImageProcessing.Mode =
                        useMaxDimension ? .maxDimension(maxDimension) : .percent(percent)
                    appState.performResize(options: .init(mode: mode, format: format))
                    appState.showResizeSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
