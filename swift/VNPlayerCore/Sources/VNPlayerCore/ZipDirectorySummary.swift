import Foundation

/// The few facts about an archive that must come from the End Of Central Directory
/// record rather than from iterating entries.
///
/// Why this exists at all, given we vendor a ZIP library:
///
/// 1. **Encrypted archives look empty.** ZIPFoundation's `Entry` initialiser returns nil
///    for an encrypted entry, so the archive simply yields fewer entries -- possibly
///    none. Without the declared count we would tell the user "This doesn't look like a
///    Ren'Py game" about a perfectly good game they happen to have password-protected.
/// 2. **Multi-disk archives** need the disk numbers, which the library does not surface.
/// 3. `totalNumberOfEntriesInCentralDirectory` is `internal` in ZIPFoundation, and
///    patching a vendored dependency to widen it would put us in the business of
///    maintaining a fork. Reading 22 bytes ourselves is cheaper and drifts less.
///
/// This reads the trailer only. It is not a second ZIP parser -- it never touches entry
/// data, never decompresses, and cannot disagree with ZIPFoundation about file contents.
public struct ZipDirectorySummary: Equatable {
    /// How many entries the archive says it has.
    public let declaredEntryCount: UInt64
    /// Non-zero means the archive is one volume of a multi-part set.
    public let diskNumber: UInt32
    /// The disk the central directory starts on. Must equal `diskNumber`.
    public let centralDirectoryDiskNumber: UInt32
    /// True when the trailer REQUIRED ZIP64 records to express its values.
    ///
    /// Not "the archive uses ZIP64 anywhere": an archive can carry ZIP64 extra fields on
    /// individual entries while its end-of-central-directory record stays in the classic
    /// form. This flag is about the trailer this type parses, and nothing else. Named
    /// carefully because the first version was called `isZip64`, and a test written
    /// against that name asserted something the field never claimed.
    public let usedZip64Trailer: Bool

    public var isMultiDisk: Bool {
        diskNumber != 0 || centralDirectoryDiskNumber != 0
    }
}

public enum ZipDirectorySummaryError: Error, Equatable {
    /// No End Of Central Directory signature in the last 64 KiB + 22 bytes. Either not a
    /// zip at all, or truncated.
    case noEndOfCentralDirectory
    case unreadable
    case malformedZip64Record
}

public enum ZipDirectoryReader {

    private static let eocdSignature: UInt32 = 0x0605_4b50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4b50
    private static let zip64EocdSignature: UInt32 = 0x0606_4b50

    /// The EOCD is 22 bytes plus a comment of up to 65535, so it lives somewhere in the
    /// last 65557 bytes. Scanning backwards from the end finds it.
    private static let maxTrailerLength = 22 + 65535

    public static func read(contentsOf url: URL) throws -> ZipDirectorySummary {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ZipDirectorySummaryError.unreadable
        }
        defer { try? handle.close() }

        let fileSize: UInt64
        do {
            fileSize = try handle.seekToEnd()
        } catch {
            throw ZipDirectorySummaryError.unreadable
        }

        let trailerLength = Int(min(fileSize, UInt64(maxTrailerLength)))
        guard trailerLength >= 22 else { throw ZipDirectorySummaryError.noEndOfCentralDirectory }

        let trailerStart = fileSize - UInt64(trailerLength)
        try? handle.seek(toOffset: trailerStart)
        guard let trailer = try? handle.read(upToCount: trailerLength), trailer.count == trailerLength else {
            throw ZipDirectorySummaryError.unreadable
        }

        // Scan backwards: a comment could itself contain the signature bytes, and the
        // LAST occurrence that leaves room for a full record is the real one.
        var eocdOffset: Int?
        var index = trailerLength - 22
        while index >= 0 {
            if readUInt32(trailer, index) == eocdSignature {
                eocdOffset = index
                break
            }
            index -= 1
        }

        guard let eocd = eocdOffset else {
            throw ZipDirectorySummaryError.noEndOfCentralDirectory
        }

        let diskNumber16 = readUInt16(trailer, eocd + 4)
        let cdDiskNumber16 = readUInt16(trailer, eocd + 6)
        let entryCount16 = readUInt16(trailer, eocd + 10)

        // Any of these saturated means the real values are in a ZIP64 record.
        let needsZip64 = entryCount16 == 0xFFFF
            || diskNumber16 == 0xFFFF
            || cdDiskNumber16 == 0xFFFF
            || readUInt32(trailer, eocd + 12) == 0xFFFF_FFFF
            || readUInt32(trailer, eocd + 16) == 0xFFFF_FFFF

        guard needsZip64 else {
            return ZipDirectorySummary(
                declaredEntryCount: UInt64(entryCount16),
                diskNumber: UInt32(diskNumber16),
                centralDirectoryDiskNumber: UInt32(cdDiskNumber16),
                usedZip64Trailer: false
            )
        }

        // The ZIP64 locator sits immediately before the EOCD.
        let locatorOffset = eocd - 20
        guard locatorOffset >= 0, readUInt32(trailer, locatorOffset) == zip64LocatorSignature else {
            throw ZipDirectorySummaryError.malformedZip64Record
        }

        let zip64RecordOffset = readUInt64(trailer, locatorOffset + 8)
        guard zip64RecordOffset < fileSize else {
            throw ZipDirectorySummaryError.malformedZip64Record
        }

        try? handle.seek(toOffset: zip64RecordOffset)
        guard let record = try? handle.read(upToCount: 56), record.count >= 56,
              readUInt32(record, 0) == zip64EocdSignature else {
            throw ZipDirectorySummaryError.malformedZip64Record
        }

        return ZipDirectorySummary(
            declaredEntryCount: readUInt64(record, 32),
            diskNumber: readUInt32(record, 16),
            centralDirectoryDiskNumber: readUInt32(record, 20),
            usedZip64Trailer: true
        )
    }

    // ZIP is little-endian throughout. These read from a Data whose indices start at 0
    // because every caller passes a freshly-created Data, but be explicit anyway --
    // Data slices keep their parent's indices and that has bitten better code than this.

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        guard base + 2 <= data.endIndex else { return 0 }
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        guard base + 4 <= data.endIndex else { return 0 }
        var value: UInt32 = 0
        for i in (0..<4).reversed() {
            value = (value << 8) | UInt32(data[base + i])
        }
        return value
    }

    private static func readUInt64(_ data: Data, _ offset: Int) -> UInt64 {
        let base = data.startIndex + offset
        guard base + 8 <= data.endIndex else { return 0 }
        var value: UInt64 = 0
        for i in (0..<8).reversed() {
            value = (value << 8) | UInt64(data[base + i])
        }
        return value
    }
}
