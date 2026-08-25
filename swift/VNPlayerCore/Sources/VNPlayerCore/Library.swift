import Foundation

public struct LibraryEntry: Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var coverPath: String?
    public var sizeBytes: Int64
    public var addedAt: Date
    public var lastPlayedAt: Date?
    public var detectedEngine: DetectedEngine
    /// False when the user turned pruning off, i.e. the desktop files are still there.
    public var importedComplete: Bool
    /// Incremented when a launch of this game killed the process. See §10.5.
    public var crashCount: Int
    /// The game's `config.save_directory`, learned from `gameReady` the first time it
    /// runs. Optional and defaulted because a `library.json` written before this field
    /// existed must still decode -- a non-optional here would lose the whole library.
    public var saveDirectory: String?

    public init(
        id: String,
        title: String,
        coverPath: String? = nil,
        sizeBytes: Int64 = 0,
        addedAt: Date = Date(),
        lastPlayedAt: Date? = nil,
        detectedEngine: DetectedEngine = .unknown,
        importedComplete: Bool = false,
        crashCount: Int = 0,
        saveDirectory: String? = nil
    ) {
        self.id = id
        self.title = title
        self.coverPath = coverPath
        self.sizeBytes = sizeBytes
        self.addedAt = addedAt
        self.lastPlayedAt = lastPlayedAt
        self.detectedEngine = detectedEngine
        self.importedComplete = importedComplete
        self.crashCount = crashCount
        self.saveDirectory = saveDirectory
    }
}

/// The library index, plus the per-game manifests that make it disposable.
///
/// `library.json` is an index, never the source of truth. If it is lost or corrupt the
/// library rebuilds by scanning `Games/`.
///
/// A plain rescan of directory names would recover the games but lose everything about
/// them — title, cover, engine, crash count, when they were added. So each game also
/// carries `Games/<id>/.vnplayer/game.json`, written at import. The rescan reads those,
/// and only falls back to inventing an entry from the directory name when a manifest is
/// missing too. Raised in review; the draft had rescan-from-names alone and would have
/// silently downgraded every game's metadata the first time the index was damaged.
public final class LibraryStore {

    private let paths: VNPlayerPaths
    private let fileManager: FileManager

    public init(paths: VNPlayerPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static let manifestSubdirectory = ".vnplayer"
    private static let manifestName = "game.json"

    public func manifestURL(for gameId: String) -> URL {
        paths.gameDirectory(gameId)
            .appendingPathComponent(Self.manifestSubdirectory, isDirectory: true)
            .appendingPathComponent(Self.manifestName)
    }

    // MARK: - Reading

    /// Load the index, rebuilding it from per-game manifests if it is missing or corrupt.
    public func load() -> [LibraryEntry] {
        if let data = try? Data(contentsOf: paths.libraryIndex),
           let entries = try? Self.decoder.decode([LibraryEntry].self, from: data) {
            // Drop entries whose directory has gone. The user can delete a game through
            // the Files app, and an index that still lists it produces a launch that
            // fails for no visible reason.
            let present = entries.filter {
                fileManager.fileExists(atPath: paths.gameDirectory($0.id).path)
            }
            if present.count != entries.count {
                try? save(present)
            }
            return present
        }

        let rebuilt = rescan()
        try? save(rebuilt)
        return rebuilt
    }

    /// Rebuild from what is actually on disk.
    public func rescan() -> [LibraryEntry] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: paths.games, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else {
            return []
        }

        var entries: [LibraryEntry] = []

        for directory in contents {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            let gameId = directory.lastPathComponent

            if let data = try? Data(contentsOf: manifestURL(for: gameId)),
               let entry = try? Self.decoder.decode(LibraryEntry.self, from: data) {
                entries.append(entry)
            } else {
                // No manifest: the directory was put there by hand, or predates the
                // manifest. Recover what the name gives us rather than ignoring it.
                entries.append(LibraryEntry(
                    id: gameId,
                    title: gameId,
                    detectedEngine: .unknown,
                    importedComplete: false
                ))
            }
        }

        return entries.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: - Writing

    /// Atomic: written to a sibling temp file and renamed, so a kill mid-write leaves
    /// the previous index intact rather than a half-written one.
    public func save(_ entries: [LibraryEntry]) throws {
        let data = try Self.encoder.encode(entries)
        try fileManager.createDirectory(
            at: paths.applicationSupport, withIntermediateDirectories: true)
        try data.write(to: paths.libraryIndex, options: .atomic)
    }

    public func writeManifest(_ entry: LibraryEntry) throws {
        let url = manifestURL(for: entry.id)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(entry).write(to: url, options: .atomic)
    }

    public func upsert(_ entry: LibraryEntry) throws -> [LibraryEntry] {
        var entries = load()
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        entries.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        try save(entries)
        try writeManifest(entry)
        return entries
    }

    // MARK: - Deletion

    /// Moves the game aside first, updates the index, and only then deletes.
    ///
    /// A direct recursive delete of a multi-gigabyte directory can be interrupted — the
    /// app is killed, the user force-quits — leaving a half-deleted game still listed in
    /// the index and still occupying space. Renaming into `Trash/` is a single atomic
    /// operation, so at every instant the game is either fully present or fully gone.
    public func delete(_ gameId: String, alsoDeleteSaves: Bool = false) throws -> [LibraryEntry] {
        let source = paths.gameDirectory(gameId)

        if fileManager.fileExists(atPath: source.path) {
            let grave = paths.trash.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: paths.trash, withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: grave)
            try? fileManager.removeItem(at: grave)
        }

        if alsoDeleteSaves {
            try? fileManager.removeItem(at: paths.saveDirectory(gameId))
        }

        var entries = load()
        entries.removeAll { $0.id == gameId }
        try save(entries)
        return entries
    }

    /// Deletes anything left in Trash/ from a previous run that was interrupted.
    public func emptyTrash() {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: paths.trash, includingPropertiesForKeys: nil) else { return }
        for url in contents {
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: - Installing an import

    /// Moves a completed staging directory into place.
    ///
    /// `moveItem` fails outright when the destination exists, which is the normal case
    /// for a re-import — both reviewers flagged it, and the draft would have failed on
    /// the happy path of updating a game. The existing directory is moved to Trash/
    /// first, so the swap is two atomic renames and never leaves a partial game.
    ///
    /// Saves are untouched: they live under Saves/<gameId>, outside the game tree,
    /// precisely so that re-importing cannot destroy progress.
    public func install(stagedAt staging: URL, as gameId: String) throws {
        let destination = paths.gameDirectory(gameId)

        try fileManager.createDirectory(at: paths.games, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.createDirectory(at: paths.trash, withIntermediateDirectories: true)
            let grave = paths.trash.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.moveItem(at: destination, to: grave)
            try? fileManager.removeItem(at: grave)
        }

        try fileManager.moveItem(at: staging, to: destination)
    }

    /// Ids already in use, for collision resolution at import time.
    public func takenIds() -> Set<String> {
        Set(load().map(\.id))
    }
}
