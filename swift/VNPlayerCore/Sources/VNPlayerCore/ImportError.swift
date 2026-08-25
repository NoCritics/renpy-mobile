import Foundation

/// Every way an import can fail, each with a message a non-developer can act on.
///
/// This is an enum with a `userMessage` rather than a thrown string because the M2 spec
/// makes it a requirement: "Every extractor rejection must be a distinct, user-readable
/// reason. A generic 'import failed' is a defect, not a fallback." Making the cases
/// exhaustive in the type is what stops a future `default:` from quietly reintroducing
/// one.
public enum ImportError: Error, Equatable {
    case cannotOpenArchive
    case notAZipArchive
    case truncatedArchive
    case multiDiskArchive
    /// Entries were declared but could not be read. ZIPFoundation skips encrypted
    /// entries silently, so this is where password-protected archives land -- see
    /// `userMessage` for why the two causes share one message.
    case entriesUnreadable(declared: UInt64, readable: Int)
    case unsupportedCompressionMethod(entry: String)
    case unsafePath(entry: String)
    case symlinkNotAllowed(entry: String)
    case duplicateEntry(path: String)
    case tooManyEntries(count: UInt64, limit: Int)
    case archiveTooLarge(bytes: Int64, limit: Int64)
    case entryTooLarge(entry: String, bytes: Int64, limit: Int64)
    case suspiciousCompressionRatio(entry: String, ratio: Double)
    case checksumMismatch(entry: String)
    case insufficientSpace(needed: Int64, available: Int64)
    case notARenpyGame
    case needsRenpy7
    case cancelled
    case writeFailed(path: String)

    public var userMessage: String {
        switch self {
        case .cannotOpenArchive:
            return "That file could not be opened."
        case .notAZipArchive:
            return "That doesn't look like a .zip file."
        case .truncatedArchive:
            return "This archive appears to be incomplete. Try downloading it again."
        case .multiDiskArchive:
            return "This archive is split across several files, which isn't supported. "
                 + "Combine it on a computer first."
        case .entriesUnreadable:
            // Deliberately covers two causes in one sentence. ZIPFoundation cannot tell
            // us WHICH entries it skipped or why -- an encrypted entry and a malformed
            // one both simply fail to construct. Claiming "password-protected" when the
            // archive is actually damaged would send the user hunting for a password
            // that does not exist, so the message names both and suggests an action that
            // works for either.
            return "This archive is password-protected or damaged. "
                 + "Try unzipping it on a computer first."
        case .unsupportedCompressionMethod(let entry):
            return "This archive uses a compression method we can't read (\(entry)). "
                 + "Try unzipping it on a computer and re-zipping it."
        case .unsafePath(let entry):
            return "This archive contains an unsafe file path (\(entry)) and was not imported."
        case .symlinkNotAllowed(let entry):
            return "This archive contains a shortcut we can't safely follow (\(entry))."
        case .duplicateEntry(let path):
            return "This archive contains two files with the same name (\(path))."
        case .tooManyEntries(let count, let limit):
            return "This archive contains \(count) files, more than the \(limit) we allow."
        case .archiveTooLarge(let bytes, let limit):
            return "This game is \(Self.gib(bytes)) unpacked, more than the \(Self.gib(limit)) limit."
        case .entryTooLarge(let entry, let bytes, let limit):
            return "A file in this archive (\(entry)) is \(Self.gib(bytes)), "
                 + "more than the \(Self.gib(limit)) limit."
        case .suspiciousCompressionRatio(let entry, _):
            return "A file in this archive (\(entry)) expands far more than expected, "
                 + "which usually means the archive is malicious."
        case .checksumMismatch(let entry):
            return "This archive appears to be damaged (\(entry) failed its checksum). "
                 + "Try downloading it again."
        case .insufficientSpace(let needed, let available):
            return "Not enough space: this needs \(Self.mib(needed)) "
                 + "and \(Self.mib(available)) is free."
        case .notARenpyGame:
            return "This doesn't look like a Ren'Py game — no game folder was found inside."
        case .needsRenpy7:
            return "This game needs Ren'Py 7, which isn't supported yet."
        case .cancelled:
            return "Import cancelled."
        case .writeFailed(let path):
            return "Could not write \(path). The device may be out of space."
        }
    }

    static func mib(_ bytes: Int64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    static func gib(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 1
            ? String(format: "%.1f GB", gb)
            : String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}
