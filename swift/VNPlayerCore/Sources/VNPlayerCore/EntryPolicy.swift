import Foundation

/// Caps on what an archive is allowed to be. Stated as values rather than left to the
/// call site so the numbers are reviewable in one place and testable directly.
public struct ImportCaps: Equatable {
    public var maxEntries: Int
    public var maxTotalUncompressed: Int64
    public var maxEntryUncompressed: Int64
    /// A single entry expanding by more than this is a zip bomb, not a game asset.
    /// Real assets are already compressed (png, ogg, webp) and barely shrink; the
    /// compressible ones (rpy source, json) do not reach anywhere near this.
    public var maxCompressionRatio: Double

    /// The two size caps were guessed before anyone had measured a real visual novel.
    /// Reality, reported from the library this app exists to read: games run 4-8 GB, and
    /// their assets usually sit in one or two `.rpa` archives, so a SINGLE entry can pass
    /// 4 GiB on its own. The old numbers rejected those games outright -- the per-entry
    /// cap with "A file in this archive is 5.2 GB, more than the 4.0 GB limit", which is
    /// a true sentence about a limit that should never have applied.
    ///
    /// Raising them does not weaken the zip-bomb defence, because the total size was
    /// never what carried it:
    ///
    /// * `maxCompressionRatio` is the actual bomb check, and it is unchanged. Real game
    ///   assets are already compressed (png, ogg, webp, rpa) and barely shrink; a bomb
    ///   is defined by expanding absurdly, not by being large.
    /// * `maxEntries` is unchanged, and bounds the other bomb shape -- millions of tiny
    ///   files.
    /// * **Free space is the real limit, and it is checked separately** against the
    ///   volume's actual capacity before a byte is written, with a message naming both
    ///   numbers. Setting the total cap ABOVE any plausible phone means that check --
    ///   the one that can say something useful -- is the one that speaks.
    ///
    /// Extraction streams in 256 KiB chunks straight to a file handle, so a 6 GB entry
    /// costs 256 KiB of memory, not 6 GB. Size was never a memory question here.
    public static let `default` = ImportCaps(
        maxEntries: 100_000,
        maxTotalUncompressed: 64 * 1_073_741_824,
        maxEntryUncompressed: 16 * 1_073_741_824,
        maxCompressionRatio: 1000
    )

    public init(maxEntries: Int, maxTotalUncompressed: Int64, maxEntryUncompressed: Int64, maxCompressionRatio: Double) {
        self.maxEntries = maxEntries
        self.maxTotalUncompressed = maxTotalUncompressed
        self.maxEntryUncompressed = maxEntryUncompressed
        self.maxCompressionRatio = maxCompressionRatio
    }
}

/// What to do with one archive entry.
public enum EntryDisposition: Equatable {
    /// Write it, at this normalised relative path.
    case extract(String)
    /// Do not write it, and this is not an error -- desktop cruft (§7.3).
    case prune(String)
    /// It is a directory entry; create it and move on.
    case directory(String)
}

public enum EntryPolicy {

    // MARK: - Path sanitisation

    /// Normalise an archive path and reject anything that could escape the destination.
    ///
    /// Returns nil for entries that are safe but carry nothing (a bare "." or ""), and
    /// throws for entries that are actively unsafe. The distinction matters: an empty
    /// path is skipped quietly, a traversal aborts the whole import. A malicious archive
    /// that gets even one file outside the staging directory has won, so this fails the
    /// import rather than skipping the entry -- if an archive is trying, nothing else in
    /// it is trustworthy either.
    public static func sanitize(_ rawPath: String) throws -> String? {
        // Windows tools write backslashes. Treat them as separators rather than as
        // ordinary characters, or "..\\..\\x" sails straight through a check that only
        // looks for forward slashes.
        let unified = rawPath.replacingOccurrences(of: "\\", with: "/")

        if unified.hasPrefix("/") {
            throw ImportError.unsafePath(entry: rawPath)
        }

        // "C:/x" and "C:x" -- a drive-qualified path is absolute even without a slash.
        if unified.count >= 2 {
            let chars = Array(unified)
            if chars[1] == ":" && chars[0].isLetter {
                throw ImportError.unsafePath(entry: rawPath)
            }
        }

        if unified.unicodeScalars.contains(where: { $0.value == 0 }) {
            throw ImportError.unsafePath(entry: rawPath)
        }

        var components: [String] = []
        for component in unified.split(separator: "/", omittingEmptySubsequences: true) {
            let piece = String(component)

            if piece == "." { continue }
            if piece == ".." {
                // Not "pop the last component": an archive is not allowed to reference a
                // parent at all, even one it created itself. Resolving would let
                // "a/../../b" pass whenever "a" happened to exist.
                throw ImportError.unsafePath(entry: rawPath)
            }
            components.append(piece)
        }

        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    // MARK: - Pruning

    /// File extensions that cannot execute on iOS and are pure weight.
    private static let prunedExtensions: Set<String> = [
        "exe", "dll", "so", "dylib", "bat", "cmd", "command", "sh", "msi",
    ]

    /// Directories a Ren'Py PC distribution ships at its ROOT that the phone cannot use.
    private static let prunedRootDirectories: Set<String> = ["lib", "renpy"]

    /// Decide what happens to one entry.
    ///
    /// `relativePath` is already sanitised and is relative to the distribution root
    /// (i.e. the directory containing `game/`), because pruning is scoped to that root.
    ///
    /// The scoping is the important part. An earlier draft pruned any directory named
    /// `lib` at any depth, which would have silently gutted a game shipping
    /// `game/lib/`. Nothing inside `game/` is ever pruned, whatever it is called.
    public static func disposition(
        relativePath: String,
        isDirectory: Bool,
        pruneDesktopFiles: Bool
    ) -> EntryDisposition {
        if isDirectory {
            if pruneDesktopFiles, isPrunedRootDirectory(relativePath) {
                return .prune(relativePath)
            }
            return .directory(relativePath)
        }

        guard pruneDesktopFiles else { return .extract(relativePath) }

        let components = relativePath.split(separator: "/").map(String.init)

        // Sacred. Whatever is in here belongs to the game.
        if components.first == "game" { return .extract(relativePath) }

        if isPrunedRootDirectory(relativePath) { return .prune(relativePath) }

        let ext = (relativePath as NSString).pathExtension.lowercased()
        if prunedExtensions.contains(ext) { return .prune(relativePath) }

        // A macOS .app bundle is a directory tree; prune the whole thing.
        if components.contains(where: { $0.lowercased().hasSuffix(".app") }) {
            return .prune(relativePath)
        }

        return .extract(relativePath)
    }

    /// True when the path's FIRST component is a pruned root directory.
    private static func isPrunedRootDirectory(_ relativePath: String) -> Bool {
        guard let first = relativePath.split(separator: "/").first else { return false }
        return prunedRootDirectories.contains(String(first).lowercased())
    }

    // MARK: - Filename decoding

    /// Decode an entry's filename bytes, preferring correctness for the corpus this app
    /// will actually see.
    ///
    /// Order: UTF-8, then Shift-JIS, then whatever the library chose (CP437).
    ///
    /// The UTF-8 attempt comes first even when the archive does not set the UTF-8 flag,
    /// because most modern archives are UTF-8 regardless of the flag, and a strict UTF-8
    /// decode fails cleanly on non-UTF-8 bytes rather than producing plausible nonsense.
    ///
    /// Shift-JIS before CP437 is a deliberate bet, and it is worth being honest that it
    /// IS a bet: both can decode arbitrary high bytes, so for a non-ASCII, non-UTF-8
    /// name there is no way to be certain which was meant. Japanese visual novels are a
    /// large fraction of what this app will ever be pointed at, and a Windows-packed
    /// Japanese release is the overwhelmingly likely source of such a name. Getting it
    /// wrong turns an asset path into mojibake, which surfaces much later as a
    /// FileNotFoundError deep inside a running game rather than as an import error.
    /// Western archives are almost always pure ASCII, where UTF-8 succeeds and neither
    /// fallback is reached.
    public static func decodeFilename(
        utf8Attempt: String,
        shiftJISAttempt: String,
        libraryDefault: String
    ) -> String {
        if !utf8Attempt.isEmpty { return utf8Attempt }
        if !shiftJISAttempt.isEmpty { return shiftJISAttempt }
        return libraryDefault
    }
}
