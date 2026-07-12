import AppKit
import CoreText
import Foundation

struct AdditionalFileToolError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private enum SystemProcess {
    static func output(executable: String, arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let combinedOutput = Pipe()
        process.standardOutput = combinedOutput
        process.standardError = combinedOutput

        try process.run()
        let output = combinedOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AdditionalFileToolError(message: processFailure(
                executable: executable,
                output: output,
                error: Data()
            ))
        }
        return output
    }

    static func output(
        executable: String,
        arguments: [String],
        to destination: URL
    ) throws {
        let manager = FileManager.default
        guard manager.createFile(atPath: destination.path, contents: nil),
              let outputHandle = try? FileHandle(forWritingTo: destination) else {
            throw AdditionalFileToolError(message: "Couldn’t create “\(destination.lastPathComponent)”.")
        }
        defer { try? outputHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let standardError = Pipe()
        process.standardOutput = outputHandle
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let error = standardError.fileHandleForReading.readDataToEndOfFile()
            try? manager.removeItem(at: destination)
            throw AdditionalFileToolError(message: processFailure(
                executable: executable,
                output: Data(),
                error: error
            ))
        }
    }

    private static func processFailure(executable: String, output: Data, error: Data) -> String {
        let detail = [output, error]
            .compactMap { String(data: $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let tool = URL(fileURLWithPath: executable).lastPathComponent
        return detail.isEmpty ? "\(tool) could not complete this action." : detail
    }
}

enum DiskImageTools {
    static func mount(_ url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            _ = try SystemProcess.output(
                executable: "/usr/bin/hdiutil",
                arguments: ["attach", "-nobrowse", url.path]
            )
        }.value
    }

    static func sha256(_ url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let data = try SystemProcess.output(
                executable: "/usr/bin/shasum",
                arguments: ["-a", "256", url.path]
            )
            guard let line = String(data: data, encoding: .utf8)?.split(whereSeparator: \.isWhitespace).first else {
                throw AdditionalFileToolError(message: "Couldn’t calculate a SHA-256 checksum.")
            }
            return String(line)
        }.value
    }
}

struct InstallerPackageDetails: Sendable {
    let name: String
    let kind: String
    let size: String
    let path: String

    var clipboardText: String {
        [
            "Installer: \(name)",
            "Kind: \(kind)",
            "Size: \(size)",
            "Path: \(path)",
        ].joined(separator: "\n")
    }
}

enum InstallerTools {
    static func details(for item: FileItem) -> InstallerPackageDetails? {
        guard item.isInstallerPackage else { return nil }
        return InstallerPackageDetails(
            name: item.name,
            kind: item.kind,
            size: item.sizeText,
            path: item.url.path
        )
    }
}

enum PresentationTools {
    static func exportToPDFUsingKeynote(at url: URL) async throws -> URL {
        try await MainActor.run {
            guard NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.iWork.Keynote"
            ) != nil else {
                throw AdditionalFileToolError(message: "Keynote is required to export this presentation to PDF.")
            }

            let baseName = url.deletingPathExtension().lastPathComponent
            let destination = FileOperations.uniqueDestination(
                for: url.deletingLastPathComponent().appendingPathComponent("\(baseName)-converted.pdf")
            )
            let scriptSource = """
            set sourceFile to POSIX file "\(escapedAppleScriptPath(url.path))"
            set destinationFile to POSIX file "\(escapedAppleScriptPath(destination.path))"
            tell application id "com.apple.iWork.Keynote"
                set sourceDocument to open sourceFile
                export sourceDocument to destinationFile as PDF
                close sourceDocument saving no
            end tell
            """

            var error: NSDictionary?
            let result = NSAppleScript(source: scriptSource)?.executeAndReturnError(&error)
            guard result != nil,
                  FileManager.default.fileExists(atPath: destination.path) else {
                let message = error?[NSAppleScript.errorMessage] as? String
                throw AdditionalFileToolError(
                    message: message ?? "Keynote couldn’t export “\(url.lastPathComponent)” to PDF."
                )
            }
            return destination
        }
    }
}

struct FontFileDetails: Sendable {
    let name: String
    let family: String?
    let postScriptName: String?
    let path: String

    var clipboardText: String {
        [
            "Font: \(name)",
            "Family: \(family ?? "Not available")",
            "PostScript Name: \(postScriptName ?? "Not available")",
            "Path: \(path)",
        ].joined(separator: "\n")
    }
}

enum FontTools {
    static func details(for item: FileItem) -> FontFileDetails? {
        guard item.isFontFile else { return nil }
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(item.url as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first else {
            return FontFileDetails(
                name: item.url.deletingPathExtension().lastPathComponent,
                family: nil,
                postScriptName: nil,
                path: item.url.path
            )
        }

        let font = CTFontCreateWithFontDescriptor(descriptor, 0, nil)
        return FontFileDetails(
            name: CTFontCopyFullName(font) as String,
            family: CTFontCopyFamilyName(font) as String,
            postScriptName: CTFontCopyPostScriptName(font) as String,
            path: item.url.path
        )
    }

    static func install(at url: URL) throws {
        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(url as CFURL, .user, &error) else {
            let message = error?.takeRetainedValue().localizedDescription
                ?? "Couldn’t install “\(url.lastPathComponent)”."
            throw AdditionalFileToolError(message: message)
        }
    }
}

struct EBookDetails: Sendable {
    let title: String
    let author: String?
    let language: String?
    let path: String

    var clipboardText: String {
        [
            "Book: \(title)",
            "Author: \(author ?? "Not available")",
            "Language: \(language ?? "Not available")",
            "Path: \(path)",
        ].joined(separator: "\n")
    }
}

enum EBookTools {
    static func details(at url: URL) async throws -> EBookDetails {
        try await Task.detached(priority: .userInitiated) {
            let container = try SystemProcess.output(
                executable: "/usr/bin/unzip",
                arguments: ["-p", url.path, "META-INF/container.xml"]
            )
            let packagePath = try EPUBContainerParser.packagePath(from: container)
            let package = try SystemProcess.output(
                executable: "/usr/bin/unzip",
                arguments: ["-p", url.path, packagePath]
            )
            let metadata = try EPUBMetadataParser.metadata(from: package)
            return EBookDetails(
                title: metadata.title ?? url.deletingPathExtension().lastPathComponent,
                author: metadata.author,
                language: metadata.language,
                path: url.path
            )
        }.value
    }
}

struct ContactCardDetails: Sendable {
    let name: String
    let organization: String?
    let emails: [String]
    let phones: [String]

    var clipboardText: String {
        var lines = ["Contact: \(name)"]
        if let organization { lines.append("Organization: \(organization)") }
        if !emails.isEmpty { lines.append("Email: \(emails.joined(separator: ", "))") }
        if !phones.isEmpty { lines.append("Phone: \(phones.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }
}

enum ContactCardTools {
    static func details(at url: URL) async throws -> ContactCardDetails {
        try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
                throw AdditionalFileToolError(message: "“\(url.lastPathComponent)” can’t be read as a contact card.")
            }

            let lines = unfoldedLines(in: text)
            var name: String?
            var organization: String?
            var emails: [String] = []
            var phones: [String] = []

            for line in lines {
                guard let separator = line.firstIndex(of: ":") else { continue }
                let key = line[..<separator]
                    .split(separator: ";", maxSplits: 1)
                    .first?
                    .uppercased()
                let value = decodedValue(String(line[line.index(after: separator)...]))
                switch key {
                case "FN": name = value
                case "ORG": organization = value
                case "EMAIL": emails.append(value)
                case "TEL": phones.append(value)
                default: break
                }
            }

            return ContactCardDetails(
                name: name ?? url.deletingPathExtension().lastPathComponent,
                organization: organization,
                emails: emails,
                phones: phones
            )
        }.value
    }

    private static func unfoldedLines(in text: String) -> [String] {
        text.components(separatedBy: .newlines).reduce(into: [String]()) { lines, line in
            if line.hasPrefix(" ") || line.hasPrefix("\t"), !lines.isEmpty {
                lines[lines.count - 1] += line.trimmingCharacters(in: .whitespaces)
            } else {
                lines.append(line)
            }
        }
    }

    private static func decodedValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}

enum ArchiveTools {
    static func extract(at url: URL) async throws -> URL {
        if url.pathExtension.localizedCaseInsensitiveCompare("zip") == .orderedSame {
            return try await FileOperations.extractZip(url)
        }

        return try await Task.detached(priority: .userInitiated) {
            let folder = FileOperations.uniqueDestination(for: extractionFolder(for: url))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            do {
                if isTarArchive(url) {
                    _ = try SystemProcess.output(
                        executable: "/usr/bin/tar",
                        arguments: ["-xf", url.path, "-C", folder.path]
                    )
                } else {
                    let output = folder.appendingPathComponent(uncompressedName(for: url))
                    let executable = try decompressor(for: url)
                    try SystemProcess.output(executable: executable, arguments: ["-cd", url.path], to: output)
                }
                return folder
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }.value
    }

    static func entries(in url: URL) async throws -> [String] {
        if url.pathExtension.localizedCaseInsensitiveCompare("zip") == .orderedSame {
            return try await ZipArchiveListingReader.listing(for: url).entries.map(\.path)
        }

        return try await Task.detached(priority: .userInitiated) {
            if isTarArchive(url) {
                let data = try SystemProcess.output(executable: "/usr/bin/tar", arguments: ["-tf", url.path])
                return String(data: data, encoding: .utf8)?
                    .split(whereSeparator: \.isNewline)
                    .map(String.init) ?? []
            }
            _ = try decompressor(for: url)
            return [uncompressedName(for: url)]
        }.value
    }

    private static func isTarArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".tar")
            || name.hasSuffix(".tar.gz")
            || name.hasSuffix(".tar.bz2")
            || name.hasSuffix(".tar.xz")
            || name.hasSuffix(".tgz")
            || name.hasSuffix(".tbz")
            || name.hasSuffix(".txz")
    }

    private static func extractionFolder(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("\(archiveBaseName(for: url)) Extracted")
    }

    private static func uncompressedName(for url: URL) -> String {
        archiveBaseName(for: url)
    }

    private static func archiveBaseName(for url: URL) -> String {
        let name = url.lastPathComponent
        let lowercaseName = name.lowercased()
        let suffixes = [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz", ".txz", ".tar", ".gz", ".bz2", ".xz"]
        guard let suffix = suffixes.first(where: { lowercaseName.hasSuffix($0) }) else {
            return url.deletingPathExtension().lastPathComponent
        }
        return String(name.dropLast(suffix.count))
    }

    private static func decompressor(for url: URL) throws -> String {
        switch url.pathExtension.lowercased() {
        case "gz": "/usr/bin/gzip"
        case "bz2": "/usr/bin/bzip2"
        case "xz": "/usr/bin/xz"
        default:
            throw AdditionalFileToolError(message: "“\(url.lastPathComponent)” is not a supported archive.")
        }
    }
}

private func escapedAppleScriptPath(_ path: String) -> String {
    path
        .replacing("\\", with: "\\\\")
        .replacing("\"", with: "\\\"")
}

private final class EPUBContainerParser: NSObject, XMLParserDelegate {
    private(set) var packagePath: String?

    static func packagePath(from data: Data) throws -> String {
        let delegate = EPUBContainerParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let packagePath = delegate.packagePath, !packagePath.isEmpty else {
            throw AdditionalFileToolError(message: "This EPUB doesn’t contain readable package metadata.")
        }
        return packagePath
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "rootfile" || qName == "rootfile" else { return }
        packagePath = attributeDict["full-path"]
    }
}

private final class EPUBMetadataParser: NSObject, XMLParserDelegate {
    private(set) var title: String?
    private(set) var author: String?
    private(set) var language: String?
    private var activeElement: String?
    private var currentText = ""

    static func metadata(from data: Data) throws -> EPUBMetadataParser {
        let delegate = EPUBMetadataParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw AdditionalFileToolError(message: "This EPUB has unreadable book metadata.")
        }
        return delegate
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = (qName ?? elementName).lowercased()
        guard name.hasSuffix("title") || name.hasSuffix("creator") || name.hasSuffix("language") else {
            return
        }
        activeElement = name
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard let activeElement else { return }
        let closingName = (qName ?? elementName).lowercased()
        guard closingName == activeElement else { return }
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            if activeElement.hasSuffix("title"), title == nil { title = value }
            if activeElement.hasSuffix("creator"), author == nil { author = value }
            if activeElement.hasSuffix("language"), language == nil { language = value }
        }
        self.activeElement = nil
        currentText = ""
    }
}
