import Foundation

struct ZipArchiveListing: Hashable {
    let entries: [ZipArchiveEntry]

    var fileCount: Int {
        entries.filter { !$0.isDirectory }.count
    }

    var folderCount: Int {
        entries.filter(\.isDirectory).count
    }

    var uncompressedSize: UInt64 {
        entries.reduce(0) { $0 + $1.uncompressedSize }
    }
}

struct ZipArchiveEntry: Identifiable, Hashable {
    let path: String
    let isDirectory: Bool
    let compressedSize: UInt64
    let uncompressedSize: UInt64

    var id: String { path }

    var name: String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.split(separator: "/").last.map(String.init) ?? path
    }

    var parentPath: String? {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let slash = trimmed.lastIndex(of: "/") else { return nil }
        return String(trimmed[..<slash])
    }

    var uncompressedSizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(uncompressedSize), countStyle: .file)
    }
}

enum ZipArchiveListingReader {
    private static let endOfCentralDirectorySignature: UInt32 = 0x06054b50
    private static let centralDirectoryHeaderSignature: UInt32 = 0x02014b50
    private static let maxEndRecordSearchLength: UInt64 = 65_557

    static func listing(for url: URL) async throws -> ZipArchiveListing {
        try await Task.detached(priority: .userInitiated) {
            try readListing(for: url)
        }.value
    }

    static func listingSync(for url: URL) throws -> ZipArchiveListing {
        try readListing(for: url)
    }

    private static func readListing(for url: URL) throws -> ZipArchiveListing {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22 else { throw ZipArchiveListingError.invalidArchive }

        let searchLength = min(fileSize, maxEndRecordSearchLength)
        try handle.seek(toOffset: fileSize - searchLength)
        let tail = try handle.read(upToCount: Int(searchLength)) ?? Data()
        guard let endOffset = tail.lastLittleEndianSignatureOffset(endOfCentralDirectorySignature) else {
            throw ZipArchiveListingError.invalidArchive
        }

        let entryCount = try tail.uint16LE(at: endOffset + 10)
        let centralDirectorySize = try tail.uint32LE(at: endOffset + 12)
        let centralDirectoryOffset = try tail.uint32LE(at: endOffset + 16)
        guard entryCount != UInt16.max,
              centralDirectorySize != UInt32.max,
              centralDirectoryOffset != UInt32.max else {
            throw ZipArchiveListingError.unsupportedZip64
        }

        try handle.seek(toOffset: UInt64(centralDirectoryOffset))
        let directory = try handle.read(upToCount: Int(centralDirectorySize)) ?? Data()
        var cursor = 0
        var entries: [ZipArchiveEntry] = []
        entries.reserveCapacity(Int(entryCount))

        while cursor + 46 <= directory.count, entries.count < Int(entryCount) {
            guard try directory.uint32LE(at: cursor) == centralDirectoryHeaderSignature else {
                throw ZipArchiveListingError.invalidArchive
            }

            let flags = try directory.uint16LE(at: cursor + 8)
            let compressedSize = UInt64(try directory.uint32LE(at: cursor + 20))
            let uncompressedSize = UInt64(try directory.uint32LE(at: cursor + 24))
            let fileNameLength = Int(try directory.uint16LE(at: cursor + 28))
            let extraLength = Int(try directory.uint16LE(at: cursor + 30))
            let commentLength = Int(try directory.uint16LE(at: cursor + 32))
            let nameStart = cursor + 46
            let nameEnd = nameStart + fileNameLength
            guard nameEnd <= directory.count else { throw ZipArchiveListingError.invalidArchive }

            let nameData = directory.subdata(in: nameStart..<nameEnd)
            let path = decodeFileName(nameData, isUTF8: flags & 0x0800 != 0)
            if !path.isEmpty {
                entries.append(ZipArchiveEntry(
                    path: path,
                    isDirectory: path.hasSuffix("/"),
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize
                ))
            }

            cursor = nameEnd + extraLength + commentLength
        }

        return ZipArchiveListing(entries: entries)
    }

    private static func decodeFileName(_ data: Data, isUTF8: Bool) -> String {
        if isUTF8, let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .macOSRoman)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }
}

enum ZipArchiveListingError: LocalizedError {
    case invalidArchive
    case unsupportedZip64

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            return "Could not read this ZIP archive."
        case .unsupportedZip64:
            return "ZIP64 archive previews are not supported yet."
        }
    }
}

private extension Data {
    func uint16LE(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { throw ZipArchiveListingError.invalidArchive }
        return UInt16(self[offset])
            | (UInt16(self[offset + 1]) << 8)
    }

    func uint32LE(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { throw ZipArchiveListingError.invalidArchive }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func lastLittleEndianSignatureOffset(_ signature: UInt32) -> Int? {
        guard count >= 4 else { return nil }
        for offset in stride(from: count - 4, through: 0, by: -1) {
            if (try? uint32LE(at: offset)) == signature {
                return offset
            }
        }
        return nil
    }
}
