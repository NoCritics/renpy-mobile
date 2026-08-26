import XCTest
@testable import VNPlayerCore

/// Unit-level tests for the decisions taken per entry, before anything is written.
///
/// These are separate from the fixture round-trips deliberately. A fixture proves the
/// pipeline handles a real archive; these prove the *policy* handles inputs that are
/// awkward to express as a real archive at all — Python's `zipfile` normalises
/// backslashes on write, for instance, so a "backslash traversal" fixture silently
/// becomes an ordinary traversal fixture and stops testing what its name claims.
final class SanitizeTests: XCTestCase {

    func testKeepsOrdinaryPaths() throws {
        XCTAssertEqual(try EntryPolicy.sanitize("game/script.rpy"), "game/script.rpy")
        XCTAssertEqual(try EntryPolicy.sanitize("a/b/c/d.png"), "a/b/c/d.png")
    }

    func testCollapsesRedundantComponents() throws {
        XCTAssertEqual(try EntryPolicy.sanitize("./game//script.rpy"), "game/script.rpy")
        XCTAssertEqual(try EntryPolicy.sanitize("game/./x.png"), "game/x.png")
    }

    func testEmptyPathsAreSkippedNotRejected() throws {
        XCTAssertNil(try EntryPolicy.sanitize(""))
        XCTAssertNil(try EntryPolicy.sanitize("."))
        XCTAssertNil(try EntryPolicy.sanitize("./"))
    }

    func testRejectsParentTraversal() {
        for path in ["../evil", "a/../../evil", "game/../../etc/passwd", ".."] {
            XCTAssertThrowsError(try EntryPolicy.sanitize(path), path) { error in
                XCTAssertEqual(error as? ImportError, .unsafePath(entry: path))
            }
        }
    }

    func testRejectsTraversalEvenWhenItWouldResolveInsideTheRoot() {
        // "a/../b" resolves to "b", which is safe -- and we still reject it. Resolving
        // rather than rejecting is how "a/../../b" gets through whenever "a" exists,
        // because the resolver cannot know whether "a" is real. A game has no reason to
        // reference a parent directory, so the rule is absolute.
        XCTAssertThrowsError(try EntryPolicy.sanitize("a/../b"))
    }

    func testRejectsBackslashTraversal() {
        // The fixture for this cannot be built with Python's zipfile: it rewrites
        // backslashes to forward slashes on write, so the archive ends up containing an
        // ordinary traversal. Tested here instead, on the raw string a Windows-packed
        // archive really can carry.
        for path in ["..\\..\\windows\\evil.dll", "game\\..\\..\\evil"] {
            XCTAssertThrowsError(try EntryPolicy.sanitize(path), path)
        }
    }

    func testTreatsBackslashAsSeparatorNotAsText() throws {
        // The safe case of the same rule: a backslash path with no traversal must
        // normalise, not survive as one long filename containing backslashes.
        XCTAssertEqual(try EntryPolicy.sanitize("game\\gui\\icon.png"), "game/gui/icon.png")
    }

    func testRejectsAbsolutePaths() {
        XCTAssertThrowsError(try EntryPolicy.sanitize("/etc/passwd"))
        XCTAssertThrowsError(try EntryPolicy.sanitize("/"))
    }

    func testRejectsWindowsDrivePaths() {
        for path in ["C:/Windows/evil.dll", "C:evil.dll", "d:/x"] {
            XCTAssertThrowsError(try EntryPolicy.sanitize(path), path)
        }
    }

    func testRejectsEmbeddedNulls() {
        XCTAssertThrowsError(try EntryPolicy.sanitize("game/scr\u{0}ipt.rpy"))
    }
}

final class PruningTests: XCTestCase {

    private func disposition(_ path: String, isDirectory: Bool = false) -> EntryDisposition {
        EntryPolicy.disposition(
            relativePath: path, isDirectory: isDirectory, pruneDesktopFiles: true)
    }

    func testPrunesDesktopBinaries() {
        for path in ["MyGame.exe", "run.sh", "setup.bat", "go.command", "x.dll", "y.so", "z.dylib"] {
            XCTAssertEqual(disposition(path), .prune(path), path)
        }
    }

    func testPrunesRootLibAndRenpy() {
        XCTAssertEqual(disposition("lib/py3-windows-x86_64/python.dll"),
                       .prune("lib/py3-windows-x86_64/python.dll"))
        XCTAssertEqual(disposition("renpy/__init__.py"), .prune("renpy/__init__.py"))
    }

    func testNeverPrunesAnythingUnderGame() {
        // The regression this scoping exists for. An earlier draft pruned any directory
        // named "lib" at any depth, which would have silently gutted a game shipping
        // game/lib/ -- and the user would have seen a game that imports fine and then
        // crashes on a missing module.
        XCTAssertEqual(disposition("game/lib/helper.rpy"), .extract("game/lib/helper.rpy"))
        XCTAssertEqual(disposition("game/renpy/compat.rpy"), .extract("game/renpy/compat.rpy"))
        XCTAssertEqual(disposition("game/tools/build.sh"), .extract("game/tools/build.sh"))
    }

    func testPrunesMacAppBundles() {
        XCTAssertEqual(disposition("MyGame.app/Contents/MacOS/MyGame"),
                       .prune("MyGame.app/Contents/MacOS/MyGame"))
    }

    func testKeepsEverythingUnrecognised() {
        // An allowlist would break games shipping assets we did not anticipate, so
        // anything not explicitly denied is extracted.
        for path in ["game/data.rpa", "game/weird.customext", "README.txt", "extras/art.psd"] {
            XCTAssertEqual(disposition(path), .extract(path), path)
        }
    }

    func testPruningDisabledExtractsEverything() {
        XCTAssertEqual(
            EntryPolicy.disposition(
                relativePath: "MyGame.exe", isDirectory: false, pruneDesktopFiles: false),
            .extract("MyGame.exe")
        )
    }
}

final class FilenameDecodingTests: XCTestCase {

    func testPrefersUTF8WhenItSucceeds() {
        XCTAssertEqual(
            EntryPolicy.decodeFilename(
                utf8Attempt: "game/効果音.ogg",
                shiftJISAttempt: "game/mojibake",
                libraryDefault: "game/cp437"),
            "game/効果音.ogg"
        )
    }

    func testFallsBackToShiftJISWhenUTF8Fails() {
        XCTAssertEqual(
            EntryPolicy.decodeFilename(
                utf8Attempt: "",
                shiftJISAttempt: "game/効果音.ogg",
                libraryDefault: "game/cp437"),
            "game/効果音.ogg"
        )
    }

    func testFallsBackToLibraryDefaultWhenBothFail() {
        XCTAssertEqual(
            EntryPolicy.decodeFilename(
                utf8Attempt: "", shiftJISAttempt: "", libraryDefault: "game/cp437"),
            "game/cp437"
        )
    }
}

final class GameIdentityTests: XCTestCase {

    func testStripsRealDistributionNames() {
        let cases: [(String, String, String)] = [
            // (top-level directory, expected title, expected id)
            ("MyGame-1.2.3-pc", "MyGame", "mygame"),
            ("MyGame-pc", "MyGame", "mygame"),
            ("Doki Doki Literature Club-1.1.1-market", "Doki Doki Literature Club",
             "doki-doki-literature-club"),
            ("Some_Game-linux", "Some_Game", "some-game"),
            ("Katawa Shoujo-all", "Katawa Shoujo", "katawa-shoujo"),
            ("Game-v1.0-pc", "Game", "game"),
            ("PlainName", "PlainName", "plainname"),
        ]

        for (input, expectedTitle, expectedId) in cases {
            let identity = GameIdentityDeriver.derive(
                topLevelDirectory: input, archiveFileName: "ignored.zip")
            XCTAssertEqual(identity.title, expectedTitle, input)
            XCTAssertEqual(identity.id, expectedId, input)
        }
    }

    func testDoesNotEatATrailingNumberThatIsPartOfTheName() {
        // "Portal 2" must not become "Portal". A version is only recognised after a
        // hyphen or underscore, never after a space.
        let identity = GameIdentityDeriver.derive(
            topLevelDirectory: "Portal 2", archiveFileName: "ignored.zip")
        XCTAssertEqual(identity.title, "Portal 2")
        XCTAssertEqual(identity.id, "portal-2")
    }

    func testFallsBackToArchiveFileName() {
        let identity = GameIdentityDeriver.derive(
            topLevelDirectory: nil, archiveFileName: "Fancy Game-1.0-pc.zip")
        XCTAssertEqual(identity.title, "Fancy Game")
        XCTAssertEqual(identity.id, "fancy-game")
    }

    func testKeepsNonLatinScripts() {
        // Slugging to "" would be worse than useless -- every Japanese-titled game would
        // collide with every other one.
        let identity = GameIdentityDeriver.derive(
            topLevelDirectory: "月に寄りそう", archiveFileName: "x.zip")
        XCTAssertEqual(identity.id, "月に寄りそう")
    }

    func testResolvesCollisions() {
        XCTAssertEqual(GameIdentityDeriver.uniqueId("mygame", taken: []), "mygame")
        XCTAssertEqual(GameIdentityDeriver.uniqueId("mygame", taken: ["mygame"]), "mygame-2")
        XCTAssertEqual(
            GameIdentityDeriver.uniqueId("mygame", taken: ["mygame", "mygame-2"]), "mygame-3")
    }

    func testEmptySlugBecomesUsable() {
        // A title of only punctuation slugs to "", which is not a directory name.
        XCTAssertEqual(GameIdentityDeriver.slug("!!!"), "")
        XCTAssertEqual(GameIdentityDeriver.uniqueId("", taken: []), "game")
        XCTAssertEqual(GameIdentityDeriver.uniqueId("", taken: ["game"]), "game-2")
    }
}

final class ImportCapsSizeTests: XCTestCase {

    private let gib = Int64(1_073_741_824)

    func testTheDefaultsAccommodateARealVisualNovel() {
        // Measured against the library this app exists to read: games run 4-8 GB, and
        // their assets usually sit in one or two .rpa archives, so one entry can pass
        // 4 GiB by itself. The old defaults (8 GiB total, 4 GiB per entry) rejected
        // exactly that. This test is the product decision written down, so lowering it
        // back has to be deliberate rather than tidy-looking.
        let caps = ImportCaps.default

        XCTAssertGreaterThan(caps.maxTotalUncompressed, 8 * gib,
                             "an 8 GB game must not sit at the boundary of the total cap")
        XCTAssertGreaterThan(caps.maxEntryUncompressed, 6 * gib,
                             "a single .rpa in a large game routinely passes 4 GiB")
    }

    func testTheBombDefencesAreNotTheSizeCaps() {
        // Raising the size caps is only safe because neither of these moved. A zip bomb
        // is defined by expanding absurdly, not by being large -- real game assets are
        // already compressed and barely shrink.
        XCTAssertEqual(ImportCaps.default.maxCompressionRatio, 1000)
        XCTAssertEqual(ImportCaps.default.maxEntries, 100_000)
    }

    func testTheTotalCapSitsAboveAnyPlausiblePhone() {
        // Deliberate: free space is the real limit and is checked separately against the
        // volume, with a message naming both numbers. Keeping the cap above any device
        // capacity means that check -- the one that can say something useful -- is the
        // one the reader hears from.
        XCTAssertGreaterThanOrEqual(ImportCaps.default.maxTotalUncompressed, 64 * gib)
    }
}
