import XCTest
@testable import VNPlayerCore

final class SaveImporterApplyTests: XCTestCase {

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

    private func makeExport(names: [String]) throws -> URL {
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
            kind: .game, appVersion: "0.2.0", to: out, now: Date())
        return out
    }

    private func importAll(_ source: URL) throws -> SaveImportResult {
        let set = try SaveImporter.plan(source: source,
                                        resolve: { _ in self.destination },
                                        caps: .default)
        return try SaveImporter.apply(set.plans[0], source: source, into: destination)
    }

    private var names: Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? [])
    }

    func testRoundTripsTheFilesByteForByte() throws {
        let source = try makeExport(names: ["1-1-LT1.save", "2-3-LT1.save"])
        _ = try importAll(source)

        XCTAssertEqual(names, ["1-1-LT1.save", "2-3-LT1.save"])
        let data = try Data(
            contentsOf: destination.appendingPathComponent("1-1-LT1.save"))
        XCTAssertEqual(data, Data("contents of 1-1-LT1.save".utf8))
    }

    /// I1: the previous version of this test compared `result` to `plan`
    /// (`result.added` vs `set.plans[0].addedCount`, etc.), but `apply()` BUILDS `result`
    /// from `plan` (`added: plan.placements.count`, `moved` counted over the same flag,
    /// `skipped: plan.alreadyPresent.count`) -- so it was comparing the plan to itself.
    /// An `apply` that skipped every `data.write` and just echoed the plan's counts back
    /// into a `SaveImportResult` would still pass every assertion the old test made.
    ///
    /// This version asserts against the DESTINATION DIRECTORY instead -- the actual
    /// files `apply()` did or did not write.
    ///
    /// Hand-trace against that exact broken `apply` (every `try data.write(...)` deleted,
    /// but the final `return SaveImportResult(added: plan.placements.count, ...)` left in
    /// place): `result.added`/`movedToNewSlot`/`skipped` would still read 1/1/1 below,
    /// because those numbers come from `plan`, not from disk. But `newFiles` -- read from
    /// `destination` after `apply` returns -- would be empty, so
    /// `XCTAssertEqual(newFiles.count, result.added)` fails (0 != 1), and the following
    /// `Data(contentsOf:)` read of "1-2-LT1.save" throws because the broken `apply` never
    /// created it. That is exactly the gap the old test could not see.
    func testTheResultMatchesThePlanExactly() throws {
        try Data("something else".utf8)
            .write(to: destination.appendingPathComponent("1-1-LT1.save"))
        try Data("contents of 9-9-LT1.save".utf8)
            .write(to: destination.appendingPathComponent("9-9-LT1.save"))

        let before = names

        let source = try makeExport(names: ["1-1-LT1.save", "9-9-LT1.save"])
        let set = try SaveImporter.plan(source: source,
                                        resolve: { _ in self.destination },
                                        caps: .default)
        let result = try SaveImporter.apply(set.plans[0], source: source,
                                            into: destination)

        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.movedToNewSlot, 1)
        XCTAssertEqual(result.skipped, 1)

        let after = names
        let newFiles = after.subtracting(before)

        // `result.added` new files actually exist.
        XCTAssertEqual(newFiles.count, result.added,
                       "result.added does not match what actually landed on disk")

        // `result.movedToNewSlot` of them sit at a name differing from their source name
        // ("1-1-LT1.save" was taken, so the incoming file was placed at "1-2-LT1.save").
        XCTAssertEqual(newFiles, ["1-2-LT1.save"])
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("1-2-LT1.save")),
            Data("contents of 1-1-LT1.save".utf8),
            "the moved save's bytes must be the incoming file's, written for real")

        // The one skipped incoming name ("9-9-LT1.save") produced no new file: the
        // existing file is untouched, and nothing else on its page was created either.
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("9-9-LT1.save")),
            Data("contents of 9-9-LT1.save".utf8))
        XCTAssertFalse(after.contains("9-10-LT1.save"))
    }

    func testAnExistingSaveIsNeverReplaced() throws {
        let existing = Data("DO NOT LOSE THIS".utf8)
        try existing.write(to: destination.appendingPathComponent("1-1-LT1.save"))

        let source = try makeExport(names: ["1-1-LT1.save"])
        _ = try importAll(source)

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("1-1-LT1.save")),
            existing,
            "the pre-existing save was overwritten -- this is the one unacceptable bug")
        XCTAssertTrue(names.contains("1-2-LT1.save"))
    }

    func testImportingTheSameBackupTwiceChangesNothingTheSecondTime() throws {
        let source = try makeExport(names: ["1-1-LT1.save", "1-2-LT1.save"])

        _ = try importAll(source)
        let afterFirst = names

        let second = try importAll(source)
        XCTAssertEqual(names, afterFirst, "a second restore duplicated every slot")
        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(second.skipped, 2)
    }

    func testTheSentenceStatesWhatHappened() throws {
        try Data("other".utf8)
            .write(to: destination.appendingPathComponent("1-1-LT1.save"))
        let source = try makeExport(names: ["1-1-LT1.save"])
        let result = try importAll(source)

        XCTAssertTrue(result.sentence.contains("1"), result.sentence)
        XCTAssertTrue(result.sentence.lowercased().contains("new slot"), result.sentence)
    }

    func testTheDestinationIsCreatedIfMissing() throws {
        let fresh = root.appendingPathComponent("Fresh", isDirectory: true)
        let source = try makeExport(names: ["1-1-LT1.save"])
        let set = try SaveImporter.plan(source: source, resolve: { _ in fresh },
                                        caps: .default)
        _ = try SaveImporter.apply(set.plans[0], source: source, into: fresh)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fresh.appendingPathComponent("1-1-LT1.save").path))
    }

    func testABareSaveFileImports() throws {
        let bare = root.appendingPathComponent("5-1-LT1.save")
        try Data("from a pc".utf8).write(to: bare)

        let set = try SaveImporter.plan(source: bare, resolve: { _ in self.destination },
                                        caps: .default)
        _ = try SaveImporter.apply(set.plans[0], source: bare, into: destination)

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("5-1-LT1.save")),
            Data("from a pc".utf8))
    }

    func testATwoGameBackupRestoresEachGamesOwnBytes() throws {
        // The ambiguity sourcePrefix exists to remove. Both games have a save named
        // 1-1-LT1.save, with DIFFERENT contents; a last-component match could give beta
        // alpha's bytes and never error.
        let alphaSaves = root.appendingPathComponent("alphaSaves", isDirectory: true)
        let betaSaves = root.appendingPathComponent("betaSaves", isDirectory: true)
        for dir in [alphaSaves, betaSaves] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("ALPHA".utf8).write(to: alphaSaves.appendingPathComponent("1-1-LT1.save"))
        try Data("BETA".utf8).write(to: betaSaves.appendingPathComponent("1-1-LT1.save"))

        let backup = root.appendingPathComponent("backup.zip")
        _ = try SaveExporter.export(
            [SaveExportItem(gameId: "alpha", title: "Alpha", saveDirectory: "A", directory: alphaSaves),
             SaveExportItem(gameId: "beta", title: "Beta", saveDirectory: "B", directory: betaSaves)],
            kind: .backup, appVersion: "0.2.0", to: backup, now: Date())

        // Two genuinely separate destinations, one per game.
        let alphaOut = root.appendingPathComponent("outAlpha", isDirectory: true)
        let betaOut = root.appendingPathComponent("outBeta", isDirectory: true)

        let set = try SaveImporter.plan(source: backup, resolve: { plan in
            plan.gameId == "alpha" ? alphaOut : betaOut
        }, caps: .default)

        for plan in set.plans {
            let target = plan.gameId == "alpha" ? alphaOut : betaOut
            _ = try SaveImporter.apply(plan, source: backup, into: target)
        }

        XCTAssertEqual(
            try Data(contentsOf: alphaOut.appendingPathComponent("1-1-LT1.save")),
            Data("ALPHA".utf8))
        XCTAssertEqual(
            try Data(contentsOf: betaOut.appendingPathComponent("1-1-LT1.save")),
            Data("BETA".utf8),
            "beta received alpha's bytes -- the last-component match is ambiguous")
    }

    func testASaveWrittenBetweenPlanningAndApplyingIsNotOverwritten() throws {
        // The autosave race, and the only path that reaches the never-overwrite guards.
        // plan() sees an empty directory and plans 1-1-LT1.save into slot 1-1; the game
        // then autosaves into that slot while the confirmation sheet is still up.
        let source = try makeExport(names: ["1-1-LT1.save"])
        let set = try SaveImporter.plan(source: source,
                                        resolve: { _ in self.destination },
                                        caps: .default)

        let theirs = Data("WRITTEN WHILE THE SHEET WAS UP".utf8)
        try theirs.write(to: destination.appendingPathComponent("1-1-LT1.save"))

        XCTAssertThrowsError(
            try SaveImporter.apply(set.plans[0], source: source, into: destination)
        ) { error in
            XCTAssertEqual(error as? SaveTransferError,
                           .slotTakenSincePlanning(name: "1-1-LT1.save"))
        }

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("1-1-LT1.save")),
            theirs,
            "a save written after planning was overwritten -- the one unacceptable bug")
    }

    func testTwoPlacementsToTheSameSlotCannotDestroyTheFirst() throws {
        // plan() never emits two placements at the same destination -- SlotPlacement
        // guarantees each incoming save gets a free slot -- but SaveImportPlan and
        // Placement are both public, so a hand-built plan can ask for exactly that. The
        // write-time guards must refuse the second write rather than replace the first,
        // even though plan() itself can never produce this shape.
        let source = try makeExport(names: ["1-1-LT1.save", "1-2-LT1.save"])

        let slot = SaveSlot(page: "1", number: 1)
        let placements = [
            Placement(sourceName: "1-1-LT1.save", destination: slot, movedToNewSlot: false),
            Placement(sourceName: "1-2-LT1.save", destination: slot, movedToNewSlot: false),
        ]
        let plan = SaveImportPlan(gameId: "bigbaddogs", title: "Big Bad Dogs",
                                  isForeign: false, placements: placements,
                                  alreadyPresent: [], sourcePrefix: "saves")

        XCTAssertThrowsError(
            try SaveImporter.apply(plan, source: source, into: destination)
        ) { error in
            XCTAssertEqual(error as? SaveTransferError,
                           .slotTakenSincePlanning(name: "1-1-LT1.save"))
        }

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("1-1-LT1.save")),
            Data("contents of 1-1-LT1.save".utf8),
            "the second placement overwrote the first -- destinations must never collide")
    }
}
