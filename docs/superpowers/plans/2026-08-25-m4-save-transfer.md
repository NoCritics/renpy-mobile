# M4 Save Transfer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export a game's Ren'Py saves to a `.zip` a PC can open, back up every game at once, and import either back — without ever destroying an existing save.

**Architecture:** All the logic lands in `VNPlayerCore`, which is Foundation-only and tested headlessly by `swift test`; the iOS app layer in `spike/` only presents it. Import is split into a **plan** phase that touches no disk and an **apply** phase that executes exactly that plan, because §4.5's confirmation sheet is a rendering of the plan. The one new piece of engine data — `config.save_directory` — arrives on the existing `gameReady` event rather than through a new channel.

**Tech Stack:** Swift 5.9, Foundation, CryptoKit (SHA-256), vendored ZIPFoundation, XCTest. Python 3 + `unittest` for the shell half. XcodeGen + GitHub Actions `macos-15`.

**Spec:** `docs/superpowers/specs/2026-08-25-m4-save-transfer-design.md`

## Global Constraints

- **No secrets in CI, ever.** No certificates, no provisioning profiles, no repository secrets. The build must work identically on any fork.
- **Never modify Ren'Py's source.** Nothing under `vendor/` is edited. `vendor/` is SHA-256 verified by `scripts/verify_third_party.sh`; never install packages into it.
- **Never raise a threshold or weaken an assertion to make a check pass.**
- **The app never downloads a game** (App Store 2.5.2 posture). No network in any code path added here.
- Licence MIT. GPLv3 forbidden. No new third-party dependencies — ZIPFoundation is already vendored; use it.
- Deployment target iOS 15. `VNPlayerCore` declares `.iOS(.v13)`, so **CryptoKit is available** (iOS 13+) but `async`/`await` APIs gated above 15 are not — keep `VNPlayerCore` synchronous.
- A save slot named `3-2` is the file **`3-2-LT1.save`**. `renpy.savegame_suffix == "-LT1.save"` (`renpy/__init__.py:144`). Never write a save file without that suffix.
- **The page of a slot is everything before the FINAL dash.** `auto-1` is page `auto`, number 1. Splitting on the first dash is a bug.
- A `.save` file is already a ZIP archive (`loadsave.py:110`). Add it to an export with `compressionMethod: .none`.
- **Import never overwrites or deletes an existing save file.** No exception, no flag, no "advanced" option.
- The UI must never show anything that reads as "verified safe" for an imported save. See spec §6.
- No Mac locally: Swift compiles only in CI. Python tests run locally with `python -m pytest tests/ -q`.

---

### Task 1: SaveSlot and SlotPlacement — the never-destroy rule, pure

**Files:**
- Create: `swift/VNPlayerCore/Sources/VNPlayerCore/SlotPlacement.swift`
- Test: `swift/VNPlayerCore/Tests/VNPlayerCoreTests/SlotPlacementTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public struct SaveSlot: Equatable, Hashable` with `page: String`, `number: Int`, `slotName: String`, `fileName: String`, `static let suffix = "-LT1.save"`, `init(page:number:)`, `init?(fileName: String)`
  - `public struct Placement: Equatable` with `sourceName: String`, `destination: SaveSlot`, `movedToNewSlot: Bool`
  - `public enum SlotPlacement` with `static func nextFree(page: String, taken: Set<SaveSlot>) -> SaveSlot` and `static func place(incoming: [String], existing: Set<String>) -> [Placement]`

This file must not import anything but Foundation and must never touch the file system. It is the rule with the sharpest consequence for being wrong, so it is testable without a zip, a directory, or a device.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import VNPlayerCore

final class SlotPlacementTests: XCTestCase {

    // MARK: SaveSlot parsing

    func testParsesANumberedPage() throws {
        let slot = try XCTUnwrap(SaveSlot(fileName: "3-2-LT1.save"))
        XCTAssertEqual(slot.page, "3")
        XCTAssertEqual(slot.number, 2)
        XCTAssertEqual(slot.slotName, "3-2")
        XCTAssertEqual(slot.fileName, "3-2-LT1.save")
    }

    func testPageIsEverythingBeforeTheFINALDash() throws {
        // The whole rule turns on this. Splitting on the first dash puts auto-1 on a
        // page called "auto" for one game and somewhere else for the next.
        let auto = try XCTUnwrap(SaveSlot(fileName: "auto-1-LT1.save"))
        XCTAssertEqual(auto.page, "auto")
        XCTAssertEqual(auto.number, 1)

        let quick = try XCTUnwrap(SaveSlot(fileName: "quick-3-LT1.save"))
        XCTAssertEqual(quick.page, "quick")
        XCTAssertEqual(quick.number, 3)
    }

    func testRejectsAnythingThatIsNotASaveFile() {
        XCTAssertNil(SaveSlot(fileName: "3-2.save"))          // wrong suffix
        XCTAssertNil(SaveSlot(fileName: "persistent"))
        XCTAssertNil(SaveSlot(fileName: "-LT1.save"))         // no slot name
        XCTAssertNil(SaveSlot(fileName: "nodash-LT1.save"))   // no number
        XCTAssertNil(SaveSlot(fileName: "3-x-LT1.save"))      // number is not a number
    }

    // MARK: nextFree

    func testNextFreeSkipsTakenNumbers() {
        let taken: Set<SaveSlot> = [
            SaveSlot(page: "1", number: 1),
            SaveSlot(page: "1", number: 2),
        ]
        XCTAssertEqual(SlotPlacement.nextFree(page: "1", taken: taken),
                       SaveSlot(page: "1", number: 3))
    }

    func testNextFreeIsPerPage() {
        let taken: Set<SaveSlot> = [SaveSlot(page: "1", number: 1)]
        XCTAssertEqual(SlotPlacement.nextFree(page: "2", taken: taken),
                       SaveSlot(page: "2", number: 1))
    }

    func testNextFreeFillsAHoleRatherThanAppending() {
        let taken: Set<SaveSlot> = [
            SaveSlot(page: "1", number: 1),
            SaveSlot(page: "1", number: 3),
        ]
        XCTAssertEqual(SlotPlacement.nextFree(page: "1", taken: taken),
                       SaveSlot(page: "1", number: 2))
    }

    // MARK: place

    func testAFreeSlotKeepsItsName() {
        let plan = SlotPlacement.place(incoming: ["1-1-LT1.save"], existing: [])
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].destination.fileName, "1-1-LT1.save")
        XCTAssertFalse(plan[0].movedToNewSlot)
    }

    func testATakenSlotMovesAndSaysSo() {
        let plan = SlotPlacement.place(incoming: ["1-1-LT1.save"],
                                       existing: ["1-1-LT1.save"])
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].sourceName, "1-1-LT1.save")
        XCTAssertEqual(plan[0].destination.fileName, "1-2-LT1.save")
        XCTAssertTrue(plan[0].movedToNewSlot)
    }

    func testTwoIncomingFilesForTheSameTakenSlotDoNotCollideWithEachOther() {
        // The second one must see the first one's destination as taken. Without that,
        // both land on 1-2 and one silently overwrites the other -- which is the exact
        // failure this whole rule exists to prevent.
        let plan = SlotPlacement.place(incoming: ["1-1-LT1.save", "1-1-LT1.save"],
                                       existing: ["1-1-LT1.save"])
        XCTAssertEqual(Set(plan.map(\.destination.fileName)),
                       ["1-2-LT1.save", "1-3-LT1.save"])
    }

    func testTheSuffixSurvivesEveryRename() {
        let plan = SlotPlacement.place(
            incoming: ["auto-1-LT1.save", "quick-1-LT1.save"],
            existing: ["auto-1-LT1.save", "quick-1-LT1.save"])
        for placement in plan {
            XCTAssertTrue(placement.destination.fileName.hasSuffix("-LT1.save"),
                          "a renamed save without the suffix stops being a save")
        }
    }

    func testAutoAndQuickPagesAreOrdinaryPages() {
        let plan = SlotPlacement.place(incoming: ["auto-1-LT1.save"],
                                       existing: ["auto-1-LT1.save"])
        XCTAssertEqual(plan[0].destination.fileName, "auto-2-LT1.save")
    }

    func testUnparseableIncomingNamesAreDropped() {
        // A file that is not a save cannot be given a slot. Dropping it here means the
        // importer never writes it, which is correct: only saves belong in a save dir.
        let plan = SlotPlacement.place(incoming: ["persistent", "1-1-LT1.save"],
                                       existing: [])
        XCTAssertEqual(plan.map(\.sourceName), ["1-1-LT1.save"])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path swift/VNPlayerCore --filter SlotPlacementTests`
Expected: FAIL — `cannot find 'SaveSlot' in scope`.

(No Mac locally. If you cannot run Swift, push the branch and read the `core-tests` job in the CI run; the same command runs there.)

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// A Ren'Py save slot, and the file name it actually occupies.
///
/// The file name is NOT `<slot>.save`. `renpy/__init__.py:144` sets
/// `savegame_suffix = "-LT1.save"` and `savelocation.py:150` joins `slotname + suffix`,
/// so slot `3-2` is the file `3-2-LT1.save`. A rename that drops the suffix produces a
/// file Ren'Py will not list and will not load.
public struct SaveSlot: Equatable, Hashable {

    public static let suffix = "-LT1.save"

    /// `"3"`, `"auto"`, `"quick"`. Everything before the FINAL dash of the slot name.
    public let page: String
    public let number: Int

    public init(page: String, number: Int) {
        self.page = page
        self.number = number
    }

    /// Parse a file name from a Ren'Py save directory. Returns nil for anything that is
    /// not a save file -- `persistent`, a stray `.txt`, a `.save` without the suffix.
    public init?(fileName: String) {
        guard fileName.hasSuffix(Self.suffix) else { return nil }

        let slotName = String(fileName.dropLast(Self.suffix.count))
        guard !slotName.isEmpty else { return nil }

        // The final dash, not the first. `auto-1` is page "auto", number 1.
        guard let dash = slotName.lastIndex(of: "-") else { return nil }

        let page = String(slotName[slotName.startIndex..<dash])
        let numberText = String(slotName[slotName.index(after: dash)...])

        guard !page.isEmpty, let number = Int(numberText), number > 0 else { return nil }

        self.page = page
        self.number = number
    }

    public var slotName: String { "\(page)-\(number)" }
    public var fileName: String { slotName + Self.suffix }
}

/// One incoming save file and where it will land.
public struct Placement: Equatable {
    /// The file's name at the source, which may repeat across a plan.
    public let sourceName: String
    public let destination: SaveSlot
    /// True when the slot it asked for was taken and it was given another.
    public let movedToNewSlot: Bool

    public init(sourceName: String, destination: SaveSlot, movedToNewSlot: Bool) {
        self.sourceName = sourceName
        self.destination = destination
        self.movedToNewSlot = movedToNewSlot
    }
}

/// Decides where imported saves go, and guarantees nothing is displaced.
///
/// Pure: no file system, no archive, no dates. That is deliberate. This is the rule with
/// the sharpest consequence for being wrong -- getting it wrong costs someone a
/// playthrough -- so it has to be exhaustively testable in milliseconds.
public enum SlotPlacement {

    /// The lowest unused number on `page`. Fills holes rather than appending, so a save
    /// directory does not grow a sparse tail after repeated imports.
    public static func nextFree(page: String, taken: Set<SaveSlot>) -> SaveSlot {
        var number = 1
        while taken.contains(SaveSlot(page: page, number: number)) {
            number += 1
        }
        return SaveSlot(page: page, number: number)
    }

    /// Place every incoming save, never onto an occupied slot.
    ///
    /// `existing` are the file names already in the destination directory. Entries that
    /// do not parse as saves are dropped: only saves belong in a save directory, and
    /// writing a non-save there would be a new kind of mess.
    public static func place(incoming: [String], existing: Set<String>) -> [Placement] {
        var taken = Set(existing.compactMap(SaveSlot.init(fileName:)))
        var result: [Placement] = []

        for name in incoming {
            guard let wanted = SaveSlot(fileName: name) else { continue }

            if !taken.contains(wanted) {
                taken.insert(wanted)
                result.append(Placement(sourceName: name,
                                        destination: wanted,
                                        movedToNewSlot: false))
                continue
            }

            // Occupied. Note that `taken` accumulates as we go, so two incoming files
            // wanting the same slot get two different destinations rather than both
            // being sent to the same one.
            let free = nextFree(page: wanted.page, taken: taken)
            taken.insert(free)
            result.append(Placement(sourceName: name,
                                    destination: free,
                                    movedToNewSlot: true))
        }

        return result
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path swift/VNPlayerCore --filter SlotPlacementTests`
Expected: PASS, 10 tests.

- [ ] **Step 5: Commit**

```bash
git add swift/VNPlayerCore/Sources/VNPlayerCore/SlotPlacement.swift \
        swift/VNPlayerCore/Tests/VNPlayerCoreTests/SlotPlacementTests.swift
git commit -m "core: SaveSlot and SlotPlacement, the never-destroy rule"
```

---

### Task 2: SaveManifest and SaveTransferError

**Files:**
- Create: `swift/VNPlayerCore/Sources/VNPlayerCore/SaveTransfer.swift`
- Test: `swift/VNPlayerCore/Tests/VNPlayerCoreTests/SaveManifestTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public struct SaveManifest: Codable, Equatable` with `static let fileName = "vnplayer-saves.json"`, `static let currentFormat = 1`, fields `format: Int`, `kind: Kind`, `exportedAt: Date`, `appVersion: String`, `games: [Game]`
  - `public enum SaveManifest.Kind: String, Codable { case game, backup }`
  - `public struct SaveManifest.Game: Codable, Equatable` with `gameId: String`, `title: String`, `saveDirectory: String?`, `files: [File]`
  - `public struct SaveManifest.File: Codable, Equatable` with `name: String`, `bytes: Int64`, `sha256: String`
  - `public static func SaveManifest.encode(_:) throws -> Data` and `SaveManifest.decode(_:) throws -> SaveManifest`
  - `public enum SaveTransferError: Error, Equatable` with a `userMessage: String`
  - `public enum SaveDigest { public static func sha256(of data: Data) -> String }`

- [ ] **Step 1: Write the failing tests**

```swift
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
            .noSuchGame("bigbaddogs"), .cannotOpenArchive,
            .writeFailed(name: "1-1-LT1.save"),
        ]
        for error in errors {
            XCTAssertGreaterThan(error.userMessage.split(separator: " ").count, 3,
                                 "\(error) has a code, not a message")
        }
    }

    func testDigestIsStableAndLowercaseHex() {
        let digest = SaveDigest.sha256(of: Data("hello".utf8))
        XCTAssertEqual(
            digest,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path swift/VNPlayerCore --filter SaveManifestTests`
Expected: FAIL — `cannot find 'SaveManifest' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import CryptoKit
import Foundation

/// The manifest that identifies a VNPlayer save export.
///
/// Its presence is what separates "our file" from "a file from somewhere else", which is
/// the distinction the import warning turns on (spec §6). It cannot make a foreign file
/// safe, and nothing here claims to.
public struct SaveManifest: Codable, Equatable {

    public static let fileName = "vnplayer-saves.json"

    /// Incremented on any breaking change to the layout. A reader that meets a higher
    /// number refuses in words rather than guessing at a format it does not know.
    public static let currentFormat = 1

    public enum Kind: String, Codable {
        /// One game; save files live under `saves/`.
        case game
        /// Every game; save files live under `games/<gameId>/`.
        case backup
    }

    public struct File: Codable, Equatable {
        public var name: String
        public var bytes: Int64
        /// Lowercase hex. Proves the file is undamaged. It does NOT prove it is safe.
        public var sha256: String

        public init(name: String, bytes: Int64, sha256: String) {
            self.name = name
            self.bytes = bytes
            self.sha256 = sha256
        }
    }

    public struct Game: Codable, Equatable {
        public var gameId: String
        public var title: String
        /// The game's `config.save_directory`. Null is legitimate and means the game
        /// saves next to itself (renpy/config.py:369, renpy.py:170-171).
        public var saveDirectory: String?
        public var files: [File]

        public init(gameId: String, title: String, saveDirectory: String?, files: [File]) {
            self.gameId = gameId
            self.title = title
            self.saveDirectory = saveDirectory
            self.files = files
        }
    }

    public var format: Int
    public var kind: Kind
    public var exportedAt: Date
    public var appVersion: String
    public var games: [Game]

    public init(format: Int, kind: Kind, exportedAt: Date, appVersion: String, games: [Game]) {
        self.format = format
        self.kind = kind
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.games = games
    }

    // MARK: - Coding

    public static func encode(_ manifest: SaveManifest) throws -> Data {
        let encoder = JSONEncoder()
        // ISO8601 and sorted keys: this file is opened by people on a desktop, and a
        // float timestamp with shuffled keys tells them nothing.
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(manifest)
    }

    public static func decode(_ data: Data) throws -> SaveManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let manifest = try? decoder.decode(SaveManifest.self, from: data) else {
            throw SaveTransferError.notASaveArchive
        }

        guard manifest.format <= currentFormat else {
            throw SaveTransferError.formatTooNew(manifest.format)
        }

        return manifest
    }
}

public enum SaveDigest {
    /// Lowercase hex SHA-256. CryptoKit is available at the iOS 13 floor this package
    /// declares, so no vendored crypto and no dependency.
    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Every way a save transfer can fail, each with a sentence a non-developer can act on.
///
/// Same contract as `ImportError`: a generic "transfer failed" is a defect, not a
/// fallback. The enum is exhaustive in the type so a future `default:` cannot quietly
/// reintroduce one.
public enum SaveTransferError: Error, Equatable {
    case cannotOpenArchive
    case notASaveArchive
    case noSaveFilesFound
    case looksLikeAGameArchive
    case formatTooNew(Int)
    case damagedFile(name: String)
    case noSuchGame(String)
    case writeFailed(name: String)

    public var userMessage: String {
        switch self {
        case .cannotOpenArchive:
            return "That file could not be opened."
        case .notASaveArchive:
            return "That doesn't look like a save file or a saves backup."
        case .noSaveFilesFound:
            return "There are no Ren'Py saves inside that file."
        case .looksLikeAGameArchive:
            return "That looks like a game, not a save file. "
                 + "Use Add game to install it instead."
        case .formatTooNew(let format):
            return "This backup was made by a newer version of VNPlayer "
                 + "(format \(format)). Update the app and try again."
        case .damagedFile(let name):
            return "One of the saves in this file is damaged (\(name)). "
                 + "Try exporting it again."
        case .noSuchGame(let title):
            return "These saves are for \(title), which isn't installed."
        case .writeFailed(let name):
            return "Could not write \(name). The device may be out of space."
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path swift/VNPlayerCore --filter SaveManifestTests`
Expected: PASS, 7 tests.

If `testDatesAreISO8601SoAPersonCanReadTheFile` fails on the year, print the encoded string and correct the expected prefix — `1_800_000_000` is a fixed instant and the assertion should match whatever it actually is, not the other way round.

- [ ] **Step 5: Commit**

```bash
git add swift/VNPlayerCore/Sources/VNPlayerCore/SaveTransfer.swift \
        swift/VNPlayerCore/Tests/VNPlayerCoreTests/SaveManifestTests.swift
git commit -m "core: save-transfer manifest, digest, and error messages"
```

---

### Task 3: DesktopSaveLocations — the WHERE-TO-PUT-THESE.txt text

**Files:**
- Create: `swift/VNPlayerCore/Sources/VNPlayerCore/DesktopSaveLocations.swift`
- Test: `swift/VNPlayerCore/Tests/VNPlayerCoreTests/DesktopSaveLocationsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public enum DesktopSaveLocations { public static func instructions(title: String, saveDirectory: String?) -> String }`

This is the entire PC half of the feature. If this text is wrong, the export is a zip nobody can use.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import VNPlayerCore

final class DesktopSaveLocationsTests: XCTestCase {

    func testNamesAllThreeDesktopPathsWithTheSaveDirectorySubstituted() {
        let text = DesktopSaveLocations.instructions(
            title: "Big Bad Dogs", saveDirectory: "BigBadDogs-1489443940")

        XCTAssertTrue(text.contains("%APPDATA%/RenPy/BigBadDogs-1489443940"), text)
        XCTAssertTrue(text.contains("~/Library/RenPy/BigBadDogs-1489443940"), text)
        XCTAssertTrue(text.contains("~/.renpy/BigBadDogs-1489443940"), text)
    }

    func testNamesTheGame() {
        let text = DesktopSaveLocations.instructions(title: "Big Bad Dogs",
                                                     saveDirectory: "x")
        XCTAssertTrue(text.contains("Big Bad Dogs"), text)
    }

    func testANullSaveDirectoryExplainsTheOtherLayoutInstead() {
        // renpy.py:170-171 -- with no config.save_directory the game saves to
        // <gamedir>/saves. Printing "%APPDATA%/RenPy/null" would be worse than useless.
        let text = DesktopSaveLocations.instructions(title: "Some Game",
                                                     saveDirectory: nil)
        XCTAssertFalse(text.contains("APPDATA"), text)
        XCTAssertFalse(text.lowercased().contains("null"), text)
        XCTAssertTrue(text.contains("saves"), text)
    }

    func testMentionsTheRenPyDataOverride() {
        // renpy.py:176-187 takes precedence over all three platform paths, so someone
        // with a portable install who follows only the platform path is misled.
        let text = DesktopSaveLocations.instructions(title: "G", saveDirectory: "d")
        XCTAssertTrue(text.contains("Ren'Py Data"), text)
    }

    func testIsPlainTextWithNoMarkup() {
        let text = DesktopSaveLocations.instructions(title: "G", saveDirectory: "d")
        XCTAssertFalse(text.contains("<"), "this is opened in Notepad, not a browser")
        XCTAssertFalse(text.contains("**"), "markdown asterisks read as noise in Notepad")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path swift/VNPlayerCore --filter DesktopSaveLocationsTests`
Expected: FAIL — `cannot find 'DesktopSaveLocations' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// The text of `WHERE-TO-PUT-THESE.txt`.
///
/// This file is the whole PC half of save transfer. There is no desktop app, no
/// documentation page and no support channel -- if these sentences are wrong or vague,
/// the export is a zip nobody can do anything with.
///
/// The paths are Ren'Py's own, read from `renpy.py:176-204` of the vendored 8.5.3 SDK
/// rather than remembered.
public enum DesktopSaveLocations {

    public static func instructions(title: String, saveDirectory: String?) -> String {
        guard let saveDirectory, !saveDirectory.isEmpty else {
            return noSaveDirectory(title: title)
        }

        return """
        Saves for \(title), exported from VNPlayer on iPhone.

        The save files are in the folder next to this note. To use them on a
        computer, copy them into the game's save folder:

          Windows   %APPDATA%/RenPy/\(saveDirectory)
          macOS     ~/Library/RenPy/\(saveDirectory)
          Linux     ~/.renpy/\(saveDirectory)

        Close the game first. Existing saves with the same name would be replaced,
        so move them somewhere else first if you want to keep them.

        One exception: if there is a folder called "Ren'Py Data" next to the game
        (or in a folder above it), the game uses that instead, and the saves go in
        "Ren'Py Data/\(saveDirectory)".

        Going the other way works too. Copy save files off a computer, put them in
        a .zip, and open it with Import saves in VNPlayer.
        """
    }

    /// `config.save_directory` is None (renpy/config.py:369). Ren'Py then saves to
    /// `<gamedir>/saves` and there is no per-user location to name at all.
    private static func noSaveDirectory(title: String) -> String {
        """
        Saves for \(title), exported from VNPlayer on iPhone.

        This game does not set a save folder name of its own, which means on a
        computer it keeps its saves right beside the game itself, in a folder
        called "saves" inside the game's own folder.

        To use these on a computer, close the game, then copy the save files from
        the folder next to this note into that "saves" folder. If it isn't there,
        create it.

        Existing saves with the same name would be replaced, so move them somewhere
        else first if you want to keep them.

        Going the other way works too. Copy save files off a computer, put them in
        a .zip, and open it with Import saves in VNPlayer.
        """
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path swift/VNPlayerCore --filter DesktopSaveLocationsTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add swift/VNPlayerCore/Sources/VNPlayerCore/DesktopSaveLocations.swift \
        swift/VNPlayerCore/Tests/VNPlayerCoreTests/DesktopSaveLocationsTests.swift
git commit -m "core: WHERE-TO-PUT-THESE.txt, the PC half of save transfer"
```

---

### Task 4: SaveExporter

**Files:**
- Create: `swift/VNPlayerCore/Sources/VNPlayerCore/SaveExporter.swift`
- Test: `swift/VNPlayerCore/Tests/VNPlayerCoreTests/SaveExporterTests.swift`

**Interfaces:**
- Consumes: `SaveManifest`, `SaveDigest`, `SaveTransferError`, `DesktopSaveLocations`, `SaveSlot`, ZIPFoundation's `Archive`.
- Produces:
  - `public struct SaveExportItem` with `gameId: String`, `title: String`, `saveDirectory: String?`, `directory: URL`
  - `public struct SaveExportSummary: Equatable` with `fileCount: Int`, `totalBytes: Int64`
  - `public enum SaveExporter` with
    `static func summarise(_ items: [SaveExportItem]) -> SaveExportSummary` and
    `static func export(_ items: [SaveExportItem], kind: SaveManifest.Kind, appVersion: String, to destination: URL, now: Date) throws -> SaveExportSummary`

`summarise` exists separately because §4.5's export confirmation needs the counts *before* anything is written.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path swift/VNPlayerCore --filter SaveExporterTests`
Expected: FAIL — `cannot find 'SaveExporter' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path swift/VNPlayerCore --filter SaveExporterTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add swift/VNPlayerCore/Sources/VNPlayerCore/SaveExporter.swift \
        swift/VNPlayerCore/Tests/VNPlayerCoreTests/SaveExporterTests.swift
git commit -m "core: SaveExporter -- save directories to a PC-openable zip"
```

---

### Task 5: SaveImporter — the plan phase

**Files:**
- Create: `swift/VNPlayerCore/Sources/VNPlayerCore/SaveImporter.swift`
- Test: `swift/VNPlayerCore/Tests/VNPlayerCoreTests/SaveImporterPlanTests.swift`

**Interfaces:**
- Consumes: `SaveManifest`, `SaveTransferError`, `SlotPlacement`, `SaveSlot`, `SaveDigest`, `EntryPolicy`, `ImportCaps`, `Archive`.
- Produces:
  - `public struct SaveImportPlan: Equatable` with `gameId: String?`, `title: String?`, `isForeign: Bool`, `placements: [Placement]`, `alreadyPresent: [String]`, `addedCount: Int`, `newSlotCount: Int`
  - `public struct SaveImportPlanSet: Equatable` with `kind: SaveManifest.Kind`, `isForeign: Bool`, `plans: [SaveImportPlan]`, `missingGames: [String]`
  - `public enum SaveImporter` with
    `static func plan(source: URL, resolve: (SaveImportPlan) -> URL?, caps: ImportCaps) throws -> SaveImportPlanSet`

`resolve` maps a planned game to the directory its saves would land in, returning nil when that game is not installed. It is a closure so `SaveImporter` never imports `LibraryStore` and stays testable with no library at all.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path swift/VNPlayerCore --filter SaveImporterPlanTests`
Expected: FAIL — `cannot find 'SaveImporter' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

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

    public init(gameId: String?, title: String?, isForeign: Bool,
                placements: [Placement], alreadyPresent: [String]) {
        self.gameId = gameId
        self.title = title
        self.isForeign = isForeign
        self.placements = placements
        self.alreadyPresent = alreadyPresent
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
                                       placements: [], alreadyPresent: [])
            guard let directory = resolve(draft) else {
                return SaveImportPlanSet(kind: .game, isForeign: true,
                                         plans: [], missingGames: [])
            }
            let data = (try? Data(contentsOf: source)) ?? Data()
            let plan = build(gameId: nil, title: nil, isForeign: true,
                             incoming: [(source.lastPathComponent, SaveDigest.sha256(of: data))],
                             directory: directory)
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
            if entry.uncompressedSize > caps.maxEntryUncompressed {
                throw ImportError.entryTooLarge(entry: name,
                                                bytes: entry.uncompressedSize,
                                                limit: caps.maxEntryUncompressed)
            }

            var data = Data()
            _ = try? archive.extract(entry) { data.append($0) }

            // `games/<id>/x.save` groups by id; anything else is one anonymous group.
            let key = (components.count >= 3 && components[0] == "games")
                ? components[1] : ""

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
            let game = games.first { $0.gameId == key } ?? (games.count == 1 ? games[0] : nil)

            if let manifest, let game {
                try verifyDigests(incoming, against: game, manifest: manifest)
            }

            let draft = SaveImportPlan(gameId: game?.gameId, title: game?.title,
                                       isForeign: manifest == nil,
                                       placements: [], alreadyPresent: [])

            guard let directory = resolve(draft) else {
                missing.append(game?.title ?? game?.gameId ?? "these saves")
                continue
            }

            plans.append(build(gameId: game?.gameId, title: game?.title,
                               isForeign: manifest == nil,
                               incoming: incoming, directory: directory))
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
        against game: SaveManifest.Game,
        manifest: SaveManifest
    ) throws {
        let expected = Dictionary(uniqueKeysWithValues: game.files.map { ($0.name, $0.sha256) })
        for file in incoming {
            if let want = expected[file.name], want != file.digest {
                throw SaveTransferError.damagedFile(name: file.name)
            }
        }
    }

    private static func build(
        gameId: String?,
        title: String?,
        isForeign: Bool,
        incoming: [(name: String, digest: String)],
        directory: URL
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
            alreadyPresent: alreadyPresent)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path swift/VNPlayerCore --filter SaveImporterPlanTests`
Expected: PASS, 11 tests.

- [ ] **Step 5: Commit**

```bash
git add swift/VNPlayerCore/Sources/VNPlayerCore/SaveImporter.swift \
        swift/VNPlayerCore/Tests/VNPlayerCoreTests/SaveImporterPlanTests.swift
git commit -m "core: SaveImporter plan phase -- decides everything, writes nothing"
```

---

### Task 6: SaveImporter — the apply phase

**Files:**
- Modify: `swift/VNPlayerCore/Sources/VNPlayerCore/SaveImporter.swift`
- Test: `swift/VNPlayerCore/Tests/VNPlayerCoreTests/SaveImporterApplyTests.swift`

**Interfaces:**
- Consumes: `SaveImportPlan`, `SaveImportPlanSet` from Task 5.
- Produces:
  - `public struct SaveImportResult: Equatable` with `added: Int`, `movedToNewSlot: Int`, `skipped: Int`, `sentence: String`
  - `public static func SaveImporter.apply(_ plan: SaveImportPlan, source: URL, into directory: URL) throws -> SaveImportResult`

- [ ] **Step 1: Write the failing tests**

```swift
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

    func testTheResultMatchesThePlanExactly() throws {
        try Data("something else".utf8)
            .write(to: destination.appendingPathComponent("1-1-LT1.save"))

        let source = try makeExport(names: ["1-1-LT1.save"])
        let set = try SaveImporter.plan(source: source,
                                        resolve: { _ in self.destination },
                                        caps: .default)
        let result = try SaveImporter.apply(set.plans[0], source: source,
                                            into: destination)

        // A confirmation that describes something other than what happens is worse
        // than no confirmation at all.
        XCTAssertEqual(result.added, set.plans[0].addedCount)
        XCTAssertEqual(result.movedToNewSlot, set.plans[0].newSlotCount)
        XCTAssertEqual(result.skipped, set.plans[0].alreadyPresent.count)
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
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path swift/VNPlayerCore --filter SaveImporterApplyTests`
Expected: FAIL — `type 'SaveImporter' has no member 'apply'`.

- [ ] **Step 3: Write the implementation**

Append to `SaveImporter.swift`:

```swift
public struct SaveImportResult: Equatable {
    public let added: Int
    public let movedToNewSlot: Int
    public let skipped: Int
    /// What to show the reader afterwards, in the same terms the confirmation used.
    public let sentence: String

    public init(added: Int, movedToNewSlot: Int, skipped: Int, sentence: String) {
        self.added = added
        self.movedToNewSlot = movedToNewSlot
        self.skipped = skipped
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
                guard let entry = archive.first(where: {
                    ($0.path as NSString).lastPathComponent == placement.sourceName
                }) else {
                    throw SaveTransferError.damagedFile(name: placement.sourceName)
                }
                var buffer = Data()
                _ = try? archive.extract(entry) { buffer.append($0) }
                data = buffer
            } else {
                data = (try? Data(contentsOf: source)) ?? Data()
            }

            let target = directory.appendingPathComponent(placement.destination.fileName)

            // Belt and braces. SlotPlacement guarantees this path is free; if a bug ever
            // made it otherwise, refusing is the only acceptable behaviour.
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw SaveTransferError.writeFailed(name: placement.destination.fileName)
            }

            do {
                try data.write(to: target, options: .withoutOverwriting)
            } catch {
                throw SaveTransferError.writeFailed(name: placement.destination.fileName)
            }

            if placement.movedToNewSlot { moved += 1 }
        }

        return SaveImportResult(
            added: plan.placements.count,
            movedToNewSlot: moved,
            skipped: plan.alreadyPresent.count,
            sentence: sentence(added: plan.placements.count,
                               moved: moved,
                               skipped: plan.alreadyPresent.count))
    }

    static func sentence(added: Int, moved: Int, skipped: Int) -> String {
        if added == 0 && skipped > 0 {
            return "Those saves are already here. Nothing changed."
        }
        if added == 0 {
            return "There was nothing to add."
        }

        var text = added == 1 ? "1 save added" : "\(added) saves added"
        if moved > 0 { text += ", \(moved) placed in new slots" }
        if skipped > 0 { text += ", \(skipped) already here" }
        return text + "."
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path swift/VNPlayerCore --filter SaveImporter`
Expected: PASS, 18 tests across both importer suites.

- [ ] **Step 5: Commit**

```bash
git add swift/VNPlayerCore/Sources/VNPlayerCore/SaveImporter.swift \
        swift/VNPlayerCore/Tests/VNPlayerCoreTests/SaveImporterApplyTests.swift
git commit -m "core: SaveImporter apply phase -- executes exactly the plan shown"
```

---

### Task 7: `saveDirectory` from the engine to the library entry

**Files:**
- Modify: `shell/vnshell/lifecycle.py` (the `announce_game_ready` emit, around line 222)
- Modify: `swift/VNPlayerCore/Sources/VNPlayerCore/ProtocolMessages.swift`
- Modify: `swift/VNPlayerCore/Sources/VNPlayerCore/Library.swift` (`LibraryEntry`)
- Test: `tests/test_commands.py`, `swift/VNPlayerCore/Tests/VNPlayerCoreTests/ProtocolMessagesTests.swift`

**Interfaces:**
- Consumes: the existing `gameReady` event.
- Produces:
  - Python: `gameReady` gains a `saveDirectory` key, `str` or `None`
  - Swift: `ProtocolMessages.Key.saveDirectory`, and `ProtocolMessages.gameReadySaveDirectory(_ payload: [String: Any]) -> String?`
  - Swift: `LibraryEntry.saveDirectory: String?`, defaulting to nil in `init`

`LibraryEntry` is `Codable` and an existing `library.json` on the device has no such key, so the property **must** be optional and decode as nil rather than throwing. That is the whole risk in this task.

- [ ] **Step 1: Write the failing tests**

In `tests/test_commands.py`, append:

```python
class GameReadySaveDirectoryTests(unittest.TestCase):
    """config.save_directory is the one thing only the running engine knows.

    It cannot be read from the archive at import time -- the game sets it in Python --
    so it rides out on the event that already announces the game is up.
    """

    def setUp(self):
        self._real_renpy = sys.modules.get("renpy")
        self._real_events = lifecycle._EVENTS
        self.events = RecordingEmitter()
        lifecycle._EVENTS = self.events
        lifecycle._announced = False
        self._real_game_id = STATE.current_game_id

    def tearDown(self):
        lifecycle._EVENTS = self._real_events
        lifecycle._announced = True
        STATE.current_game_id = self._real_game_id
        if self._real_renpy is None:
            sys.modules.pop("renpy", None)
        else:
            sys.modules["renpy"] = self._real_renpy

    def test_game_ready_carries_the_save_directory(self):
        module = fake_renpy()
        module.config.save_directory = "BigBadDogs-1489443940"
        sys.modules["renpy"] = module
        STATE.current_game_id = "bigbaddogs"

        lifecycle.announce_game_ready()

        event = self.events.events[0]
        self.assertEqual(event["event"], "gameReady")
        self.assertEqual(event["saveDirectory"], "BigBadDogs-1489443940")

    def test_a_game_with_no_save_directory_reports_none_not_a_string(self):
        # renpy/config.py:369 -- save_directory may be None, and "None" as a string
        # would send WHERE-TO-PUT-THESE.txt to a folder that does not exist.
        module = fake_renpy()
        module.config.save_directory = None
        sys.modules["renpy"] = module
        STATE.current_game_id = "bigbaddogs"

        lifecycle.announce_game_ready()

        self.assertIsNone(self.events.events[0]["saveDirectory"])

    def test_shell_ready_has_no_save_directory_to_report(self):
        sys.modules["renpy"] = fake_renpy()
        STATE.current_game_id = None

        lifecycle.announce_game_ready()

        event = self.events.events[0]
        self.assertEqual(event["event"], "shellReady")
        self.assertIsNone(event["saveDirectory"])
```

Add `from vnshell.state import STATE  # noqa: E402` to the imports at the top of `tests/test_commands.py` if it is not already there.

In `ProtocolMessagesTests.swift`, append:

```swift
    func testGameReadyCarriesTheSaveDirectory() {
        let payload: [String: Any] = [
            "event": "gameReady",
            "gameId": "bigbaddogs",
            "saveDirectory": "BigBadDogs-1489443940",
        ]
        XCTAssertEqual(ProtocolMessages.gameReadySaveDirectory(payload),
                       "BigBadDogs-1489443940")
    }

    func testAMissingOrNullSaveDirectoryReadsAsNil() {
        XCTAssertNil(ProtocolMessages.gameReadySaveDirectory(["event": "gameReady"]))
        XCTAssertNil(ProtocolMessages.gameReadySaveDirectory(
            ["event": "gameReady", "saveDirectory": NSNull()]))
    }

    func testALibraryEntryWrittenBeforeThisFieldExistedStillDecodes() throws {
        // There is a library.json on the device right now with no saveDirectory key.
        // A non-optional property would make the whole library fail to load.
        let json = """
        {"id":"a","title":"A","sizeBytes":1,"addedAt":0,
         "detectedEngine":"renpy8","importedComplete":true,"crashCount":0}
        """
        let entry = try JSONDecoder().decode(LibraryEntry.self, from: Data(json.utf8))
        XCTAssertNil(entry.saveDirectory)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest tests/test_commands.py -q`
Expected: FAIL — `KeyError: 'saveDirectory'`.

Run: `swift test --package-path swift/VNPlayerCore --filter ProtocolMessagesTests`
Expected: FAIL — `type 'ProtocolMessages' has no member 'gameReadySaveDirectory'`.

- [ ] **Step 3: Write the implementation**

In `shell/vnshell/lifecycle.py`, replace the emit inside `announce_game_ready`:

```python
    # config.save_directory is knowable only from the running engine -- the game sets it
    # in its own Python, so it cannot be read out of the archive at import time. It rides
    # out on the event that already says the game is up rather than opening a channel for
    # one string. None is a legitimate value (renpy/config.py:369) and must survive as
    # null rather than as the string "None": the export note uses it to name a folder.
    save_directory = None
    if STATE.current_game_id:
        try:
            import renpy  # type: ignore

            value = renpy.config.save_directory
            save_directory = str(value) if value else None
        except Exception:  # noqa: BLE001 - never let this stop the ready announcement
            save_directory = None

    _EVENTS.emit(
        {
            "event": event,
            "commandId": _pending_command_id,
            "gameId": STATE.current_game_id,
            "saveDirectory": save_directory,
        }
    )
```

In `ProtocolMessages.swift`, add to `Key`:

```swift
        public static let saveDirectory = "saveDirectory"
```

and add, next to `parseEvent`:

```swift
    /// The game's `config.save_directory` from a `gameReady` event.
    ///
    /// Absent, null and empty all read as nil, because all three mean the same thing to
    /// the export note: this game has no save-folder name of its own.
    public static func gameReadySaveDirectory(_ payload: [String: Any]) -> String? {
        guard let value = payload[Key.saveDirectory] as? String, !value.isEmpty else {
            return nil
        }
        return value
    }
```

In `Library.swift`, add the property to `LibraryEntry` after `crashCount`:

```swift
    /// The game's `config.save_directory`, learned from `gameReady` the first time it
    /// runs. Optional and defaulted because a `library.json` written before this field
    /// existed must still decode -- a non-optional here would lose the whole library.
    public var saveDirectory: String?
```

and add `saveDirectory: String? = nil` to the end of `init(...)`'s parameter list with `self.saveDirectory = saveDirectory` in the body.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m pytest tests/ -q` — expected PASS, 79 tests.
Run: `swift test --package-path swift/VNPlayerCore` — expected PASS, all suites.

- [ ] **Step 5: Commit**

```bash
git add shell/vnshell/lifecycle.py tests/test_commands.py \
        swift/VNPlayerCore/Sources/VNPlayerCore/ProtocolMessages.swift \
        swift/VNPlayerCore/Sources/VNPlayerCore/Library.swift \
        swift/VNPlayerCore/Tests/VNPlayerCoreTests/ProtocolMessagesTests.swift
git commit -m "protocol: gameReady reports config.save_directory"
```

---

### Task 8: Export in the app — share sheet, library actions, confirmation

**Files:**
- Create: `spike/Sources/SaveTransferSheets.swift`
- Modify: `spike/Sources/LibraryModel.swift`
- Modify: `spike/Sources/LibraryView.swift`

**Interfaces:**
- Consumes: `SaveExporter.summarise`, `SaveExporter.export`, `SaveExportItem`, `LibraryEntry.saveDirectory`, `VNPlayerPaths.saveDirectory(_:)`.
- Produces:
  - `LibraryModel.confirmExport(_ entry: LibraryEntry?)` — nil means "every game"
  - `LibraryModel.performExport()` — runs the confirmed export and presents the share sheet
  - `LibraryModel.pendingExport: ExportConfirmation?` published
  - `struct ExportConfirmation { let title: String; let message: String; let items: [SaveExportItem]; let kind: SaveManifest.Kind }`
  - `struct ShareSheet: UIViewControllerRepresentable` wrapping `UIActivityViewController`

This task has no headless tests: it is presentation over logic that Tasks 4 and 7 already covered. Do not invent unit tests for SwiftUI here; verify it on the device checklist in Task 10.

- [ ] **Step 1: Add the confirmation model and the export actions**

In `LibraryModel.swift`, inside the class:

```swift
    struct ExportConfirmation: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let items: [SaveExportItem]
        let kind: SaveManifest.Kind
    }

    @Published var pendingExport: ExportConfirmation?
    @Published var shareURL: URL?
```

and in the controls extension:

```swift
    /// Build the confirmation for an export. `entry` nil means every game.
    ///
    /// The numbers come from `summarise`, which writes nothing -- a confirmation that had
    /// to produce the file first would not be a confirmation.
    func confirmExport(_ entry: LibraryEntry?) {
        guard let paths else { return }

        let chosen = entry.map { [$0] } ?? entries
        let items = chosen.map {
            SaveExportItem(gameId: $0.id, title: $0.title,
                           saveDirectory: $0.saveDirectory,
                           directory: paths.saveDirectory($0.id))
        }

        let summary = SaveExporter.summarise(items)

        guard summary.fileCount > 0 else {
            errorMessage = entry == nil
                ? "There are no saves to back up yet."
                : "\(entry!.title) has no saves yet."
            return
        }

        let size = ByteCountFormatter.string(fromByteCount: summary.totalBytes,
                                             countStyle: .file)
        let saves = summary.fileCount == 1 ? "1 save" : "\(summary.fileCount) saves"

        pendingExport = ExportConfirmation(
            title: entry == nil ? "Back up all saves" : "Export saves",
            message: entry == nil
                ? "Back up saves for all \(chosen.count) games? \(saves), \(size)."
                : "Export saves for \(entry!.title)? \(saves), \(size). "
                  + "You'll choose where to put the file next.",
            items: items,
            kind: entry == nil ? .backup : .game)
    }

    func performExport() {
        guard let confirmation = pendingExport, let paths else { return }
        pendingExport = nil

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withDashSeparatorInDate]
        let dated = stamp.string(from: Date())

        let name = confirmation.kind == .backup
            ? "VNPlayer saves \(dated).zip"
            : "\(confirmation.items[0].title) saves \(dated).zip"

        let out = paths.imports.appendingPathComponent(name)

        do {
            _ = try SaveExporter.export(confirmation.items, kind: confirmation.kind,
                                        appVersion: Self.appVersion, to: out,
                                        now: Date())
            shareURL = out
        } catch let error as SaveTransferError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "That export did not work."
        }
    }

    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }
```

- [ ] **Step 2: Add the share sheet wrapper**

Create `spike/Sources/SaveTransferSheets.swift`:

```swift
import SwiftUI
import UIKit

/// `UIActivityViewController` in SwiftUI clothing.
///
/// The export writes a real file into Application Support and hands its URL here.
/// Nothing is copied anywhere the reader can see until she picks a destination, which is
/// why the confirmation says "You'll choose where to put the file next".
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController,
                                context: Context) {}
}
```

- [ ] **Step 3: Wire the UI**

In `LibraryView.swift`, add to the game row's existing `.contextMenu` (around line 232), above the delete buttons:

```swift
                            Button {
                                model.confirmExport(entry)
                            } label: {
                                Label("Export saves", systemImage: "square.and.arrow.up")
                            }
```

In the same file's `header` view, add a second button beside "Add game", inside the same
`if case .idle = model.phase` block:

```swift
                Button {
                    model.confirmExport(nil)          // nil means every game
                } label: {
                    Label("Back up saves", systemImage: "arrow.up.doc.on.clipboard")
                        .font(.system(size: 17, weight: .semibold))
                }
                .buttonStyle(.bordered)
```

Then attach these modifiers to the same view that already carries `.fileImporter`:

```swift
        .alert(item: $model.pendingExport) { confirmation in
            Alert(title: Text(confirmation.title),
                  message: Text(confirmation.message),
                  primaryButton: .default(Text("Export")) { model.performExport() },
                  secondaryButton: .cancel())
        }
        .sheet(isPresented: Binding(
            get: { model.shareURL != nil },
            set: { if !$0 { model.shareURL = nil } })
        ) {
            if let url = model.shareURL { ShareSheet(url: url) }
        }
```

- [ ] **Step 4: Build**

Run: `python -m pytest tests/ -q` (must stay green — this task touches no Python)
Then push the branch and confirm the CI `discover` job builds the `.ipa`. There is no Mac locally; a Swift syntax error surfaces there and nowhere else.

- [ ] **Step 5: Commit**

```bash
git add spike/Sources/SaveTransferSheets.swift spike/Sources/LibraryModel.swift \
        spike/Sources/LibraryView.swift
git commit -m "app: export saves, per game and as a whole-library backup"
```

---

### Task 9: Import in the app — picker, plan preview, and the strip's two new icons

**Files:**
- Modify: `spike/Sources/LibraryModel.swift`
- Modify: `spike/Sources/LibraryView.swift`
- Modify: `spike/Sources/VNPlayerCoordinator.swift`

**Interfaces:**
- Consumes: `SaveImporter.plan`, `SaveImporter.apply`, `SaveImportPlanSet`, `LibraryModel.returnToLibrary()`.
- Produces:
  - `LibraryModel.beginSaveImport()`, `LibraryModel.handlePickedSave(_ result: Result<[URL], Error>)`, `LibraryModel.performSaveImport()`
  - `LibraryModel.pendingSaveImport: ImportConfirmation?` published
  - Strip items `exportSaves` and `importSaves`, replacing `quickSave` and `quickLoad`

Python's `quickSave` and `quickLoad` handlers stay in `lifecycle.py`. Nothing sends them once the icons are gone, but deleting them would also delete the tests that prove `_save_blocked_reason` still mirrors Ren'Py's own `FileSave.get_sensitive()`, which `showMenu` depends on. Unreachable and tested beats deleted and re-derived later.

- [ ] **Step 1: Add the import confirmation**

In `LibraryModel.swift`:

```swift
    struct ImportConfirmation: Identifiable {
        let id = UUID()
        let message: String
        let warning: String?
        let source: URL
        let set: SaveImportPlanSet
        let destinations: [URL]
    }

    @Published var pendingSaveImport: ImportConfirmation?
    @Published var showSaveImporter = false
```

```swift
    func beginSaveImport() {
        guard !showSaveImporter else { return }
        print("[vnspike] save import: opening")
        showSaveImporter = true
    }

    func handlePickedSave(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard let paths else { return }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var destinations: [URL] = []

        do {
            let set = try SaveImporter.plan(source: url, resolve: { plan in
                // §4.2: id first, then an exact single title match, then nothing.
                let match = self.entries.first { $0.id == plan.gameId }
                    ?? self.entries.first { $0.title == plan.title }
                    ?? (plan.gameId == nil && self.entries.count == 1
                        ? self.entries[0] : nil)
                guard let match else { return nil }
                let directory = paths.saveDirectory(match.id)
                destinations.append(directory)
                return directory
            }, caps: .default)

            guard !set.plans.isEmpty else {
                errorMessage = set.missingGames.isEmpty
                    ? "There was nothing to import."
                    : "These saves are for \(set.missingGames.joined(separator: ", ")), "
                      + "which isn't installed."
                return
            }

            pendingSaveImport = ImportConfirmation(
                message: Self.describe(set),
                // Spec §6: one warning, inside this sheet, never a checkmark.
                warning: set.isForeign
                    ? "This file didn't come from VNPlayer. Ren'Py saves can contain "
                      + "code, so only open it if you trust where it came from."
                    : nil,
                source: url,
                set: set,
                destinations: destinations)
        } catch let error as SaveTransferError {
            errorMessage = error.userMessage
        } catch let error as ImportError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "That file could not be read."
        }
    }

    /// Render the plan. This IS the confirmation -- see spec §4.5.
    static func describe(_ set: SaveImportPlanSet) -> String {
        var lines: [String] = []

        for plan in set.plans {
            let into = plan.title.map { " into \($0)" } ?? ""
            let fresh = plan.addedCount - plan.newSlotCount
            var line = "Import \(plan.addedCount) saves\(into)?"
            if fresh > 0 { line += " \(fresh) go into empty slots." }
            if plan.newSlotCount > 0 { line += " \(plan.newSlotCount) into new slots." }
            if !plan.alreadyPresent.isEmpty {
                line += " \(plan.alreadyPresent.count) already here and will be skipped."
            }
            lines.append(line)
        }

        if !set.missingGames.isEmpty {
            lines.append("Not installed, so skipped: "
                         + set.missingGames.joined(separator: ", ") + ".")
        }

        lines.append("Nothing will be replaced.")
        return lines.joined(separator: " ")
    }

    func performSaveImport() {
        guard let confirmation = pendingSaveImport else { return }
        pendingSaveImport = nil

        let scoped = confirmation.source.startAccessingSecurityScopedResource()
        defer { if scoped { confirmation.source.stopAccessingSecurityScopedResource() } }

        var sentences: [String] = []

        do {
            for (index, plan) in confirmation.set.plans.enumerated() {
                let result = try SaveImporter.apply(
                    plan, source: confirmation.source,
                    into: confirmation.destinations[index])
                sentences.append(result.sentence)
            }
            noticeMessage = sentences.joined(separator: " ")
        } catch let error as SaveTransferError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "That import did not finish."
        }
    }
```

- [ ] **Step 2: Wire the picker and the alert**

In `LibraryView.swift`, alongside the existing `.fileImporter`:

```swift
        .fileImporter(
            isPresented: $model.showSaveImporter,
            allowedContentTypes: Self.importableTypes,
            allowsMultipleSelection: false
        ) { result in
            model.handlePickedSave(result)
        }
        .alert(item: $model.pendingSaveImport) { confirmation in
            Alert(title: Text("Import saves"),
                  message: Text([confirmation.message, confirmation.warning]
                                    .compactMap { $0 }.joined(separator: "\n\n")),
                  primaryButton: .default(Text("Import")) { model.performSaveImport() },
                  secondaryButton: .cancel())
        }
```

Add "Import saves" to the game row's context menu, calling `model.beginSaveImport()`.

`Self.importableTypes` already accepts `.zip`, `.archive` and the extension-derived type. Add the `.save` extension to it so a bare Ren'Py save is selectable:

```swift
        if let save = UTType(filenameExtension: "save") {
            types.append(save)
        }
```

- [ ] **Step 3: Replace the strip's bottom pair**

In `VNPlayerCoordinator.swift`, replace the `quickSave` and `quickLoad` items with:

```swift
            // Save FILES, in and out. Quick save and quick load lived here and were read
            // as file export and import; these are the real thing. Import returns to the
            // library first -- writing save files under a live engine is the one version
            // of this that can corrupt something (spec §4.1).
            .init(id: "exportSaves", symbol: "square.and.arrow.up", accessibility: "Export saves",
                  startsGroup: true) { [weak self] in self?.model.confirmExportCurrentGame() },
            .init(id: "importSaves", symbol: "square.and.arrow.down",
                  accessibility: "Import saves") { [weak self] in self?.model.importSavesFromStrip() },
```

and in `LibraryModel.swift`:

```swift
    /// Export the game that is running now.
    ///
    /// `LibraryPhase.playing` already carries the id (`LibraryModel.swift:12`), so there
    /// is no second source of truth to keep in step with it.
    func confirmExportCurrentGame() {
        guard case .playing(let id) = phase,
              let entry = entries.first(where: { $0.id == id })
        else { return }
        confirmExport(entry)
    }

    /// Import from the strip. Returns to the library first, then picks.
    ///
    /// Not caution: Ren'Py caches the slot list and holds the save directory open, so
    /// writing files underneath a live engine leaves the game looking at saves that are
    /// not there.
    func importSavesFromStrip() {
        coordinatorRef?.showControlMessage("Returning to the library to import saves.")
        returnToLibrary()
        beginSaveImport()
    }
```

No new property is needed for "which game is running": `LibraryPhase` is already
`case playing(gameId: String)` (`spike/Sources/LibraryModel.swift:12`). Adding a parallel
`playingGameId` would be a second source of truth that can disagree with the first.

- [ ] **Step 4: Build and verify nothing regressed**

Run: `python -m pytest tests/ -q` — PASS, 79 tests.
Push and confirm all three CI jobs are green and the `.ipa` artifact is produced.

- [ ] **Step 5: Commit**

```bash
git add spike/Sources/LibraryModel.swift spike/Sources/LibraryView.swift \
        spike/Sources/VNPlayerCoordinator.swift
git commit -m "app: import saves with a plan-preview confirmation; strip gains export/import"
```

---

### Task 10: Choosing the game when the file cannot name one

**Files:**
- Modify: `spike/Sources/LibraryModel.swift`
- Modify: `spike/Sources/LibraryView.swift`

**Interfaces:**
- Consumes: `SaveImporter.plan`, `LibraryModel.handlePickedSave`.
- Produces: `LibraryModel.pendingGameChoice: GameChoice?` published, and
  `LibraryModel.chooseGame(_ entry: LibraryEntry)`.

Spec §4.2 case 3: a bare `.save` from a PC, or a manifest whose game is not installed
under that id or title, must let her say which game it belongs to. Task 9 leaves this
reporting "there was nothing to import", which strands exactly the case the feature
exists for. This task closes it, and it is separate because a reviewer could reasonably
accept Task 9 and reject this.

- [ ] **Step 1: Add the choice state**

In `LibraryModel.swift`:

```swift
    struct GameChoice: Identifiable {
        let id = UUID()
        /// Held so the import can be re-planned once she picks.
        let source: URL
        let candidates: [LibraryEntry]
    }

    @Published var pendingGameChoice: GameChoice?
```

- [ ] **Step 2: Ask instead of giving up**

In `handlePickedSave`, replace the `guard !set.plans.isEmpty else { ... }` block with:

```swift
            guard !set.plans.isEmpty else {
                // §4.2 case 3. A bare .save carries no id and no title, and a manifest
                // can name a game installed here under a different id -- ids come from
                // the archive's distribution root, so the same game from a differently
                // named .zip legitimately differs. Refusing outright would strand the
                // case this feature exists for.
                if entries.isEmpty {
                    errorMessage = "Add a game first, then import its saves."
                } else if set.missingGames.isEmpty {
                    pendingGameChoice = GameChoice(source: url, candidates: entries)
                } else {
                    errorMessage = "These saves are for "
                        + "\(set.missingGames.joined(separator: ", ")), "
                        + "which isn't installed."
                }
                return
            }
```

- [ ] **Step 3: Re-plan against the chosen game**

```swift
    /// She picked a game for a save file that could not name one. Plan again, forcing
    /// every save into that game's directory, then show the ordinary §4.5 sheet -- the
    /// confirmation is not skipped just because a question preceded it.
    func chooseGame(_ entry: LibraryEntry) {
        guard let choice = pendingGameChoice, let paths else { return }
        pendingGameChoice = nil

        let url = choice.source
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let directory = paths.saveDirectory(entry.id)

        do {
            let set = try SaveImporter.plan(source: url, resolve: { _ in directory },
                                            caps: .default)
            guard let plan = set.plans.first else {
                errorMessage = "There was nothing to import."
                return
            }

            pendingSaveImport = ImportConfirmation(
                message: "Import \(plan.addedCount) saves into \(entry.title)? "
                    + (plan.newSlotCount > 0
                        ? "\(plan.newSlotCount) go into new slots. " : "")
                    + "Nothing will be replaced.",
                warning: set.isForeign
                    ? "This file didn't come from VNPlayer. Ren'Py saves can contain "
                      + "code, so only open it if you trust where it came from."
                    : nil,
                source: url,
                set: set,
                destinations: [directory])
        } catch let error as SaveTransferError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "That file could not be read."
        }
    }
```

- [ ] **Step 4: Present the chooser**

In `LibraryView.swift`, beside the other modifiers:

```swift
        .confirmationDialog(
            "Which game are these saves for?",
            isPresented: Binding(
                get: { model.pendingGameChoice != nil },
                set: { if !$0 { model.pendingGameChoice = nil } }),
            titleVisibility: .visible
        ) {
            ForEach(model.pendingGameChoice?.candidates ?? []) { entry in
                Button(entry.title) { model.chooseGame(entry) }
            }
            Button("Cancel", role: .cancel) { model.pendingGameChoice = nil }
        }
```

- [ ] **Step 5: Build and commit**

Run: `python -m pytest tests/ -q` — PASS, 79 tests.
Push and confirm all three CI jobs are green.

```bash
git add spike/Sources/LibraryModel.swift spike/Sources/LibraryView.swift
git commit -m "app: ask which game when a save file cannot name its own"
```

---

### Task 11: Device verification and the docs

**Files:**
- Modify: `docs/STATE.md`

There is no automated substitute for these. Every one of them has already caught something in this project that reasoning did not.

- [ ] **Step 1: Run the device checks in this order**

1. Export a game with real saves → AirDrop to a PC → unzip into the folder `WHERE-TO-PUT-THESE.txt` names → the desktop game lists the slots.
2. Zip a desktop save folder by hand → Import saves → the slots appear on the phone, with the foreign-file warning shown once.
3. Back up everything → delete a game → re-add it → restore → its saves are back.
4. Import the same backup twice. The second time reports "already here" and adds nothing.
5. Import from the strip mid-game. It returns to the library, then opens the picker.
6. Export a game that has never been launched. It is refused in words, not with an empty zip.
7. Confirm the numbers in the import sheet match the sentence reported afterwards.
8. Import a bare `.save` while two or more games are installed. It asks which game, then
   shows the ordinary confirmation.

- [ ] **Step 2: Answer the open question from spec §9**

At the next seven-day expiry, re-sign with Sideloadly and check whether `Documents/Saves/` survived. Record the answer in `docs/STATE.md` either way. It decides whether the library should prompt for a backup, and it is not answerable any other way.

- [ ] **Step 3: Update `docs/STATE.md`**

Replace "The build to install" with the new run id and artifact size. Replace "What to check, in order" with whatever from Step 1 is still unverified. Add to "Settled by measurement" anything Step 2 answered.

- [ ] **Step 4: Commit**

```bash
git add docs/STATE.md
git commit -m "docs: STATE.md for M4 save transfer"
```

---

## Notes for the executor

- **`swift build` does not exist on your machine.** CI is the compiler. Push early and read the `core-tests` job rather than guessing at Swift syntax.
- **Heredocs in this repo mangle escapes.** When writing a file with `\(`, `\n` or `\x` in it, use the Write tool or write to the scratchpad and splice — this has cost time repeatedly.
- **`vendor/` is SHA-256 verified.** `scripts/verify_third_party.sh` runs in CI and will fail the build if anything under `vendor/` or `swift/VNPlayerCore/Sources/ZIPFoundation/` changed. If you need a ZIPFoundation behaviour it does not have, wrap it in `VNPlayerCore` — do not edit it.
- **A check that cannot fail is the recurring bug in this project** — four instances so far. After writing a guard, break it on purpose once and confirm it fails.
