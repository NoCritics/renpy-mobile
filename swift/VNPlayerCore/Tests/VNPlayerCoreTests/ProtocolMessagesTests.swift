import XCTest
@testable import VNPlayerCore

/// Asserts the Swift side PRODUCES the shape `vnshell.mailbox` accepts.
///
/// `tests/test_protocol.py` is the other half, asserting Python accepts it, and both read
/// from the same idea of the format. Neither existed when the two sides disagreed, which
/// is how a launch button that did nothing shipped to a device.
final class ProtocolMessagesTests: XCTestCase {

    func testLaunchUsesNameAndArgsNotAFlatCommandKey() throws {
        let message = ProtocolMessages.launch(
            commandId: "abc", gameId: "bigbaddogs", basedir: "/Documents/Games/bigbaddogs")

        // The exact mistake that cost a device round-trip.
        XCTAssertNil(message["command"],
                     "a flat 'command' key is the shape vnshell.mailbox silently drops")

        XCTAssertEqual(message["name"] as? String, "launch")

        let args = try XCTUnwrap(message["args"] as? [String: Any])
        XCTAssertEqual(args["commandId"] as? String, "abc")
        XCTAssertEqual(args["gameId"] as? String, "bigbaddogs")
        XCTAssertEqual(args["basedir"] as? String, "/Documents/Games/bigbaddogs")
    }

    func testQuitToLibraryShape() throws {
        let message = ProtocolMessages.quitToLibrary(commandId: "xyz")

        XCTAssertNil(message["command"])
        XCTAssertEqual(message["name"] as? String, "quitToLibrary")
        let args = try XCTUnwrap(message["args"] as? [String: Any])
        XCTAssertEqual(args["commandId"] as? String, "xyz")
    }

    func testLaunchSurvivesJSONSerialisation() throws {
        // Spool writes with JSONSerialization, so anything unrepresentable would throw
        // at run time on the device rather than here.
        let message = ProtocolMessages.launch(
            commandId: "abc", gameId: "月に寄りそう", basedir: "/Documents/Games/tsukiyori")

        let data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        let round = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(round["name"] as? String, "launch")
        let args = try XCTUnwrap(round["args"] as? [String: Any])
        XCTAssertEqual(args["gameId"] as? String, "月に寄りそう")
    }

    func testEveryControlCommandUsesTheNameArgsShape() throws {
        // All four M3 controls, checked the same way the launch command is. The shape is
        // the thing that drifted before, and it drifted silently.
        for name in [ProtocolMessages.CommandName.quickSave,
                     ProtocolMessages.CommandName.quickLoad,
                     ProtocolMessages.CommandName.rollback,
                     ProtocolMessages.CommandName.toggleSkip] {
            let message = ProtocolMessages.control(name, commandId: "abc")

            XCTAssertNil(message["command"], "\(name) used a flat command key")
            XCTAssertEqual(message["name"] as? String, name)

            let args = try XCTUnwrap(message["args"] as? [String: Any], name)
            XCTAssertEqual(args["commandId"] as? String, "abc", name)

            // And it must survive the serialiser Spool actually uses.
            let data = try JSONSerialization.data(withJSONObject: message)
            XCTAssertGreaterThan(data.count, 0)
        }
    }

    func testControlNamesMatchTheHandlersPythonRegisters() {
        // These four strings are keys in vnshell.lifecycle._HANDLERS. If either side is
        // renamed alone, the command is accepted by the spool and then reported as
        // "this build does not understand" -- which is at least visible now, but should
        // not happen.
        XCTAssertEqual(ProtocolMessages.CommandName.quickSave, "quickSave")
        XCTAssertEqual(ProtocolMessages.CommandName.quickLoad, "quickLoad")
        XCTAssertEqual(ProtocolMessages.CommandName.rollback, "rollback")
        XCTAssertEqual(ProtocolMessages.CommandName.toggleSkip, "toggleSkip")
        XCTAssertEqual(ProtocolMessages.CommandName.quitToLibrary, "quitToLibrary")
        XCTAssertEqual(ProtocolMessages.CommandName.showMenu, "showMenu")
    }

    func testShowMenuShape() throws {
        let message = ProtocolMessages.showMenu(commandId: "m1", screen: .preferences)

        XCTAssertNil(message["command"])
        XCTAssertEqual(message["name"] as? String, "showMenu")

        let args = try XCTUnwrap(message["args"] as? [String: Any])
        XCTAssertEqual(args["commandId"] as? String, "m1")
        XCTAssertEqual(args["screen"] as? String, "preferences")
    }

    func testShowMenuScreenNamesMatchWhatPythonAccepts() {
        // lifecycle.MENU_SCREENS is the other end of this. The names are Ren'Py's own
        // screen names, so neither side is free to rename them.
        XCTAssertEqual(
            ProtocolMessages.MenuScreen.allCases.map(\.rawValue),
            ["save", "load", "preferences"])
    }

    func testShowMenuSurvivesJSONSerialisation() throws {
        for screen in ProtocolMessages.MenuScreen.allCases {
            let data = try JSONSerialization.data(
                withJSONObject: ProtocolMessages.showMenu(commandId: "m", screen: screen))
            let round = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any])
            let args = try XCTUnwrap(round["args"] as? [String: Any])
            XCTAssertEqual(args["screen"] as? String, screen.rawValue)
        }
    }

    func testEngineStateParsesFromItsEvent() throws {
        let state = try XCTUnwrap(ProtocolMessages.EngineState(payload: [
            "event": "engineState",
            "canRollback": true,
            "canSave": false,
            "isSkipping": true,
            "inGame": true,
            "inMenu": true,
        ]))

        XCTAssertTrue(state.canRollback)
        XCTAssertFalse(state.canSave)
        XCTAssertTrue(state.isSkipping)
        XCTAssertTrue(state.inGame)
        XCTAssertTrue(state.inMenu)
    }

    func testEngineStateRejectsOtherEvents() {
        XCTAssertNil(ProtocolMessages.EngineState(payload: ["event": "gameReady"]))
        XCTAssertNil(ProtocolMessages.EngineState(payload: [:]))
    }

    func testEngineStateDefaultsToEverythingDisabled() throws {
        // A malformed or partial state must not enable controls. Greying out a control
        // that would have worked is a small annoyance; offering one that cannot work is
        // the failure this event exists to prevent.
        let state = try XCTUnwrap(
            ProtocolMessages.EngineState(payload: ["event": "engineState"]))
        XCTAssertFalse(state.canRollback)
        XCTAssertFalse(state.canSave)
        XCTAssertFalse(state.isSkipping)
        XCTAssertFalse(state.inGame)
        XCTAssertFalse(state.inMenu)
    }

    func testEventParsing() {
        let parsed = ProtocolMessages.parseEvent(["event": "gameReady", "commandId": "abc"])
        XCTAssertEqual(parsed?.name, "gameReady")
        XCTAssertEqual(parsed?.commandId, "abc")
    }

    func testEventParsingRejectsNonEvents() {
        XCTAssertNil(ProtocolMessages.parseEvent(["name": "launch"]))
        XCTAssertNil(ProtocolMessages.parseEvent([:]))
    }

    func testEventWithoutCommandIdStillParses() {
        // shellReady carries no commandId when it is not answering a launch.
        let parsed = ProtocolMessages.parseEvent(["event": "shellReady"])
        XCTAssertEqual(parsed?.name, "shellReady")
        XCTAssertNil(parsed?.commandId)
    }

    /// A round trip through Spool, because that is the path the real message takes.
    func testLaunchRoundTripsThroughTheSpool() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("protocol-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let spool = Spool(directory: directory)
        try spool.write(ProtocolMessages.launch(
            commandId: "abc", gameId: "g", basedir: "/b"))

        let drained = spool.drain()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained.first?.payload["name"] as? String, "launch")
        XCTAssertNotNil(drained.first?.payload["args"] as? [String: Any])
    }
}
