import Foundation

/// The Swift half of the command protocol, in the tested target rather than in the app.
///
/// It lives here for one reason: the app target has no tests. When the launch payload was
/// built inline in `LibraryModel`, nothing on either side of the boundary asserted its
/// shape — Swift wrote `{"command": "launch", ...}`, `vnshell.mailbox` read
/// `entry["name"]` and `entry["args"]`, both suites passed, and the phone showed a launch
/// button that did nothing until it timed out sixty seconds later. The command was being
/// consumed and discarded in silence.
///
/// `tests/protocol/*.json` are the shared fixtures. Python asserts it *accepts* them;
/// `ProtocolMessagesTests` asserts these builders *produce* that shape. Changing one side
/// without the other now fails a test rather than a device.
public enum ProtocolMessages {

    /// Keys, named once. A typo in a string literal is exactly how the original bug
    /// happened, and a typo here breaks the test instead of the app.
    public enum Key {
        public static let name = "name"
        public static let args = "args"
        public static let commandId = "commandId"
        public static let gameId = "gameId"
        public static let basedir = "basedir"
        public static let screen = "screen"
        public static let event = "event"
        public static let reason = "reason"
        public static let saveDirectory = "saveDirectory"
    }

    public enum CommandName {
        public static let launch = "launch"
        public static let quitToLibrary = "quitToLibrary"
        public static let quickSave = "quickSave"
        public static let quickLoad = "quickLoad"
        public static let rollback = "rollback"
        public static let toggleSkip = "toggleSkip"
        public static let showMenu = "showMenu"
    }

    /// The game's own menu pages, by the names Ren'Py knows them under. Python validates
    /// this same set; the fixture in tests/protocol keeps the two honest.
    public enum MenuScreen: String, CaseIterable {
        case save
        case load
        case preferences
    }

    public enum EventName {
        public static let launchAccepted = "launchAccepted"
        public static let gameReady = "gameReady"
        public static let shellReady = "shellReady"
        public static let launchFailed = "launchFailed"
        public static let commandDone = "commandDone"
        public static let commandFailed = "commandFailed"
        public static let engineState = "engineState"
    }

    /// What the engine will currently accept, so the overlay can grey out controls
    /// instead of offering them and then reporting a refusal.
    public struct EngineState: Equatable {
        public var canRollback = false
        public var canSave = false
        public var isSkipping = false
        public var inGame = false
        /// True while the game's own menu -- or its main menu -- is up.
        public var inMenu = false

        public init() {}

        public init?(payload: [String: Any]) {
            guard payload[Key.event] as? String == EventName.engineState else { return nil }
            canRollback = payload["canRollback"] as? Bool ?? false
            canSave = payload["canSave"] as? Bool ?? false
            isSkipping = payload["isSkipping"] as? Bool ?? false
            inGame = payload["inGame"] as? Bool ?? false
            inMenu = payload["inMenu"] as? Bool ?? false
        }
    }

    /// Every control command has the same shape, so build them the same way. A per-control
    /// literal is how the launch payload drifted from what Python read.
    public static func control(_ name: String, commandId: String) -> [String: Any] {
        [
            Key.name: name,
            Key.args: [Key.commandId: commandId],
        ]
    }

    public static func launch(commandId: String, gameId: String, basedir: String) -> [String: Any] {
        [
            Key.name: CommandName.launch,
            Key.args: [
                Key.commandId: commandId,
                Key.gameId: gameId,
                Key.basedir: basedir,
            ],
        ]
    }

    /// Open one of the game's own menu pages.
    ///
    /// Takes the enum rather than a String on purpose: the page name is the one argument
    /// in this protocol that Python validates against a fixed set, so an unrepresentable
    /// value should not be constructible on this side either.
    public static func showMenu(commandId: String, screen: MenuScreen) -> [String: Any] {
        [
            Key.name: CommandName.showMenu,
            Key.args: [
                Key.commandId: commandId,
                Key.screen: screen.rawValue,
            ],
        ]
    }

    public static func quitToLibrary(commandId: String) -> [String: Any] {
        [
            Key.name: CommandName.quitToLibrary,
            Key.args: [Key.commandId: commandId],
        ]
    }

    /// Reads an event's name and the commandId it answers.
    ///
    /// Events are flat -- Python's emitter writes `{"event": ..., "commandId": ...}` --
    /// while commands are nested. That asymmetry is real and worth stating rather than
    /// tidying away: commands go through `vnshell.mailbox`, which has had a name/args
    /// contract since Milestone A, and events do not go through it at all.
    public static func parseEvent(_ payload: [String: Any]) -> (name: String, commandId: String?)? {
        guard let name = payload[Key.event] as? String else { return nil }
        return (name, payload[Key.commandId] as? String)
    }

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
}
