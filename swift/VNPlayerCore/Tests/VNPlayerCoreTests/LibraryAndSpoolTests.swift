import XCTest
@testable import VNPlayerCore

private func makeTempPaths() throws -> (VNPlayerPaths, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("vnplayer-\(UUID().uuidString)", isDirectory: true)
    let paths = VNPlayerPaths(
        documents: root.appendingPathComponent("Documents", isDirectory: true),
        applicationSupport: root.appendingPathComponent("Support", isDirectory: true)
    )
    try paths.createDirectories()
    return (paths, root)
}

final class LibraryStoreTests: XCTestCase {

    private var paths: VNPlayerPaths!
    private var root: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        (paths, root) = try makeTempPaths()
        store = LibraryStore(paths: paths)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeGameDirectory(_ id: String) throws {
        try FileManager.default.createDirectory(
            at: paths.gameDirectory(id).appendingPathComponent("game", isDirectory: true),
            withIntermediateDirectories: true)
    }

    func testUpsertPersistsAndReloads() throws {
        try makeGameDirectory("mygame")
        let entry = LibraryEntry(id: "mygame", title: "My Game", detectedEngine: .renpy8)

        _ = try store.upsert(entry)

        let reloaded = LibraryStore(paths: paths).load()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.title, "My Game")
        XCTAssertEqual(reloaded.first?.detectedEngine, .renpy8)
    }

    /// The join C1 was missing: Task 7 built `ProtocolMessages.gameReadySaveDirectory`,
    /// Task 8 read `LibraryEntry.saveDirectory`, and nothing ever wrote the field onto a
    /// stored entry. `LibraryModel.swift`'s `gameReady` handler is the actual call site,
    /// but it lives in `spike/`, which has no XCTest target at all -- so this exercises
    /// the closest reachable seam: extracting the directory from a real `gameReady`
    /// payload via `ProtocolMessages.gameReadySaveDirectory`, then joining it onto the
    /// stored entry through the same `LibraryStore.upsert` path `LibraryModel` uses.
    /// A regression in the glue code itself (wrong id, wrong guard) is NOT caught by
    /// this test -- only a regression in the join's two halves would be.
    func testGameReadySaveDirectoryIsJoinedOntoStoredEntry() throws {
        try makeGameDirectory("bigbaddogs")
        _ = try store.upsert(LibraryEntry(id: "bigbaddogs", title: "Big Bad Dogs"))

        let payload: [String: Any] = [
            "event": "gameReady",
            "commandId": "abc",
            "saveDirectory": "BigBadDogs-1489443940",
        ]

        guard let directory = ProtocolMessages.gameReadySaveDirectory(payload) else {
            XCTFail("expected a save directory from the payload")
            return
        }

        var entries = store.load()
        guard let index = entries.firstIndex(where: { $0.id == "bigbaddogs" }) else {
            XCTFail("entry not found")
            return
        }
        entries[index].saveDirectory = directory
        _ = try store.upsert(entries[index])

        let reloaded = LibraryStore(paths: paths).load()
        XCTAssertEqual(reloaded.first(where: { $0.id == "bigbaddogs" })?.saveDirectory,
                       "BigBadDogs-1489443940")
    }

    func testCorruptIndexRebuildsFromManifestsWithMetadataIntact() throws {
        try makeGameDirectory("mygame")
        _ = try store.upsert(LibraryEntry(
            id: "mygame", title: "Proper Title", detectedEngine: .renpy8, crashCount: 3))

        // Corrupt the index the way a Files-app tap or an interrupted write would.
        try Data("{ this is not json".utf8).write(to: paths.libraryIndex)

        let recovered = LibraryStore(paths: paths).load()

        XCTAssertEqual(recovered.count, 1)
        // The point of the per-game manifest. A rescan of directory NAMES alone would
        // recover the game but call it "mygame" with engine .unknown and crashCount 0 --
        // silently downgrading every game's metadata the first time the index is damaged.
        XCTAssertEqual(recovered.first?.title, "Proper Title")
        XCTAssertEqual(recovered.first?.detectedEngine, .renpy8)
        XCTAssertEqual(recovered.first?.crashCount, 3)
    }

    func testRescanInventsAnEntryForAHandPlacedGame() throws {
        // A directory dropped in via the Files app has no manifest. It should still show
        // up rather than being ignored, because being able to do that by hand is half
        // the reason Documents/ is exposed at all.
        try makeGameDirectory("dropped-in-by-hand")

        let entries = LibraryStore(paths: paths).load()
        XCTAssertEqual(entries.map(\.id), ["dropped-in-by-hand"])
        XCTAssertEqual(entries.first?.detectedEngine, .unknown)
    }

    func testEntriesWhoseDirectoryVanishedAreDropped() throws {
        try makeGameDirectory("ghost")
        _ = try store.upsert(LibraryEntry(id: "ghost", title: "Ghost"))

        try FileManager.default.removeItem(at: paths.gameDirectory("ghost"))

        // An index still listing it would offer a launch that fails for no visible
        // reason.
        XCTAssertEqual(LibraryStore(paths: paths).load(), [])
    }

    func testInstallOverExistingGameSucceeds() throws {
        // moveItem() fails outright when the destination exists, so the naive version of
        // this breaks on the happy path of re-importing to update a game. Both reviewers
        // flagged it.
        try makeGameDirectory("mygame")
        try Data("old".utf8).write(
            to: paths.gameDirectory("mygame").appendingPathComponent("marker.txt"))

        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: staging.appendingPathComponent("marker.txt"))

        try store.install(stagedAt: staging, as: "mygame")

        let marker = try Data(contentsOf:
            paths.gameDirectory("mygame").appendingPathComponent("marker.txt"))
        XCTAssertEqual(marker, Data("new".utf8))
    }

    func testReimportPreservesSaves() throws {
        try makeGameDirectory("mygame")
        let save = paths.saveDirectory("mygame").appendingPathComponent("slot-1.save")
        try FileManager.default.createDirectory(
            at: paths.saveDirectory("mygame"), withIntermediateDirectories: true)
        try Data("progress".utf8).write(to: save)

        let staging = root.appendingPathComponent("staging2", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try store.install(stagedAt: staging, as: "mygame")

        // The entire reason saves live outside the game tree.
        XCTAssertEqual(try Data(contentsOf: save), Data("progress".utf8))
    }

    func testDeleteRemovesGameButKeepsSavesByDefault() throws {
        try makeGameDirectory("mygame")
        try FileManager.default.createDirectory(
            at: paths.saveDirectory("mygame"), withIntermediateDirectories: true)
        let save = paths.saveDirectory("mygame").appendingPathComponent("slot-1.save")
        try Data("progress".utf8).write(to: save)
        _ = try store.upsert(LibraryEntry(id: "mygame", title: "My Game"))

        let remaining = try store.delete("mygame")

        XCTAssertEqual(remaining, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.gameDirectory("mygame").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: save.path))
    }

    func testDeleteCanAlsoRemoveSaves() throws {
        try makeGameDirectory("mygame")
        try FileManager.default.createDirectory(
            at: paths.saveDirectory("mygame"), withIntermediateDirectories: true)
        _ = try store.upsert(LibraryEntry(id: "mygame", title: "My Game"))

        _ = try store.delete("mygame", alsoDeleteSaves: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.saveDirectory("mygame").path))
    }
}

final class SpoolTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testWriteThenDrainRoundTrips() throws {
        let spool = Spool(directory: directory)
        try spool.write(["command": "launch", "gameId": "mygame"])

        let messages = spool.drain()
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.payload["command"] as? String, "launch")
        XCTAssertEqual(messages.first?.payload["gameId"] as? String, "mygame")
    }

    func testDrainConsumes() throws {
        let spool = Spool(directory: directory)
        try spool.write(["command": "launch"])

        XCTAssertEqual(spool.drain().count, 1)
        // The bug the append-only mailbox had in reverse: a message that is not consumed
        // replays every frame, relaunching forever.
        XCTAssertEqual(spool.drain().count, 0)
    }

    func testMessagesDrainInWriteOrder() throws {
        let spool = Spool(directory: directory)
        for index in 0..<10 {
            try spool.write(["n": index])
        }

        let order = spool.drain().compactMap { $0.payload["n"] as? Int }
        XCTAssertEqual(order, Array(0..<10))
    }

    func testPartiallyWrittenMessageIsInvisible() throws {
        // The race the spool exists to eliminate. A reader must never see a half-written
        // message: the writer builds it under .tmp, which drain() does not look at.
        let spool = Spool(directory: directory)
        try Data("{ \"command\": \"lau".utf8).write(
            to: directory.appendingPathComponent("0000-partial.json.tmp"))

        XCTAssertEqual(spool.drain().count, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("0000-partial.json.tmp").path),
            "drain deleted a temp file it should not even see")
    }

    func testWritingWhileDrainingLosesNothing() throws {
        // The specific failure of the old design: read-then-delete destroys anything
        // written in between. Here each message is its own file, so a write during a
        // drain is simply picked up by the next one.
        let spool = Spool(directory: directory)
        try spool.write(["n": 1])

        let first = spool.drain()
        try spool.write(["n": 2])
        let second = spool.drain()

        XCTAssertEqual(first.compactMap { $0.payload["n"] as? Int }, [1])
        XCTAssertEqual(second.compactMap { $0.payload["n"] as? Int }, [2])
    }

    func testUnparseableMessageIsDiscardedNotRetriedForever() throws {
        let spool = Spool(directory: directory)
        try Data("not json at all".utf8).write(
            to: directory.appendingPathComponent("0001-bad.json"))

        XCTAssertEqual(spool.drain().count, 0)
        XCTAssertEqual(spool.drain().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("0001-bad.json").path))
    }

    func testClearDropsStaleCommandsWithoutReadingThem() throws {
        // Commands written before the app was killed are stale by definition. Replaying
        // them would relaunch a game the user did not ask for -- possibly the one that
        // killed the app in the first place.
        let spool = Spool(directory: directory)
        try spool.write(["command": "launch", "gameId": "the-one-that-crashed"])

        spool.clear()

        XCTAssertEqual(spool.drain().count, 0)
    }
}
