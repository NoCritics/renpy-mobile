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

    func testAPageNameContainingADashStillSplitsOnTheFinalDash() {
        // The discriminating case. Every other fixture in this file has exactly one dash
        // after the suffix is stripped, so firstIndex and lastIndex agree on all of them
        // and neither would fail if the rule were inverted. This one diverges:
        //   lastIndex  -> page "extra-1", number 2   (correct)
        //   firstIndex -> page "extra", number "1-2" -> Int(...) fails -> nil
        let slot = SaveSlot(fileName: "extra-1-2-LT1.save")
        XCTAssertNotNil(slot, "splitting on the FIRST dash makes this unparseable")
        XCTAssertEqual(slot?.page, "extra-1")
        XCTAssertEqual(slot?.number, 2)
    }

    func testRejectsAnythingThatIsNotASaveFile() {
        XCTAssertNil(SaveSlot(fileName: "3-2.save"))          // wrong suffix
        XCTAssertNil(SaveSlot(fileName: "persistent"))
        XCTAssertNil(SaveSlot(fileName: "-LT1.save"))         // no slot name
        XCTAssertNil(SaveSlot(fileName: "nodash-LT1.save"))   // no dash, so no page/number split
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
