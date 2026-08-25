import XCTest
@testable import VNPlayerCore

final class SaveManifestTests: XCTestCase {

    private func sample(format: Int = SaveManifest.currentFormat) -> SaveManifest {
        SaveManifest(
            format: format,
            kind: .game,
            exportedAt: Date(timeIntervalSince1970: 1_800_000_000),
            appVersion: "0.2.0",
            games: [
                .init(gameId: "bigbaddogs",
                      title: "Big Bad Dogs",
                      saveDirectory: "BigBadDogs-1489443940",
                      files: [.init(name: "1-1-LT1.save", bytes: 481_203, sha256: "ab12")])
            ])
    }

    func testRoundTrip() throws {
        let data = try SaveManifest.encode(sample())
        XCTAssertEqual(try SaveManifest.decode(data), sample())
    }

    func testAFutureFormatIsReportedNotGuessedAt() throws {
        let data = try SaveManifest.encode(sample(format: SaveManifest.currentFormat + 1))
        XCTAssertThrowsError(try SaveManifest.decode(data)) { error in
            XCTAssertEqual(error as? SaveTransferError,
                           .formatTooNew(SaveManifest.currentFormat + 1))
        }
    }

    func testAFutureFormatIsReportedEvenWhenItsSHAPEIsAlsoIncompatible() throws {
        // The case the format number actually exists for, and the one the previous
        // ordering got wrong: a breaking layout change. Here `games` is an object where
        // today's decoder wants an array, so a decode-first implementation throws
        // .notASaveArchive -- telling the reader their backup is junk -- instead of
        // .formatTooNew, which tells them to update the app.
        let json = """
        {"format": 99, "kind": "game", "exportedAt": "2027-01-15T08:00:00Z",
         "appVersion": "9.0", "games": {"unexpected": "shape"}}
        """
        XCTAssertThrowsError(try SaveManifest.decode(Data(json.utf8))) { error in
            XCTAssertEqual(error as? SaveTransferError, .formatTooNew(99))
        }
    }

    func testANullSaveDirectorySurvivesTheRoundTrip() throws {
        // config.save_directory may be None (renpy/config.py:369). Losing the
        // distinction between "null" and "absent" would break WHERE-TO-PUT-THESE.txt.
        var manifest = sample()
        manifest.games[0].saveDirectory = nil
        let decoded = try SaveManifest.decode(try SaveManifest.encode(manifest))
        XCTAssertNil(decoded.games[0].saveDirectory)
    }

    func testGarbageIsNotAManifest() {
        XCTAssertThrowsError(try SaveManifest.decode(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? SaveTransferError, .notASaveArchive)
        }
    }

    func testDatesAreISO8601SoAPersonCanReadTheFile() throws {
        let text = String(decoding: try SaveManifest.encode(sample()), as: UTF8.self)
        XCTAssertTrue(text.contains("2027-01-15T"), text)
    }

    func testEveryErrorHasASentenceNotACode() {
        let errors: [SaveTransferError] = [
            .notASaveArchive, .noSaveFilesFound, .looksLikeAGameArchive,
            .formatTooNew(9), .damagedFile(name: "1-1-LT1.save"),
            .noSuchGame("Big Bad Dogs"), .cannotOpenArchive,
            .writeFailed(name: "1-1-LT1.save"),
        ]

        for error in errors {
            let message = error.userMessage
            XCTAssertGreaterThan(message.split(separator: " ").count, 3,
                                 "\(error) has a code, not a message")
            // A sentence ends. "ERR SAVE FORMAT NEWER THAN APP" is six words and still a code.
            XCTAssertTrue(message.hasSuffix(".") || message.hasSuffix("?"),
                          "\(error) does not end like a sentence: \(message)")
            XCTAssertFalse(message.uppercased() == message,
                           "\(error) is shouting an identifier: \(message)")
        }

        // The interpolated cases must actually name the thing they are about, or the
        // reader cannot act on them.
        XCTAssertTrue(SaveTransferError.damagedFile(name: "1-1-LT1.save")
                        .userMessage.contains("1-1-LT1.save"))
        XCTAssertTrue(SaveTransferError.noSuchGame("Big Bad Dogs")
                        .userMessage.contains("Big Bad Dogs"))
        XCTAssertTrue(SaveTransferError.formatTooNew(9).userMessage.contains("9"))
        XCTAssertTrue(SaveTransferError.writeFailed(name: "1-1-LT1.save")
                        .userMessage.contains("1-1-LT1.save"))
    }

    func testDigestIsStableAndLowercaseHex() {
        let digest = SaveDigest.sha256(of: Data("hello".utf8))
        XCTAssertEqual(
            digest,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }
}
