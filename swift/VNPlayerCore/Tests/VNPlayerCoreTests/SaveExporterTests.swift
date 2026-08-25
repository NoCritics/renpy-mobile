import XCTest
import ZIPFoundation
@testable import VNPlayerCore

final class SaveExporterTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A save directory holding `names`, each with distinct contents.
    private func makeSaveDirectory(_ names: [String]) throws -> URL {
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names {
            try Data("contents of \(name)".utf8)
                .write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    private func item(_ dir: URL, id: String = "bigbaddogs",
                      saveDirectory: String? = "BBD-1") -> SaveExportItem {
        SaveExportItem(gameId: id, title: "Big Bad Dogs",
                       saveDirectory: saveDirectory, directory: dir)
    }

    func testSummariseCountsOnlySaveFiles() throws {
        let dir = try makeSaveDirectory(["1-1-LT1.save", "2-1-LT1.save", "persistent"])
        let summary = SaveExporter.summarise([item(dir)])
        XCTAssertEqual(summary.fileCount, 2, "persistent is not a save slot")
    }

    func testExportProducesAReadableZipWithManifestAndNote() throws {
        let dir = try makeSaveDirectory(["1-1-LT1.save"])
        let out = root.appendingPathComponent("out.zip")

        _ = try SaveExporter.export([item(dir)], kind: .game, appVersion: "0.2.0",
                                    to: out, now: Date(timeIntervalSince1970: 1_800_000_000))

        let archive = try XCTUnwrap(try? Archive(url: out, accessMode: .read))
        let paths = Set(archive.map(\.path))
        XCTAssertTrue(paths.contains(SaveManifest.fileName), "\(paths)")
        XCTAssertTrue(paths.contains("WHERE-TO-PUT-THESE.txt"), "\(paths)")
        XCTAssertTrue(paths.contains("saves/1-1-LT1.save"), "\(paths)")
    }

    func testBackupPutsEachGameUnderItsOwnId() throws {
        let a = try makeSaveDirectory(["1-1-LT1.save"])
        let b = try makeSaveDirectory(["1-1-LT1.save"])
        let out = root.appendingPathComponent("backup.zip")

        _ = try SaveExporter.export(
            [item(a, id: "alpha"), item(b, id: "beta")],
            kind: .backup, appVersion: "0.2.0", to: out, now: Date())

        let archive = try XCTUnwrap(try? Archive(url: out, accessMode: .read))
        let paths = Set(archive.map(\.path))
        XCTAssertTrue(paths.contains("games/alpha/1-1-LT1.save"), "\(paths)")
        XCTAssertTrue(paths.contains("games/beta/1-1-LT1.save"), "\(paths)")
    }

    func testTheManifestRecordsEveryFileWithItsRealDigest() throws {
        let dir = try makeSaveDirectory(["1-1-LT1.save"])
        let out = root.appendingPathComponent("out.zip")
        _ = try SaveExporter.export([item(dir)], kind: .game, appVersion: "0.2.0",
                                    to: out, now: Date())

        let archive = try XCTUnwrap(try? Archive(url: out, accessMode: .read))
        let entry = try XCTUnwrap(archive[SaveManifest.fileName])
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }

        let manifest = try SaveManifest.decode(data)
        XCTAssertEqual(manifest.kind, .game)
        XCTAssertEqual(manifest.games.count, 1)
        XCTAssertEqual(manifest.games[0].files.count, 1)
        XCTAssertEqual(manifest.games[0].files[0].sha256,
                       SaveDigest.sha256(of: Data("contents of 1-1-LT1.save".utf8)))
        XCTAssertEqual(manifest.games[0].saveDirectory, "BBD-1")
    }

    func testANullSaveDirectorySurvivesIntoTheManifest() throws {
        let dir = try makeSaveDirectory(["1-1-LT1.save"])
        let out = root.appendingPathComponent("out.zip")
        _ = try SaveExporter.export([item(dir, saveDirectory: nil)], kind: .game,
                                    appVersion: "0.2.0", to: out, now: Date())

        let archive = try XCTUnwrap(try? Archive(url: out, accessMode: .read))
        let entry = try XCTUnwrap(archive[SaveManifest.fileName])
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        XCTAssertNil(try SaveManifest.decode(data).games[0].saveDirectory)
    }

    func testExportingAGameWithNoSavesIsRefusedInWords() throws {
        let dir = try makeSaveDirectory([])
        let out = root.appendingPathComponent("out.zip")
        XCTAssertThrowsError(
            try SaveExporter.export([item(dir)], kind: .game, appVersion: "0.2.0",
                                    to: out, now: Date())
        ) { error in
            XCTAssertEqual(error as? SaveTransferError, .noSaveFilesFound)
        }
    }

    func testSaveFilesAreStoredNotDeflated() throws {
        // A .save is already a ZIP (loadsave.py:110). Deflating it again spends CPU on
        // a phone to make the file marginally larger.
        let dir = try makeSaveDirectory(["1-1-LT1.save"])
        let out = root.appendingPathComponent("out.zip")
        _ = try SaveExporter.export([item(dir)], kind: .game, appVersion: "0.2.0",
                                    to: out, now: Date())

        let archive = try XCTUnwrap(try? Archive(url: out, accessMode: .read))
        let entry = try XCTUnwrap(archive["saves/1-1-LT1.save"])
        XCTAssertEqual(entry.type, .file)
        XCTAssertEqual(entry.compressedSize, entry.uncompressedSize)
    }
}
