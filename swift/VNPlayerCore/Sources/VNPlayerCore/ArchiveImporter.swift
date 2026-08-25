import Foundation

// These sources build two ways: as a SwiftPM target (where ZIPFoundation is a separate
// module and must be imported) and compiled directly into the iOS app target alongside
// ZIPFoundation's own sources (where it is not a module at all, and importing it is an
// error). canImport picks correctly in both, without a second copy of the file.
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

/// What an archive turned out to contain, decided before a single byte is written.
public struct ImportPlan {
    public let identity: GameIdentity
    /// Path prefix of the directory containing `game/`; "" when it is the archive root.
    public let distributionRoot: String
    public let engine: DetectedEngine
    /// Entries that will actually be written, after pruning.
    public let extractCount: Int
    /// Bytes those entries occupy once expanded. What the free-space check needs.
    public let totalUncompressed: Int64
    /// Bytes pruning avoided writing. Shown to the user, because "saved 180 MB" is the
    /// only way pruning stops looking like the app losing their files.
    public let prunedBytes: Int64
}

public struct ImportResult {
    public let identity: GameIdentity
    public let engine: DetectedEngine
    public let stagingGameDirectory: URL
    public let bytesWritten: Int64
    public let coverRelativePath: String?
}

public final class ArchiveImporter {

    private let caps: ImportCaps
    private let pruneDesktopFiles: Bool

    public init(caps: ImportCaps = .default, pruneDesktopFiles: Bool = true) {
        self.caps = caps
        self.pruneDesktopFiles = pruneDesktopFiles
    }

    // MARK: - Phase 1: inspect and validate

    /// Reads the archive's directory and decides everything that can be decided without
    /// writing. Every §7.3 rejection happens here, so a malicious or broken archive is
    /// refused before it has touched the filesystem.
    public func plan(archiveURL: URL, archiveFileName: String) throws -> ImportPlan {
        let summary: ZipDirectorySummary
        do {
            summary = try ZipDirectoryReader.read(contentsOf: archiveURL)
        } catch ZipDirectorySummaryError.noEndOfCentralDirectory {
            throw ImportError.notAZipArchive
        } catch ZipDirectorySummaryError.malformedZip64Record {
            throw ImportError.truncatedArchive
        } catch {
            throw ImportError.cannotOpenArchive
        }

        if summary.isMultiDisk { throw ImportError.multiDiskArchive }

        if summary.declaredEntryCount > UInt64(caps.maxEntries) {
            throw ImportError.tooManyEntries(count: summary.declaredEntryCount, limit: caps.maxEntries)
        }

        guard let archive = try? Archive(url: archiveURL, accessMode: .read) else {
            throw ImportError.cannotOpenArchive
        }

        var allPaths: [String] = []
        var seenLowercased = Set<String>()
        var readableCount = 0
        var totalUncompressed: Int64 = 0

        for entry in archive {
            readableCount += 1

            let rawPath = decodedPath(of: entry)
            guard let safePath = try EntryPolicy.sanitize(rawPath) else { continue }

            if entry.type == .symlink {
                throw ImportError.symlinkNotAllowed(entry: safePath)
            }
            if entry.type == .file, entry.isCompressed == false, entry.compressedSize > 0,
               entry.uncompressedSize == 0 {
                // A stored entry claiming zero expanded size but non-zero stored size is
                // malformed; refusing beats writing a truncated asset.
                throw ImportError.truncatedArchive
            }

            // Case-insensitive duplicate check: iOS's filesystem folds case, so
            // "Game/x.png" and "game/X.png" are the same destination. Letting the second
            // silently win is how a crafted archive overwrites a file we already vetted.
            let key = safePath.lowercased()
            if entry.type == .file {
                if seenLowercased.contains(key) {
                    throw ImportError.duplicateEntry(path: safePath)
                }
                seenLowercased.insert(key)
            }

            allPaths.append(safePath)

            guard entry.type == .file else { continue }

            let uncompressed = Int64(entry.uncompressedSize)
            if uncompressed > caps.maxEntryUncompressed {
                throw ImportError.entryTooLarge(
                    entry: safePath, bytes: uncompressed, limit: caps.maxEntryUncompressed)
            }

            let compressed = Int64(entry.compressedSize)
            if compressed > 0 {
                let ratio = Double(uncompressed) / Double(compressed)
                if ratio > caps.maxCompressionRatio {
                    throw ImportError.suspiciousCompressionRatio(entry: safePath, ratio: ratio)
                }
            }

            totalUncompressed += uncompressed
            if totalUncompressed > caps.maxTotalUncompressed {
                throw ImportError.archiveTooLarge(
                    bytes: totalUncompressed, limit: caps.maxTotalUncompressed)
            }
        }

        // ZIPFoundation's Entry init returns nil for encrypted entries, so they never
        // reach the loop above -- the archive simply appears to have fewer files. This
        // is the only place that discrepancy is visible, and without it a
        // password-protected game is reported as "not a Ren'Py game".
        if readableCount < Int(summary.declaredEntryCount) {
            throw ImportError.entriesUnreadable(
                declared: summary.declaredEntryCount, readable: readableCount)
        }

        if allPaths.isEmpty { throw ImportError.notARenpyGame }

        guard let root = EngineDetector.distributionRoot(relativePaths: allPaths) else {
            throw ImportError.notARenpyGame
        }

        let rootRelativePaths = allPaths.compactMap { relative($0, under: root) }

        let vcVersion = try? readVCVersion(archive: archive, root: root)
        let engine = EngineDetector.detect(
            relativePaths: rootRelativePaths, vcVersionContents: vcVersion)

        if engine == .renpy7 { throw ImportError.needsRenpy7 }

        // Recompute the byte totals over what survives pruning, which is what the free
        // space check actually needs. Doing it here rather than during extraction means
        // a game that only fits BECAUSE of pruning is not refused.
        var extractBytes: Int64 = 0
        var prunedBytes: Int64 = 0
        var extractCount = 0

        for entry in archive {
            guard entry.type == .file else { continue }
            let rawPath = decodedPath(of: entry)
            guard let safePath = try EntryPolicy.sanitize(rawPath),
                  let rel = relative(safePath, under: root) else { continue }

            let size = Int64(entry.uncompressedSize)
            switch EntryPolicy.disposition(
                relativePath: rel, isDirectory: false, pruneDesktopFiles: pruneDesktopFiles) {
            case .extract:
                extractBytes += size
                extractCount += 1
            case .prune:
                prunedBytes += size
            case .directory:
                break
            }
        }

        // Name the game after its DISTRIBUTION ROOT, not after the archive's single
        // top-level directory. Those coincide for the common "MyGame-1.2-pc/" layout,
        // and differ exactly where it matters: an archive whose root IS the game --
        // "game/script.rpy" at the top level -- has a single top-level directory called
        // "game", and calling the game "game" is useless. In that case the archive's own
        // filename is the only name we have.
        let rootName = plan_rootName(distributionRoot: root)
        let identity = GameIdentityDeriver.derive(
            topLevelDirectory: rootName,
            archiveFileName: archiveFileName
        )

        return ImportPlan(
            identity: identity,
            distributionRoot: root,
            engine: engine,
            extractCount: extractCount,
            totalUncompressed: extractBytes,
            prunedBytes: prunedBytes
        )
    }

    // MARK: - Phase 2: extract

    /// Writes the planned entries into `stagingDirectory`, which must already exist and
    /// should be empty.
    ///
    /// `isCancelled` is consulted per entry rather than per chunk: a single entry is
    /// bounded by `caps.maxEntryUncompressed`, and per-chunk checking measurably slows
    /// the common case of thousands of small files.
    @discardableResult
    public func extract(
        archiveURL: URL,
        plan: ImportPlan,
        to stagingDirectory: URL,
        progress: (Double) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> ImportResult {
        guard let archive = try? Archive(url: archiveURL, accessMode: .read) else {
            throw ImportError.cannotOpenArchive
        }

        let fm = FileManager.default
        var written: Int64 = 0
        var completed = 0
        var coverRelativePath: String?

        for entry in archive {
            if isCancelled() { throw ImportError.cancelled }

            let rawPath = decodedPath(of: entry)
            guard let safePath = try EntryPolicy.sanitize(rawPath),
                  let rel = relative(safePath, under: plan.distributionRoot) else { continue }

            let disposition = EntryPolicy.disposition(
                relativePath: rel,
                isDirectory: entry.type == .directory,
                pruneDesktopFiles: pruneDesktopFiles
            )

            switch disposition {
            case .prune:
                continue

            case .directory(let path):
                let target = stagingDirectory.appendingPathComponent(path, isDirectory: true)
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)

            case .extract(let path):
                guard entry.type == .file else { continue }

                let target = stagingDirectory.appendingPathComponent(path)
                let parent = target.deletingLastPathComponent()

                do {
                    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                } catch {
                    throw ImportError.writeFailed(path: path)
                }

                guard fm.createFile(atPath: target.path, contents: nil) else {
                    throw ImportError.writeFailed(path: path)
                }
                guard let handle = try? FileHandle(forWritingTo: target) else {
                    throw ImportError.writeFailed(path: path)
                }

                var checksum: CRC32 = 0
                do {
                    checksum = try archive.extract(entry, bufferSize: 256 * 1024, skipCRC32: false) { chunk in
                        handle.write(chunk)
                    }
                    try? handle.close()
                } catch let error as ImportError {
                    try? handle.close()
                    throw error
                } catch {
                    try? handle.close()
                    // ZIPFoundation raises for unsupported methods and malformed data
                    // alike. We cannot tell them apart from the error alone, so name the
                    // entry and let the message cover both.
                    throw ImportError.unsupportedCompressionMethod(entry: path)
                }

                // The check that catches a truncated download or a corrupted asset, and
                // the reason a bad import fails loudly rather than producing a game that
                // crashes hours later on one broken image.
                if checksum != entry.checksum {
                    throw ImportError.checksumMismatch(entry: path)
                }

                written += Int64(entry.uncompressedSize)
                completed += 1

                if coverRelativePath == nil, isCoverCandidate(path) {
                    coverRelativePath = path
                }

                if plan.extractCount > 0 {
                    progress(Double(completed) / Double(plan.extractCount))
                }
            }
        }

        // Extraction wrote the distribution root's CONTENTS directly into staging, so
        // staging itself is the basedir.
        return ImportResult(
            identity: plan.identity,
            engine: plan.engine,
            stagingGameDirectory: stagingDirectory,
            bytesWritten: written,
            coverRelativePath: coverRelativePath
        )
    }

    // MARK: - Helpers

    /// Filename decoding with the fallback chain from EntryPolicy. ZIPFoundation returns
    /// "" from `path(using:)` when the bytes are not valid in that encoding, which is
    /// what makes the chain testable.
    private func decodedPath(of entry: Entry) -> String {
        EntryPolicy.decodeFilename(
            utf8Attempt: entry.path(using: .utf8),
            shiftJISAttempt: entry.path(using: .shiftJIS),
            libraryDefault: entry.path
        )
    }

    /// The last component of the distribution root, or nil when the root is the archive
    /// itself. nil sends `GameIdentityDeriver` to the archive filename.
    private func plan_rootName(distributionRoot root: String) -> String? {
        guard !root.isEmpty else { return nil }
        return root.split(separator: "/").last.map(String.init)
    }

    /// Strips the distribution root prefix. Returns nil for paths outside it.
    private func relative(_ path: String, under root: String) -> String? {
        guard !root.isEmpty else { return path }
        let prefix = root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private func readVCVersion(archive: Archive, root: String) throws -> String? {
        let wanted = root.isEmpty ? "renpy/vc_version.py" : "\(root)/renpy/vc_version.py"

        for entry in archive where entry.type == .file {
            guard decodedPath(of: entry).lowercased() == wanted.lowercased() else { continue }

            var data = Data()
            _ = try? archive.extract(entry, bufferSize: 64 * 1024, skipCRC32: true) { data.append($0) }
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    private func isCoverCandidate(_ relativePath: String) -> Bool {
        let lower = relativePath.lowercased()
        return lower == "game/gui/window_icon.png" || lower == "icon.png"
    }
}
