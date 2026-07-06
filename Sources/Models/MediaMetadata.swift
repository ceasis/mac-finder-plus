import AVFoundation
import CoreMedia
import Foundation
import ImageIO

struct MediaMetadata: Equatable {
    var sections: [MediaMetadataSection]

    var isEmpty: Bool {
        sections.allSatisfy { $0.rows.isEmpty }
    }
}

struct MediaMetadataSection: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var rows: [MediaMetadataRow]
}

struct MediaMetadataRow: Identifiable, Equatable {
    let id = UUID()
    var label: String
    var value: String
}

enum MediaMetadataReader {
    static func metadata(for item: FileItem) async -> MediaMetadata {
        if item.isImage {
            return imageMetadata(for: item)
        }
        if item.isPlayableMedia {
            return await mediaMetadata(for: item)
        }
        return genericMetadata(for: item)
    }

    static func captureDate(for url: URL) async -> Date? {
        if let imageDate = imageCaptureDate(for: url) {
            return imageDate
        }
        if let videoDate = await videoCaptureDate(for: url) {
            return videoDate
        }
        return try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }

    private static func genericMetadata(for item: FileItem) -> MediaMetadata {
        MediaMetadata(sections: [
            MediaMetadataSection(title: "File", rows: fileRows(for: item))
        ])
    }

    private static func imageMetadata(for item: FileItem) -> MediaMetadata {
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return genericMetadata(for: item)
        }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let width = intValue(properties[kCGImagePropertyPixelWidth])
        let height = intValue(properties[kCGImagePropertyPixelHeight])

        var fileRows = fileRows(for: item)
        if let width, let height {
            fileRows.append(.init(label: "Dimensions", value: "\(width) x \(height)"))
        }
        if let colorModel = properties[kCGImagePropertyColorModel] as? String {
            fileRows.append(.init(label: "Color", value: colorModel))
        }

        var cameraRows: [MediaMetadataRow] = []
        if let make = stringValue(tiff[kCGImagePropertyTIFFMake]),
           let model = stringValue(tiff[kCGImagePropertyTIFFModel]) {
            cameraRows.append(.init(label: "Camera", value: "\(make) \(model)"))
        } else if let model = stringValue(tiff[kCGImagePropertyTIFFModel]) {
            cameraRows.append(.init(label: "Camera", value: model))
        }
        appendStringRow(&cameraRows, label: "Lens", value: exif[kCGImagePropertyExifLensModel])
        appendNumberRow(&cameraRows, label: "ISO", value: exif[kCGImagePropertyExifISOSpeedRatings])
        appendApertureRow(&cameraRows, value: exif[kCGImagePropertyExifFNumber])
        appendExposureRow(&cameraRows, value: exif[kCGImagePropertyExifExposureTime])
        appendFocalLengthRow(&cameraRows, value: exif[kCGImagePropertyExifFocalLength])

        var captureRows: [MediaMetadataRow] = []
        if let date = imageCaptureDate(properties: properties) {
            captureRows.append(.init(label: "Captured", value: date.formatted(date: .abbreviated, time: .standard)))
        }
        appendStringRow(&captureRows, label: "Software", value: tiff[kCGImagePropertyTIFFSoftware])

        var gpsRows: [MediaMetadataRow] = []
        if let coordinate = coordinate(from: gps) {
            gpsRows.append(.init(label: "Coordinates", value: coordinate))
        }
        appendNumberRow(&gpsRows, label: "Altitude", value: gps[kCGImagePropertyGPSAltitude], suffix: " m")

        return MediaMetadata(sections: [
            .init(title: "File", rows: fileRows),
            .init(title: "Camera", rows: cameraRows),
            .init(title: "Capture", rows: captureRows),
            .init(title: "GPS", rows: gpsRows),
        ].filter { !$0.rows.isEmpty })
    }

    private static func mediaMetadata(for item: FileItem) async -> MediaMetadata {
        let asset = AVURLAsset(url: item.url)
        var fileRows = fileRows(for: item)
        if let duration = try? await asset.load(.duration) {
            fileRows.append(.init(label: "Duration", value: durationText(duration)))
        }

        var videoRows: [MediaMetadataRow] = []
        var audioRows: [MediaMetadataRow] = []
        if let tracks = try? await asset.load(.tracks) {
            if let videoTrack = tracks.first(where: { $0.mediaType == .video }) {
                if let sizeText = await videoSizeText(for: videoTrack) {
                    videoRows.append(.init(label: "Dimensions", value: sizeText))
                }
                if let codec = await codecText(for: videoTrack) {
                    videoRows.append(.init(label: "Codec", value: codec))
                }
                if let bitrate = try? await videoTrack.load(.estimatedDataRate), bitrate > 0 {
                    videoRows.append(.init(label: "Bitrate", value: bitrateText(Double(bitrate))))
                }
                if let fps = try? await videoTrack.load(.nominalFrameRate), fps > 0 {
                    videoRows.append(.init(label: "FPS", value: String(format: "%.2f", fps)))
                }
            }
            if let audioTrack = tracks.first(where: { $0.mediaType == .audio }) {
                if let codec = await codecText(for: audioTrack) {
                    audioRows.append(.init(label: "Codec", value: codec))
                }
                if let bitrate = try? await audioTrack.load(.estimatedDataRate), bitrate > 0 {
                    audioRows.append(.init(label: "Bitrate", value: bitrateText(Double(bitrate))))
                }
            }
        }

        var captureRows: [MediaMetadataRow] = []
        if let date = await videoCaptureDate(for: item.url) {
            captureRows.append(.init(label: "Created", value: date.formatted(date: .abbreviated, time: .standard)))
        }

        return MediaMetadata(sections: [
            .init(title: "File", rows: fileRows),
            .init(title: "Video", rows: videoRows),
            .init(title: "Audio", rows: audioRows),
            .init(title: "Capture", rows: captureRows),
        ].filter { !$0.rows.isEmpty })
    }

    private static func fileRows(for item: FileItem) -> [MediaMetadataRow] {
        var rows = [
            MediaMetadataRow(label: "Kind", value: item.kind),
            MediaMetadataRow(label: "Size", value: item.sizeText),
        ]
        if item.modified != .distantPast {
            rows.append(.init(label: "Modified", value: item.modified.formatted(date: .abbreviated, time: .shortened)))
        }
        return rows
    }

    private static func imageCaptureDate(for url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        return imageCaptureDate(properties: properties)
    }

    private static func imageCaptureDate(properties: [CFString: Any]) -> Date? {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let candidates = [
            stringValue(exif[kCGImagePropertyExifDateTimeOriginal]),
            stringValue(exif[kCGImagePropertyExifDateTimeDigitized]),
            stringValue(tiff[kCGImagePropertyTIFFDateTime]),
        ].compactMap { $0 }
        return candidates.lazy.compactMap(parseMetadataDate).first
    }

    private static func videoCaptureDate(for url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        for item in metadata {
            if item.commonKey == .commonKeyCreationDate,
               let value = try? await item.load(.stringValue),
               let date = parseMetadataDate(value) {
                return date
            }
        }
        return nil
    }

    private static func videoSizeText(for track: AVAssetTrack) async -> String? {
        guard let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else {
            return nil
        }
        let transformed = naturalSize.applying(transform)
        return "\(Int(abs(transformed.width))) x \(Int(abs(transformed.height)))"
    }

    private static func codecText(for track: AVAssetTrack) async -> String? {
        guard let descriptions = try? await track.load(.formatDescriptions),
              let description = descriptions.first else {
            return nil
        }
        return fourCCString(CMFormatDescriptionGetMediaSubType(description))
    }

    private static func bitrateText(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.1f Mbps", bitsPerSecond / 1_000_000)
        }
        return String(format: "%.0f Kbps", bitsPerSecond / 1_000)
    }

    private static func durationText(_ duration: CMTime) -> String {
        let seconds = max(CMTimeGetSeconds(duration), 0)
        guard seconds.isFinite else { return "Unknown" }
        let wholeSeconds = Int(seconds.rounded())
        let hours = wholeSeconds / 3600
        let minutes = (wholeSeconds % 3600) / 60
        let remainingSeconds = wholeSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    private static func parseMetadataDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in [
            "yyyy:MM:dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd HH:mm:ss",
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return ISO8601DateFormatter().date(from: trimmed)
    }

    private static func coordinate(from gps: [CFString: Any]) -> String? {
        guard var latitude = doubleValue(gps[kCGImagePropertyGPSLatitude]),
              var longitude = doubleValue(gps[kCGImagePropertyGPSLongitude]) else {
            return nil
        }
        if stringValue(gps[kCGImagePropertyGPSLatitudeRef])?.uppercased() == "S" {
            latitude *= -1
        }
        if stringValue(gps[kCGImagePropertyGPSLongitudeRef])?.uppercased() == "W" {
            longitude *= -1
        }
        return String(format: "%.5f, %.5f", latitude, longitude)
    }

    private static func appendStringRow(
        _ rows: inout [MediaMetadataRow],
        label: String,
        value: Any?
    ) {
        guard let value = stringValue(value), !value.isEmpty else { return }
        rows.append(.init(label: label, value: value))
    }

    private static func appendNumberRow(
        _ rows: inout [MediaMetadataRow],
        label: String,
        value: Any?,
        suffix: String = ""
    ) {
        guard let number = doubleValue(value) else { return }
        rows.append(.init(label: label, value: String(format: "%.0f%@", number, suffix)))
    }

    private static func appendApertureRow(_ rows: inout [MediaMetadataRow], value: Any?) {
        guard let number = doubleValue(value) else { return }
        rows.append(.init(label: "Aperture", value: String(format: "f/%.1f", number)))
    }

    private static func appendExposureRow(_ rows: inout [MediaMetadataRow], value: Any?) {
        guard let seconds = doubleValue(value), seconds > 0 else { return }
        if seconds < 1 {
            rows.append(.init(label: "Shutter", value: "1/\(Int((1 / seconds).rounded())) s"))
        } else {
            rows.append(.init(label: "Shutter", value: String(format: "%.1f s", seconds)))
        }
    }

    private static func appendFocalLengthRow(_ rows: inout [MediaMetadataRow], value: Any?) {
        guard let millimeters = doubleValue(value) else { return }
        rows.append(.init(label: "Focal Length", value: String(format: "%.0f mm", millimeters)))
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Float { return Double(value) }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let values = value as? [Any], let first = values.first {
            return doubleValue(first)
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff),
        ]
        let raw = String(bytes: bytes, encoding: .macOSRoman) ?? "\(code)"
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "hvc1", "hev1": return "HEVC"
        case "avc1": return "H.264"
        case "mp4a": return "AAC"
        default: return raw
        }
    }
}
