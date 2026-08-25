import Foundation
import ZIPFoundation

public struct SaveExportItem {
    public let gameId: String
    public let title: String
    /// `config.save_directory`, or nil when the game does not set one.
    public let saveDirectory: String?
    /// The game's save directory on this device: `Documents/Saves/<gameId>/`.
    public let directory: URL

    public init(gameId: String, title: String, saveDirectory: String?, directory: URL) {
        self.gameId = gameId
        self.title = title
        self.saveDirectory = saveDirectory
        self.directory = directory
    }
}

public struct SaveExportSummary: Equatable {
    public let fileCount: Int
    public let totalBytes: Int64

    public init(fileCount: Int, totalBytes: Int64) {
        self.fileCount = fileCount
        self.totalBytes = totalBytes
    }
}

/// Packs save directories into a `.zip` a desktop can open with nothing installed.
public enum SaveExporter {

    /// Count and size, without writing anything.
    ///
    /// Separate from `export` because the confirmation sheet (spec §4.5) must state the
    /// numbers BEFORE the reader agrees, and a confirmation that had to write the file
    /// first would not be a confirmation.
    public static func summarise(_ items: [SaveExportItem]) -> SaveExportSummary {
        var count = 0
        var bytes: Int64 = 0

        for item in items {
            for (_, url) in saveFiles(in: item.directory) {
                count += 1
                bytes += fileSize(url)
            }
        }

        return SaveExportSummary(fileCount: count, totalBytes: bytes)
    }

    public static func export(
        _ items: [SaveExportItem],
        kind: SaveManifest.Kind,
        appVersion: String,
        to destination: URL,
        now: Date = Date()
    ) throws -> SaveExportSummary {

        // Refuse before creating a file. An empty archive that reports success is the
        // worst outcome here: it looks like a backup right up until it is needed.
        let anySaves = items.contains { !saveFiles(in: $0.directory).isEmpty }
        guard anySaves else { throw SaveTransferError.noSaveFilesFound }

        try? FileManager.default.removeItem(at: destination)

        guard let archive = try? Archive(url: destination, accessMode: .create) else {
            throw SaveTransferError.writeFailed(name: destination.lastPathComponent)
        }

        var manifestGames: [SaveManifest.Game] = []
        var count = 0
        var bytes: Int64 = 0

        for item in items {
            let files = saveFiles(in: item.directory).sorted { $0.0 < $1.0 }
            if files.isEmpty { continue }

            let prefix = (kind == .backup) ? "games/\(item.gameId)" : "saves"
            var records: [SaveManifest.File] = []

            for (name, url) in files {
                let data: Data
                do {
                    data = try Data(contentsOf: url)
                } catch {
                    throw SaveTransferError.writeFailed(name: name)
                }

                // .none: a .save is already a ZIP (loadsave.py:110). Deflating it again
                // costs CPU on a phone and makes the result slightly bigger.
                try archive.addEntry(with: "\(prefix)/\(name)", type: .file,
                                     uncompressedSize: Int64(data.count),
                                     compressionMethod: .none) { position, size in
                    let start = Int(position)
                    return data.subdata(in: start..<(start + size))
                }

                records.append(SaveManifest.File(name: name,
                                                 bytes: Int64(data.count),
                                                 sha256: SaveDigest.sha256(of: data)))
                count += 1
                bytes += Int64(data.count)
            }

            manifestGames.append(SaveManifest.Game(gameId: item.gameId,
                                                   title: item.title,
                                                   saveDirectory: item.saveDirectory,
                                                   files: records))
        }

        let manifest = SaveManifest(format: SaveManifest.currentFormat,
                                    kind: kind,
                                    exportedAt: now,
                                    appVersion: appVersion,
                                    games: manifestGames)

        try addText(try SaveManifest.encode(manifest),
                    at: SaveManifest.fileName, to: archive)

        // One note per game for a backup would be several files with the same name, so a
        // backup gets one note listing every game in it.
        let note = manifestGames
            .map { DesktopSaveLocations.instructions(title: $0.title,
                                                     saveDirectory: $0.saveDirectory) }
            .joined(separator: "\n\n----------------------------------------\n\n")
        try addText(Data(note.utf8), at: "WHERE-TO-PUT-THESE.txt", to: archive)

        return SaveExportSummary(fileCount: count, totalBytes: bytes)
    }

    // MARK: - Helpers

    /// Save files in a directory, keyed by file name. Anything that is not a slot --
    /// `persistent`, a stray `.txt` -- is not a save and is not exported.
    private static func saveFiles(in directory: URL) -> [(String, URL)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))
            ?? []

        return names.compactMap { name in
            guard SaveSlot(fileName: name) != nil else { return nil }
            return (name, directory.appendingPathComponent(name))
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func addText(_ data: Data, at path: String, to archive: Archive) throws {
        do {
            try archive.addEntry(with: path, type: .file,
                                 uncompressedSize: Int64(data.count),
                                 compressionMethod: .deflate) { position, size in
                let start = Int(position)
                return data.subdata(in: start..<(start + size))
            }
        } catch {
            throw SaveTransferError.writeFailed(name: path)
        }
    }
}
