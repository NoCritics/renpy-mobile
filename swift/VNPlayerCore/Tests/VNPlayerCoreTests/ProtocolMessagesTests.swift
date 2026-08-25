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
