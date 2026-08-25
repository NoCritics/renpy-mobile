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
