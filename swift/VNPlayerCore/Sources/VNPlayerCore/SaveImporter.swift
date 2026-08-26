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
    /// What will happen to `persistent` for this game. `persistent` is a single file, not
    /// a slot -- there is only one, so the never-destroy rule cannot be satisfied by
    /// "put it in a free slot" the way a save can. Copy it in when the destination has
    /// none; otherwise leave the existing one exactly as it is.
    public let persistentAction: PersistentAction

    public enum PersistentAction: Equatable {
        /// The archive carries no `persistent` for this game.
        case none
        /// The archive has one and the destination does not -- it will be copied in.
        case copy
        /// The archive has one, but the destination already has its own -- the
        /// destination's is kept, untouched. Not a failure: this is the rule working.
        case keptExisting
    }

    public init(gameId: String?, title: String?, isForeign: Bool,
                placements: [Placement], alreadyPresent: [String], sourcePrefix: String,
                persistentAction: PersistentAction) {
        self.gameId = gameId
        self.title = title
        self.isForeign = isForeign
        self.placements = placements
        self.alreadyPresent = alreadyPresent
        self.sourcePrefix = sourcePrefix
        self.persistentAction = persistentAction
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
                                       placements: [], alreadyPresent: [], sourcePrefix: "",
                                       persistentAction: .none)
            guard let directory = resolve(draft) else {
                return SaveImportPlanSet(kind: .game, isForeign: true,
                                         plans: [], missingGames: [])
            }
            let data: Data
            do {
                data = try Data(contentsOf: source)
            } catch {
                throw SaveTransferError.damagedFile(name: source.lastPathComponent)
            }
            // A Ren'Py save is a non-empty zip; a bare .save that reads as zero bytes is
            // damage, not a valid (if minimal) save.
            guard !data.isEmpty else {
                throw SaveTransferError.damagedFile(name: source.lastPathComponent)
            }
            // A bare file is a single save with nothing else beside it -- there is no
            // archive to hold a `persistent` alongside it.
            let plan = build(gameId: nil, title: nil, isForeign: true,
                             incoming: [(source.lastPathComponent, SaveDigest.sha256(of: data))],
                             directory: directory, sourcePrefix: "", persistentIncoming: nil)
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
        // `persistent` is a single file, not a slot, so it never belongs in `byGame`'s
        // placement lists -- it gets its own dictionary, one entry per game group.
        var persistentByGame: [String: (name: String, digest: String)] = [:]
        var groupPrefix: [String: String] = [:]
        var sawGameDirectory = false
        var entryCount = 0
        // I2: the four EntryPolicy rejections ArchiveImporter enforces that this path
        // used to skip entirely. Spec §6/§8: "Save transfer adds no new policy and gets
        // no exemption from the old one" -- mirrored here rather than re-derived.
        var seenLowercased = Set<String>()
        var totalUncompressed: Int64 = 0

        for entry in archive {
            guard let relative = try EntryPolicy.sanitize(entry.path) else { continue }

            entryCount += 1
            if entryCount > caps.maxEntries {
                throw ImportError.tooManyEntries(count: UInt64(entryCount),
                                                 limit: caps.maxEntries)
            }

            if entry.type == .symlink {
                throw ImportError.symlinkNotAllowed(entry: relative)
            }

            // Case-insensitive: iOS's filesystem folds case, so two entries differing
            // only in case are the same destination. Checked for every file entry, not
            // only ones that turn out to be save slots -- the archive is untrusted before
            // any name filter runs.
            if entry.type == .file {
                let key = relative.lowercased()
                if seenLowercased.contains(key) {
                    throw ImportError.duplicateEntry(path: relative)
                }
                seenLowercased.insert(key)
            }

            let components = relative.split(separator: "/").map(String.init)
            if components.contains("game") { sawGameDirectory = true }

            // `persistent` is admitted here alongside a real slot name -- it gets every
            // guard below (size caps, checksum, non-empty) exactly as a slot file does;
            // it just lands in `persistentByGame` instead of `byGame` further down.
            guard let name = components.last else { continue }
            let isPersistentEntry = (name == "persistent")
            guard isPersistentEntry || SaveSlot(fileName: name) != nil else {
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

            let compressedSize = Int64(entry.compressedSize)
            if compressedSize > 0 {
                let ratio = Double(uncompressedSize) / Double(compressedSize)
                if ratio > caps.maxCompressionRatio {
                    throw ImportError.suspiciousCompressionRatio(entry: name, ratio: ratio)
                }
            }

            totalUncompressed += uncompressedSize
            if totalUncompressed > caps.maxTotalUncompressed {
                throw ImportError.archiveTooLarge(bytes: totalUncompressed,
                                                  limit: caps.maxTotalUncompressed)
            }

            var data = Data()
            let checksum: CRC32
            do {
                checksum = try archive.extract(entry) { data.append($0) }
            } catch {
                throw SaveTransferError.damagedFile(name: name)
            }

            // ZIPFoundation's closure-based extract RETURNS the CRC rather than checking
            // it -- only the extract(_:to:) variant verifies. Discarding it means a
            // corrupted or truncated save is digested (and, in apply(), written) exactly
            // as-is, and for a manifest-free zip (spec §5's "zip a desktop save folder
            // yourself") there is no manifest sha256 to catch it either -- this is the
            // only check standing between the archive and her save directory.
            // ArchiveImporter.swift:284 does the same comparison for the same reason.
            if checksum != entry.checksum {
                throw SaveTransferError.damagedFile(name: name)
            }

            // A Ren'Py save is itself a non-empty zip (loadsave.py:110) -- never zero
            // bytes. EOF is not a read error in ZIPFoundation's fread-based reader, so a
            // read that stops short can finish without throwing at all; this is what
            // closes that hole for an entry that reads as empty.
            guard !data.isEmpty else {
                throw SaveTransferError.damagedFile(name: name)
            }

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

            if isPersistentEntry {
                persistentByGame[key] = (name, SaveDigest.sha256(of: data))
            } else {
                byGame[key, default: []].append((name, SaveDigest.sha256(of: data)))
            }
        }

        if byGame.isEmpty && persistentByGame.isEmpty {
            // Distinguishing "you picked a game" from "there is nothing here" is the
            // difference between a message she can act on and one she cannot.
            throw sawGameDirectory
                ? SaveTransferError.looksLikeAGameArchive
                : SaveTransferError.noSaveFilesFound
        }

        var plans: [SaveImportPlan] = []
        var missing: [String] = []

        let games = manifest?.games ?? []

        // A group may exist only in `persistentByGame` -- a game whose saves directory
        // held nothing but `persistent` (never saved, but the gallery and settings are
        // real). Iterating the union rather than `byGame` alone is what lets that group's
        // plan get built at all.
        let allKeys = Set(byGame.keys).union(persistentByGame.keys)

        for key in allKeys.sorted() {
            let incoming = byGame[key] ?? []
            let persistentEntry = persistentByGame[key]

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
                try verifyPersistentDigest(persistentEntry, against: game)
            }

            let draft = SaveImportPlan(gameId: game?.gameId, title: game?.title,
                                       isForeign: manifest == nil,
                                       placements: [], alreadyPresent: [],
                                       sourcePrefix: prefix, persistentAction: .none)

            guard let directory = resolve(draft) else {
                // A group we cannot NAME is not "missing" -- there is no absent game to
                // report. Leaving it out of missingGames is what lets the app layer tell
                // "named, but not installed" (say so) from "cannot name itself at all"
                // (offer the chooser). Without the distinction, a save folder zipped by
                // hand on a PC reports "These saves are for these saves, which isn't
                // installed" and the reader has no way in.
                if let name = game?.title ?? game?.gameId {
                    missing.append(name)
                }
                continue
            }

            plans.append(build(gameId: game?.gameId, title: game?.title,
                               isForeign: manifest == nil,
                               incoming: incoming, directory: directory,
                               sourcePrefix: prefix, persistentIncoming: persistentEntry))
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
        // uniquingKeysWith, not uniqueKeysWithValues: the latter TRAPS on a duplicate key,
        // and this dictionary is built from a file the reader picked. A hand-edited
        // manifest naming the same file twice would crash the app rather than be refused.
        // Last one wins; the reverse pass below still catches anything the archive lacks.
        let expected = Dictionary(game.files.map { ($0.name, $0.sha256) },
                                  uniquingKeysWith: { _, second in second })

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
        // `persistent` is excluded: it is never part of `incoming` (it is tracked and
        // verified separately by `verifyPersistentDigest`), so it would otherwise always
        // read as "promised but missing" whenever the manifest recorded one.
        let present = Set(incoming.map(\.name))
        for file in game.files where !present.contains(file.name) && file.name != "persistent" {
            throw SaveTransferError.damagedFile(name: file.name)
        }
    }

    /// Same proof `verifyDigests` gives the slot files, for the one file that isn't one.
    /// Checked in both directions: an archive `persistent` the manifest doesn't describe,
    /// or a manifest `persistent` the archive doesn't contain, are both damage -- not
    /// silently accepted and not silently dropped.
    private static func verifyPersistentDigest(
        _ persistent: (name: String, digest: String)?,
        against game: SaveManifest.Game
    ) throws {
        let expected = game.files.first { $0.name == "persistent" }

        switch (persistent, expected) {
        case (nil, nil):
            return
        case (let archiveEntry?, let manifestFile?):
            if archiveEntry.digest != manifestFile.sha256 {
                throw SaveTransferError.damagedFile(name: "persistent")
            }
        case (nil, .some):
            throw SaveTransferError.damagedFile(name: "persistent")
        case (.some, nil):
            throw SaveTransferError.damagedFile(name: "persistent")
        }
    }

    private static func build(
        gameId: String?,
        title: String?,
        isForeign: Bool,
        incoming: [(name: String, digest: String)],
        directory: URL,
        sourcePrefix: String,
        persistentIncoming: (name: String, digest: String)?
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

        // `persistent` never displaces an existing one -- there is only one file, so
        // "put it in a free slot" (what SlotPlacement does for a taken save slot) has no
        // equivalent here. Present and absent at the destination is the whole decision.
        let persistentAction: SaveImportPlan.PersistentAction
        if persistentIncoming != nil {
            persistentAction = existingNames.contains("persistent") ? .keptExisting : .copy
        } else {
            persistentAction = .none
        }

        return SaveImportPlan(
            gameId: gameId,
            title: title,
            isForeign: isForeign,
            placements: SlotPlacement.place(incoming: toPlace, existing: existingNames),
            alreadyPresent: alreadyPresent,
            sourcePrefix: sourcePrefix,
            persistentAction: persistentAction)
    }
}

public struct SaveImportResult: Equatable {
    public let added: Int
    public let movedToNewSlot: Int
    public let skipped: Int
    /// What actually happened to `persistent`. Always equal to the plan's own
    /// `persistentAction` -- `apply` either does exactly that or throws before returning,
    /// so there is no case where the executed action could differ from the planned one.
    public let persistentAction: SaveImportPlan.PersistentAction
    /// What to show the reader afterwards, in the same terms the confirmation used.
    public let sentence: String

    public init(added: Int, movedToNewSlot: Int, skipped: Int,
                persistentAction: SaveImportPlan.PersistentAction, sentence: String) {
        self.added = added
        self.movedToNewSlot = movedToNewSlot
        self.skipped = skipped
        self.persistentAction = persistentAction
        self.sentence = sentence
    }
}

extension SaveImporter {

    /// Execute exactly the plan, and nothing else.
    ///
    /// The counts it returns must equal the counts the plan predicted, because the
    /// confirmation sheet showed those numbers before the reader agreed. That equality
    /// is asserted in `SaveImporterApplyTests.testTheResultMatchesThePlanExactly`.
    public static func apply(
        _ plan: SaveImportPlan,
        source: URL,
        into directory: URL
    ) throws -> SaveImportResult {

        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)

        // A bare .save has no archive to read from.
        let archive = (SaveSlot(fileName: source.lastPathComponent) != nil)
            ? nil
            : try? Archive(url: source, accessMode: .read)

        if archive == nil, SaveSlot(fileName: source.lastPathComponent) == nil {
            throw SaveTransferError.cannotOpenArchive
        }

        var moved = 0

        for placement in plan.placements {
            let data: Data

            if let archive {
                // Exact path first. A last-component match is ambiguous in a backup --
                // games/alpha/1-1-LT1.save and games/beta/1-1-LT1.save share their last
                // component -- so matching by name alone can file one game's save into
                // another game's directory without erroring.
                let path = plan.sourcePrefix.isEmpty
                    ? placement.sourceName
                    : "\(plan.sourcePrefix)/\(placement.sourceName)"

                // The fallback covers a hand-made archive whose entries for one game sit
                // at differing depths, where a single recorded prefix cannot describe them
                // all. It is safe here precisely because a plan maps to ONE destination
                // game: the worst a name match can do inside a single group is pick the
                // wrong one of that game's own files.
                guard let entry = archive[path] ?? archive.first(where: {
                    ($0.path as NSString).lastPathComponent == placement.sourceName
                }) else {
                    throw SaveTransferError.damagedFile(name: placement.sourceName)
                }
                var buffer = Data()
                let checksum: CRC32
                do {
                    checksum = try archive.extract(entry) { buffer.append($0) }
                } catch {
                    // I6: `try?` here used to discard a thrown extraction error and write
                    // the empty buffer as the save, counted as added and reported as
                    // success.
                    throw SaveTransferError.damagedFile(name: placement.sourceName)
                }

                // ZIPFoundation's closure-based extract RETURNS the CRC rather than
                // checking it -- discarding it (as `_ = try archive.extract(...)` used to
                // do here) means a corrupted or truncated save is written as whatever
                // bytes arrived and still counted as added. Mirrors ArchiveImporter.swift
                // :284's comparison, and closes the same manifest-free-zip gap plan()'s
                // own extract now closes above.
                if checksum != entry.checksum {
                    throw SaveTransferError.damagedFile(name: placement.sourceName)
                }

                // EOF is not a read error in ZIPFoundation's fread-based reader, so a
                // short read can finish without throwing. A Ren'Py save is never zero
                // bytes, so an empty result here is damage, not a valid save.
                guard !buffer.isEmpty else {
                    throw SaveTransferError.damagedFile(name: placement.sourceName)
                }
                data = buffer
            } else {
                // A bare .save contains exactly one save: itself. Checking the name rather
                // than reusing these bytes for whatever the plan asks for -- a hand-built
                // plan with several placements would otherwise write one file's contents
                // under several slot names, silently and without error.
                guard placement.sourceName == source.lastPathComponent else {
                    throw SaveTransferError.damagedFile(name: placement.sourceName)
                }
                do {
                    data = try Data(contentsOf: source)
                } catch {
                    throw SaveTransferError.damagedFile(name: placement.sourceName)
                }
                guard !data.isEmpty else {
                    throw SaveTransferError.damagedFile(name: placement.sourceName)
                }
            }

            let target = directory.appendingPathComponent(placement.destination.fileName)

            // Belt and braces, and deliberately redundant. SlotPlacement guarantees this
            // path is free AT PLANNING TIME, but the reader's own game can autosave into
            // it while the confirmation sheet is still on screen -- between plan() and
            // apply() -- so this is a real race, not just defensive coding. Refusing is
            // the only acceptable behaviour; overwriting what appeared in that window
            // would be the exact bug this whole feature exists to prevent.
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw SaveTransferError.slotTakenSincePlanning(name: placement.destination.fileName)
            }

            do {
                try data.write(to: target, options: .withoutOverwriting)
            } catch {
                // The same race, losing a narrower photo finish: the explicit check above
                // passed, but something claimed this path before the write below landed.
                if FileManager.default.fileExists(atPath: target.path) {
                    throw SaveTransferError.slotTakenSincePlanning(name: placement.destination.fileName)
                }
                throw SaveTransferError.writeFailed(name: placement.destination.fileName)
            }

            if placement.movedToNewSlot { moved += 1 }
        }

        // `persistent` is a single file, not a slot: `.copy` is the only case that writes
        // anything. `.keptExisting` means the destination already has its own and it is
        // left completely alone -- no read, no write, not even a comparison -- and
        // `.none` means the archive never had one for this game.
        if plan.persistentAction == .copy {
            guard let archive else {
                // Only reachable if a hand-built plan claims `.copy` for a bare-.save
                // import, which has no archive to copy from.
                throw SaveTransferError.cannotOpenArchive
            }

            let path = plan.sourcePrefix.isEmpty ? "persistent" : "\(plan.sourcePrefix)/persistent"
            guard let entry = archive[path] ?? archive.first(where: {
                ($0.path as NSString).lastPathComponent == "persistent"
            }) else {
                throw SaveTransferError.damagedFile(name: "persistent")
            }

            var buffer = Data()
            let checksum: CRC32
            do {
                checksum = try archive.extract(entry) { buffer.append($0) }
            } catch {
                throw SaveTransferError.damagedFile(name: "persistent")
            }
            if checksum != entry.checksum {
                throw SaveTransferError.damagedFile(name: "persistent")
            }
            guard !buffer.isEmpty else {
                throw SaveTransferError.damagedFile(name: "persistent")
            }

            let target = directory.appendingPathComponent("persistent")

            // Belt and braces, exactly as for a slot above: `plan()` saw no `persistent`
            // at the destination, but something -- the reader's own game running, or a
            // second import landing first -- could have created one while the
            // confirmation sheet was on screen. The never-destroy rule covers
            // `persistent` exactly as it covers a slot: refuse rather than replace.
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw SaveTransferError.slotTakenSincePlanning(name: "persistent")
            }

            do {
                try buffer.write(to: target, options: .withoutOverwriting)
            } catch {
                if FileManager.default.fileExists(atPath: target.path) {
                    throw SaveTransferError.slotTakenSincePlanning(name: "persistent")
                }
                throw SaveTransferError.writeFailed(name: "persistent")
            }
        }

        return SaveImportResult(
            added: plan.placements.count,
            movedToNewSlot: moved,
            skipped: plan.alreadyPresent.count,
            persistentAction: plan.persistentAction,
            sentence: sentence(added: plan.placements.count,
                               moved: moved,
                               skipped: plan.alreadyPresent.count,
                               persistent: plan.persistentAction))
    }

    static func sentence(added: Int, moved: Int, skipped: Int,
                         persistent: SaveImportPlan.PersistentAction) -> String {

        let persistentClause: String?
        switch persistent {
        case .copy:
            persistentClause = "Your gallery and settings for this game came along too."
        case .keptExisting:
            persistentClause = "Your existing gallery and settings for this game were kept, unchanged."
        case .none:
            persistentClause = nil
        }

        if added == 0 && skipped == 0 {
            // No slot saves at all -- either this plan is genuinely empty, or
            // `persistent` is the only thing in it.
            guard let persistentClause else { return "There was nothing to add." }
            return persistentClause
        }

        var text: String
        if added == 0 {
            text = "Those saves are already here. Nothing changed."
        } else {
            text = added == 1 ? "1 save added" : "\(added) saves added"
            if moved > 0 { text += ", \(moved) placed in new slots" }
            if skipped > 0 { text += ", \(skipped) already here" }
            text += "."
        }

        if let persistentClause {
            text += " " + persistentClause
        }
        return text
    }
}
