import Foundation

// These sources build two ways: as a SwiftPM target (where ZIPFoundation is a separate
// module and must be imported) and compiled directly into the iOS app target alongside
// ZIPFoundation's own sources (where it is not a module at all, and importing it is an
// error). canImport picks correctly in both, without a second copy of the file.
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

/// What an import will do to one game's save directory. Produced before anything is
/// written, so the confirmation sheet (spec §4.5) can render it and the reader can
/// cancel with nothing on disk changed.
public struct SaveImportPlan: Equatable {
    /// From the manifest. Nil for a foreign file, which cannot name its own game.
    public let gameId: String?
    public let title: String?
    public let isForeign: Bool
    /// Source name inside the archive → destination slot.
    public let placements: [Placement]
    /// Files already present with identical content, which will be skipped.
    public let alreadyPresent: [String]
    /// Where this game's saves live inside the archive: `"saves"`, `"games/<gameId>"`, or
    /// whatever directory a hand-made zip used. Empty for a bare `.save` file, which has
    /// no archive at all.
    ///
    /// Task 6 needs this because a last-path-component match is ambiguous in a backup:
    /// `games/alpha/1-1-LT1.save` and `games/beta/1-1-LT1.save` share their last
    /// component, so restoring a two-game backup could file one game's saves into the
    /// other game's directory without erroring.
    public let sourcePrefix: String

    public init(gameId: String?, title: String?, isForeign: Bool,
                placements: [Placement], alreadyPresent: [String], sourcePrefix: String) {
        self.gameId = gameId
        self.title = title
        self.isForeign = isForeign
        self.placements = placements
        self.alreadyPresent = alreadyPresent
        self.sourcePrefix = sourcePrefix
    }

    public var addedCount: Int { placements.count }
    public var newSlotCount: Int { placements.filter(\.movedToNewSlot).count }
}

public struct SaveImportPlanSet: Equatable {
    public let kind: SaveManifest.Kind
    /// True when the source carried no VNPlayer manifest. Drives the §6 warning, and
    /// nothing else -- it is not a safety verdict.
    public let isForeign: Bool
    public let plans: [SaveImportPlan]
    /// Titles present in a backup that are not installed here. Named, never dropped.
    public let missingGames: [String]

    public init(kind: SaveManifest.Kind, isForeign: Bool,
                plans: [SaveImportPlan], missingGames: [String]) {
        self.kind = kind
        self.isForeign = isForeign
        self.plans = plans
        self.missingGames = missingGames
    }
}

public enum SaveImporter {

    /// Work out what would happen, without doing any of it.
    ///
    /// `resolve` maps a plan to the directory its saves would land in, and returns nil
    /// when that game is not installed. A closure rather than a `LibraryStore`, so this
    /// type never depends on the library and is testable with no library at all.
    public static func plan(
        source: URL,
        resolve: (SaveImportPlan) -> URL?,
        caps: ImportCaps = .default
    ) throws -> SaveImportPlanSet {

        // A bare save file straight off a desktop. No manifest, so it cannot name its
        // game; §4.2 case 3 asks the reader which game it belongs to.
        if SaveSlot(fileName: source.lastPathComponent) != nil {
            let draft = SaveImportPlan(gameId: nil, title: nil, isForeign: true,
                                       placements: [], alreadyPresent: [], sourcePrefix: "")
            guard let directory = resolve(draft) else {
                return SaveImportPlanSet(kind: .game, isForeign: true,
                                         plans: [], missingGames: [])
            }
            let data = (try? Data(contentsOf: source)) ?? Data()
            let plan = build(gameId: nil, title: nil, isForeign: true,
                             incoming: [(source.lastPathComponent, SaveDigest.sha256(of: data))],
                             directory: directory, sourcePrefix: "")
            return SaveImportPlanSet(kind: .game, isForeign: true,
                                     plans: [plan], missingGames: [])
        }

        guard let archive = try? Archive(url: source, accessMode: .read) else {
            throw SaveTransferError.cannotOpenArchive
        }

        let manifest = try readManifest(from: archive)

        // Group save entries by the game directory they sit under. `EntryPolicy.sanitize`
        // is what stops a crafted path escaping the destination; save transfer gets no
        // exemption from the policy the game importer already uses.
        var byGame: [String: [(name: String, digest: String)]] = [:]
        var groupPrefix: [String: String] = [:]
        var sawGameDirectory = false
        var entryCount = 0

        for entry in archive {
            guard let relative = try EntryPolicy.sanitize(entry.path) else { continue }

            entryCount += 1
            if entryCount > caps.maxEntries {
                throw ImportError.tooManyEntries(count: UInt64(entryCount),
                                                 limit: caps.maxEntries)
            }

            let components = relative.split(separator: "/").map(String.init)
            if components.contains("game") { sawGameDirectory = true }

            guard let name = components.last, SaveSlot(fileName: name) != nil else {
                continue
            }
            // ZIPFoundation's `uncompressedSize` is UInt64; `ImportError` and `ImportCaps`
            // use Int64 throughout (see ArchiveImporter.swift), so it is cast at the
            // boundary rather than threading UInt64 through this file's own types.
            let uncompressedSize = Int64(entry.uncompressedSize)
            if uncompressedSize > caps.maxEntryUncompressed {
                throw ImportError.entryTooLarge(entry: name,
                                                bytes: uncompressedSize,
                                                limit: caps.maxEntryUncompressed)
            }

            var data = Data()
            _ = try? archive.extract(entry) { data.append($0) }

            // `games/<id>/x.save` groups by id; anything else is one anonymous group.
            let key = (components.count >= 3 && components[0] == "games")
                ? components[1] : ""

            // The directory portion of this entry's path -- everything but the file name
            // itself. Task 6 needs this to know where a game's saves sat in the archive,
            // since matching by last path component alone cannot tell
            // `games/alpha/1-1-LT1.save` apart from `games/beta/1-1-LT1.save`.
            let prefix = components.dropLast().joined(separator: "/")
            if groupPrefix[key] == nil {
                groupPrefix[key] = prefix
            }

            byGame[key, default: []].append((name, SaveDigest.sha256(of: data)))
        }

        if byGame.isEmpty {
            // Distinguishing "you picked a game" from "there is nothing here" is the
            // difference between a message she can act on and one she cannot.
            throw sawGameDirectory
                ? SaveTransferError.looksLikeAGameArchive
                : SaveTransferError.noSaveFilesFound
        }

        var plans: [SaveImportPlan] = []
        var missing: [String] = []

        let games = manifest?.games ?? []

        for (key, incoming) in byGame.sorted(by: { $0.key < $1.key }) {
            // The fallback is ONLY for our own single-game export, where saves sit under
            // `saves/` and there is no `games/<id>/` component to match a manifest entry
            // against. Letting it catch any unmatched key means a group at
            // `games/somethingelse/` is silently attributed to the one game in the
            // manifest -- and since the archive carries our manifest, it imports with no
            // warning. An unmatched non-empty key names a game this archive does not
            // describe, and must not be guessed at.
            let game = games.first { $0.gameId == key }
                ?? (key.isEmpty && games.count == 1 ? games[0] : nil)
            let prefix = groupPrefix[key] ?? ""

            if let game {
                try verifyDigests(incoming, against: game)
            }

            let draft = SaveImportPlan(gameId: game?.gameId, title: game?.title,
                                       isForeign: manifest == nil,
                                       placements: [], alreadyPresent: [],
                                       sourcePrefix: prefix)

            guard let directory = resolve(draft) else {
                missing.append(game?.title ?? game?.gameId ?? "these saves")
                continue
            }

            plans.append(build(gameId: game?.gameId, title: game?.title,
                               isForeign: manifest == nil,
                               incoming: incoming, directory: directory,
                               sourcePrefix: prefix))
        }

        return SaveImportPlanSet(kind: manifest?.kind ?? .game,
                                 isForeign: manifest == nil,
                                 plans: plans,
                                 missingGames: missing)
    }

    // MARK: - Helpers

    private static func readManifest(from archive: Archive) throws -> SaveManifest? {
        guard let entry = archive[SaveManifest.fileName] else { return nil }
        var data = Data()
        _ = try? archive.extract(entry) { data.append($0) }
        return try SaveManifest.decode(data)
    }

    private static func verifyDigests(
        _ incoming: [(name: String, digest: String)],
        against game: SaveManifest.Game
    ) throws {
        let expected = Dictionary(uniqueKeysWithValues:
            game.files.map { ($0.name, $0.sha256) })

        for file in incoming {
            guard let want = expected[file.name] else {
                // The archive carries our manifest, which means it imports with no
                // warning at all -- so a file the manifest does not describe cannot be
                // waved through. It is not what the file claims to be.
                throw SaveTransferError.damagedFile(name: file.name)
            }
            if want != file.digest {
                throw SaveTransferError.damagedFile(name: file.name)
            }
        }

        // The other direction, which iterating `incoming` alone cannot see: a save the
        // manifest promised and the archive does not contain. Silence here means a
        // reader restores a backup and never learns part of it did not arrive.
        let present = Set(incoming.map(\.name))
        for file in game.files where !present.contains(file.name) {
            throw SaveTransferError.damagedFile(name: file.name)
        }
    }

    private static func build(
        gameId: String?,
        title: String?,
        isForeign: Bool,
        incoming: [(name: String, digest: String)],
        directory: URL,
        sourcePrefix: String
    ) -> SaveImportPlan {

        let existingNames = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])

        // Digests of what is already there, so an identical file is skipped rather than
        // copied into a second slot. Without this, restoring twice doubles everything.
        var existingDigests = Set<String>()
        for name in existingNames {
            let url = directory.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url) {
                existingDigests.insert(SaveDigest.sha256(of: data))
            }
        }

        let alreadyPresent = incoming
            .filter { existingDigests.contains($0.digest) }
            .map(\.name)
            .sorted()

        let toPlace = incoming
            .filter { !existingDigests.contains($0.digest) }
            .map(\.name)
            .sorted()

        return SaveImportPlan(
            gameId: gameId,
            title: title,
            isForeign: isForeign,
            placements: SlotPlacement.place(incoming: toPlace, existing: existingNames),
            alreadyPresent: alreadyPresent,
            sourcePrefix: sourcePrefix)
    }
}
