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
                .help("Choose the output image format")
            }

            if videoCount > 0 {
                Picker("Video", selection: $options.videoCodec) {
                    ForEach(MediaVideoOutputCodec.allCases) { codec in
                        Text(codec.rawValue).tag(codec)
                    }
                }
                .help("Choose the output video codec")
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
                .help("Cancel conversion")
                Button("Convert") {
                    appState.performConvert(options: options)
                    appState.showConvertSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(targets.isEmpty)
                .help("Convert selected files")
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

struct PDFToolsSheet: View {
    @Environment(AppState.self) private var appState
    let target: FileItem
    let mode: PDFToolSheetMode
    let pageCount: Int

    @State private var pageRange: String
    @State private var watermark = ""
    @State private var password = ""

    init(target: FileItem, mode: PDFToolSheetMode, pageCount: Int) {
        self.target = target
        self.mode = mode
        self.pageCount = pageCount
        _pageRange = State(initialValue: "1-\(max(pageCount, 1))")
    }

    private var actionTitle: String {
        switch mode {
        case .extractPages: "Extract"
        case .watermark: "Add Watermark"
        case .protect: "Protect"
        case .removePassword: "Remove Password"
        }
    }

    private var actionDisabled: Bool {
        switch mode {
        case .extractPages: pageRange.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .watermark: watermark.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .protect, .removePassword: password.isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode.title)
                .font(.headline)
            Text(target.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            switch mode {
            case .extractPages:
                TextField("Pages", text: $pageRange)
                    .textFieldStyle(.roundedBorder)
                Text("\(pageCount) page\(pageCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .watermark:
                TextField("Watermark text", text: $watermark)
                    .textFieldStyle(.roundedBorder)
            case .protect:
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
            case .removePassword:
                SecureField("Current password", text: $password)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    appState.dismissPDFToolSheet()
                }
                .keyboardShortcut(.cancelAction)
                Button(actionTitle) {
                    performAction()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(actionDisabled)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func performAction() {
        switch mode {
        case .extractPages:
            appState.extractPDFPages(pageRange)
        case .watermark:
            appState.addPDFWatermark(watermark)
        case .protect:
            appState.protectPDF(password)
        case .removePassword:
            appState.removePDFPassword(password)
        }
    }
}
