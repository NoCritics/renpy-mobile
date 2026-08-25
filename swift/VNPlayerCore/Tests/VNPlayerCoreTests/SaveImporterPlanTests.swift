import XCTest
import ZIPFoundation
@testable import VNPlayerCore

final class SaveImporterPlanTests: XCTestCase {

    private var root: URL!
    private var destination: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        destination = root.appendingPathComponent("Saves", isDirectory: true)
        try FileManager.default.createDirectory(at: destination,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func alwaysResolve(_ plan: SaveImportPlan) -> URL? { destination }

    /// Build an export to import back, which is also the round-trip test.
    private func makeExport(names: [String], kind: SaveManifest.Kind = .game) throws -> URL {
        let saves = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        for name in names {
            try Data("contents of \(name)".utf8)
                .write(to: saves.appendingPathComponent(name))
        }
        let out = root.appendingPathComponent("\(UUID().uuidString).zip")
        _ = try SaveExporter.export(
            [SaveExportItem(gameId: "bigbaddogs", title: "Big Bad Dogs",
                            saveDirectory: "BBD-1", directory: saves)],
            kind: kind, appVersion: "0.2.0", to: out, now: Date())
        return out
    }

    func testOurOwnExportPlansCleanlyAndIsNotForeign() throws {
        let source = try makeExport(names: ["1-1-LT1.save", "1-2-LT1.save"])
        let set = try SaveImporter.plan(source: source, resolve: alwaysResolve,
                                        caps: .default)

        XCTAssertFalse(set.isForeign)
        XCTAssertEqual(set.plans.count, 1)
        XCTAssertEqual(set.plans[0].gameId, "bigbaddogs")
        XCTAssertEqual(set.plans[0].title, "Big Bad Dogs")
        XCTAssertEqual(set.plans[0].addedCount, 2)
        XCTAssertEqual(set.plans[0].newSlotCount, 0)
        XCTAssertEqual(set.plans[0].sourcePrefix, "saves")
    }

    func testPlanningWritesNothing() throws {
        let source = try makeExport(names: ["1-1-LT1.save"])
        _ = try SaveImporter.plan(source: source, resolve: alwaysResolve, caps: .default)

        let after = try FileManager.default
            .contentsOfDirectory(atPath: destination.path)
        XCTAssertEqual(after, [], "plan() must not touch the destination")
    }

    func testATakenSlotIsPlannedIntoANewOneAndCounted() throws {
        try Data("existing".utf8)
            .write(to: destination.appendingPathComponent("1-1-LT1.save"))

        let source = try makeExport(names: ["1-1-LT1.save"])
        let set = try SaveImporter.plan(source: source, resolve: alwaysResolve,
                                        caps: .default)

        XCTAssertEqual(set.plans[0].newSlotCount, 1)
        XCTAssertEqual(set.plans[0].placements[0].destination.fileName, "1-2-LT1.save")
    }

    func testIdenticalContentIsListedAsAlreadyPresentNotPlanned() throws {
        // A restore run twice must not double every slot.
        try Data("contents of 1-1-LT1.save".utf8)
            .write(to: destination.appendingPathComponent("1-1-LT1.save"))

        let source = try makeExport(names: ["1-1-LT1.save"])
        let set = try SaveImporter.plan(source: source, resolve: alwaysResolve,
                                        caps: .default)

        XCTAssertEqual(set.plans[0].alreadyPresent, ["1-1-LT1.save"])
        XCTAssertEqual(set.plans[0].addedCount, 0)
    }

    func testADamagedFileIsReportedByName() throws {
        // sha256 in the manifest proves the file is undamaged. That is a different claim
        // from "safe", and only this one is checkable.
        let source = try makeExport(names: ["1-1-LT1.save"])
        try corrupt(entry: "saves/1-1-LT1.save", in: source)

        XCTAssertThrowsError(
            try SaveImporter.plan(source: source, resolve: alwaysResolve, caps: .default)
        ) { error in
            XCTAssertEqual(error as? SaveTransferError,
                           .damagedFile(name: "1-1-LT1.save"))
        }
    }

    func testABareSaveFileIsAcceptedAndIsForeign() throws {
        let bare = root.appendingPathComponent("3-2-LT1.save")
        try Data("from a pc".utf8).write(to: bare)

        let set = try SaveImporter.plan(source: bare, resolve: alwaysResolve,
                                        caps: .default)

        XCTAssertTrue(set.isForeign)
        XCTAssertNil(set.plans[0].gameId)
        XCTAssertEqual(set.plans[0].placements[0].destination.fileName, "3-2-LT1.save")
        XCTAssertEqual(set.plans[0].sourcePrefix, "")
    }

    func testAManifestFreeZipIsAcceptedAndIsForeign() throws {
        let zip = root.appendingPathComponent("hand-made.zip")
        let archive = try XCTUnwrap(try? Archive(url: zip, accessMode: .create))
        let payload = Data("from a pc".utf8)
        try archive.addEntry(with: "some/folder/1-1-LT1.save", type: .file,
                             uncompressedSize: Int64(payload.count),
                             compressionMethod: .none) { position, size in
            payload.subdata(in: Int(position)..<(Int(position) + size))
        }

        let set = try SaveImporter.plan(source: zip, resolve: alwaysResolve,
                                        caps: .default)

        XCTAssertTrue(set.isForeign)
        XCTAssertEqual(set.plans[0].addedCount, 1,
                       "save files must be found at any depth")
        XCTAssertEqual(set.plans[0].sourcePrefix, "some/folder")
    }

    func testAGameArchiveIsRejectedByNameNotGenerically() throws {
        let zip = root.appendingPathComponent("game.zip")
        let archive = try XCTUnwrap(try? Archive(url: zip, accessMode: .create))
        let payload = Data("script".utf8)
        try archive.addEntry(with: "MyGame-1.0/game/script.rpy", type: .file,
                             uncompressedSize: Int64(payload.count),
                             compressionMethod: .none) { position, size in
            payload.subdata(in: Int(position)..<(Int(position) + size))
        }

        XCTAssertThrowsError(
            try SaveImporter.plan(source: zip, resolve: alwaysResolve, caps: .default)
        ) { error in
            XCTAssertEqual(error as? SaveTransferError, .looksLikeAGameArchive)
        }
    }

    func testAZipWithNothingUsefulIsRefused() throws {
        let zip = root.appendingPathComponent("empty.zip")
        _ = try XCTUnwrap(try? Archive(url: zip, accessMode: .create))

        XCTAssertThrowsError(
            try SaveImporter.plan(source: zip, resolve: alwaysResolve, caps: .default)
        ) { error in
            XCTAssertEqual(error as? SaveTransferError, .noSaveFilesFound)
        }
    }

    func testAnUninstalledGameIsNamedRatherThanSilentlySkipped() throws {
        let source = try makeExport(names: ["1-1-LT1.save"])
        let set = try SaveImporter.plan(source: source, resolve: { _ in nil },
                                        caps: .default)

        XCTAssertEqual(set.plans, [])
        XCTAssertEqual(set.missingGames, ["Big Bad Dogs"])
    }

    func testEntryPolicyStillGuardsThisPath() throws {
        // Save transfer adds no new policy and gets no exemption from the old one.
        let zip = root.appendingPathComponent("evil.zip")
        let archive = try XCTUnwrap(try? Archive(url: zip, accessMode: .create))
        let payload = Data("x".utf8)
        try archive.addEntry(with: "../../1-1-LT1.save", type: .file,
                             uncompressedSize: Int64(payload.count),
                             compressionMethod: .none) { position, size in
            payload.subdata(in: Int(position)..<(Int(position) + size))
        }

        XCTAssertThrowsError(
            try SaveImporter.plan(source: zip, resolve: alwaysResolve, caps: .default))
    }

    func testATwoGameBackupKeepsEachGamesSavesUnderItsOwnPrefix() throws {
        // The ambiguity this field exists to remove: both games have a save named
        // 1-1-LT1.save, so a last-path-component match cannot tell them apart, and a
        // restore could file alpha's save into beta's directory without erroring.
        let alpha = root.appendingPathComponent("alpha", isDirectory: true)
        let beta = root.appendingPathComponent("beta", isDirectory: true)
        for dir in [alpha, beta] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("alpha save".utf8).write(to: alpha.appendingPathComponent("1-1-LT1.save"))
        try Data("beta save".utf8).write(to: beta.appendingPathComponent("1-1-LT1.save"))

        let out = root.appendingPathComponent("backup.zip")
        _ = try SaveExporter.export(
            [SaveExportItem(gameId: "alpha", title: "Alpha", saveDirectory: "A", directory: alpha),
             SaveExportItem(gameId: "beta", title: "Beta", saveDirectory: "B", directory: beta)],
            kind: .backup, appVersion: "0.2.0", to: out, now: Date())

        let set = try SaveImporter.plan(source: out, resolve: alwaysResolve, caps: .default)

        XCTAssertEqual(set.plans.count, 2)
        let prefixes = Dictionary(uniqueKeysWithValues:
            set.plans.map { ($0.gameId ?? "?", $0.sourcePrefix) })
        XCTAssertEqual(prefixes["alpha"], "games/alpha")
        XCTAssertEqual(prefixes["beta"], "games/beta")
    }

    func testAGroupNamingAGameTheManifestDoesNotDescribeIsNotAttributedToTheOneItDoes() throws {
        // A real single-game manifest plus an extra group under a different id. The
        // extra group must NOT be folded into the manifest's game: an archive carrying
        // our manifest imports without a foreign-file warning, so anything attributed to
        // a real game is trusted content.
        let source = try makeExport(names: ["1-1-LT1.save"])
        let archive = try XCTUnwrap(try? Archive(url: source, accessMode: .update))
        let payload = Data("injected".utf8)
        try archive.addEntry(with: "games/mallory/9-9-LT1.save", type: .file,
                             uncompressedSize: Int64(payload.count),
                             compressionMethod: .none) { position, size in
            payload.subdata(in: Int(position)..<(Int(position) + size))
        }

        let set = try SaveImporter.plan(source: source, resolve: alwaysResolve,
                                        caps: .default)

        for plan in set.plans where plan.gameId == "bigbaddogs" {
            XCTAssertFalse(plan.placements.contains { $0.sourceName == "9-9-LT1.save" },
                           "an unrelated group was attributed to the manifest's game")
        }
    }

    func testASaveTheManifestDoesNotDescribeIsRejected() throws {
        let source = try makeExport(names: ["1-1-LT1.save"])
        let archive = try XCTUnwrap(try? Archive(url: source, accessMode: .update))
        let payload = Data("injected".utf8)
        try archive.addEntry(with: "saves/5-5-LT1.save", type: .file,
                             uncompressedSize: Int64(payload.count),
                             compressionMethod: .none) { position, size in
            payload.subdata(in: Int(position)..<(Int(position) + size))
        }

        XCTAssertThrowsError(
            try SaveImporter.plan(source: source, resolve: alwaysResolve, caps: .default)
        ) { error in
            XCTAssertEqual(error as? SaveTransferError,
                           .damagedFile(name: "5-5-LT1.save"))
        }
    }

    func testASaveTheManifestPromisedButTheArchiveLacksIsReported() throws {
        let source = try makeExport(names: ["1-1-LT1.save", "1-2-LT1.save"])
        let archive = try XCTUnwrap(try? Archive(url: source, accessMode: .update))
        let entry = try XCTUnwrap(archive["saves/1-2-LT1.save"])
        try archive.remove(entry)

        XCTAssertThrowsError(
            try SaveImporter.plan(source: source, resolve: alwaysResolve, caps: .default)
        ) { error in
            XCTAssertEqual(error as? SaveTransferError,
                           .damagedFile(name: "1-2-LT1.save"))
        }
    }

    func testADuplicateNameInTheManifestIsRefusedNotACrash() throws {
        // Dictionary(uniqueKeysWithValues:) TRAPS on a duplicate key, purely on the
        // repeated name -- it does not matter that both entries below agree on the
        // digest. `expected` in `verifyDigests` is built from a manifest inside a file
        // the reader chose to open, so this shape must not crash the app.
        //
        // For THIS fixture the two duplicated entries are identical, so verifyDigests
        // does not actually throw: the reverse-direction check collapses the repeated
        // name through a Set, and `plan()` returns a plan normally. The `catch is
        // SaveTransferError` branch below is therefore dead code for this input -- it is
        // kept only so a future change that makes verifyDigests reject a duplicate
        // manifest entry outright doesn't turn this test red for the wrong reason. The
        // one thing this test actually proves is that calling `plan` here does not trap
        // the process. There is no way to assert that positively other than by the test
        // process still being alive afterwards to report a result: a Swift precondition
        // failure aborts the process outright rather than throwing or reaching any catch
        // clause, so no in-process assertion can distinguish "this was fixed" from "this
        // run got lucky" -- it can only distinguish "did not crash" from "did crash",
        // and only by virtue of the test finishing at all.
        let source = try makeExport(names: ["1-1-LT1.save"])

        let archive = try XCTUnwrap(try? Archive(url: source, accessMode: .update))
        let manifestEntry = try XCTUnwrap(archive[SaveManifest.fileName])
        var manifestData = Data()
        _ = try? archive.extract(manifestEntry) { manifestData.append($0) }
        var manifest = try SaveManifest.decode(manifestData)
        // Duplicate the one file entry under the same name -- the manifest now lists
        // "1-1-LT1.save" twice for the same game.
        manifest.games[0].files.append(manifest.games[0].files[0])
        let newManifestData = try SaveManifest.encode(manifest)

        try archive.remove(manifestEntry)
        try archive.addEntry(with: SaveManifest.fileName, type: .file,
                             uncompressedSize: Int64(newManifestData.count),
                             compressionMethod: .deflate) { position, size in
            newManifestData.subdata(in: Int(position)..<(Int(position) + size))
        }

        // Must not trap. A plan comes back for this exact fixture (see above); the catch
        // is kept for a stricter future verifyDigests, not because it fires here.
        do {
            _ = try SaveImporter.plan(source: source, resolve: alwaysResolve, caps: .default)
        } catch is SaveTransferError {
            // Not reached by this fixture. Kept for generality only.
        }
    }

    /// Replace one entry's bytes so its digest no longer matches the manifest.
    private func corrupt(entry path: String, in zip: URL) throws {
        let archive = try XCTUnwrap(try? Archive(url: zip, accessMode: .update))
        let entry = try XCTUnwrap(archive[path])
        try archive.remove(entry)
        let payload = Data("tampered".utf8)
        try archive.addEntry(with: path, type: .file,
                             uncompressedSize: Int64(payload.count),
                             compressionMethod: .none) { position, size in
            payload.subdata(in: Int(position)..<(Int(position) + size))
        }
    }
}
