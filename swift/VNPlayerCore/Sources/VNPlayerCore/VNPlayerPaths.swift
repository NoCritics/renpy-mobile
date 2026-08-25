import Foundation

/// The on-disk layout, in one place.
///
/// The split between what the Files app can see and what it cannot is the whole point of
/// this type, so it is worth stating plainly:
///
///   Documents/                     EXPOSED  (UIFileSharingEnabled)
///     Games/<gameId>/              the basedir handed to Ren'Py
///     Saves/<gameId>/              path_to_saves target, outside the game tree
///
///   Library/Application Support/VNPlayer/    HIDDEN
///     library.json                 the index
///     Commands/                    Swift -> Python spool
///     Events/                      Python -> Swift spool
///     Imports/<uuid>/              extraction staging
///     Trash/<uuid>/                deferred deletion
///
/// Saves are exposed so they can be backed up and so a fan-translation patch can be
/// dropped in by hand. The index and the spools are hidden because they are the app's
/// control plane: a user who deletes `library.json` in the Files app should not be able
/// to, and one who deletes a command file mid-launch definitely should not.
///
/// An earlier draft of the M2 spec had all of it under `Documents/`. Both consultation
/// reviewers objected independently, and they were right.
public struct VNPlayerPaths {

    public let documents: URL
    public let applicationSupport: URL

    public init(documents: URL, applicationSupport: URL) {
        self.documents = documents
        self.applicationSupport = applicationSupport
    }

    /// The real containers on a device. Injectable above so tests never touch them.
    public static func standard() throws -> VNPlayerPaths {
        let fm = FileManager.default

        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw VNPlayerPathsError.noDocumentsDirectory
        }
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw VNPlayerPathsError.noApplicationSupportDirectory
        }

        return VNPlayerPaths(
            documents: documents,
            applicationSupport: support.appendingPathComponent("VNPlayer", isDirectory: true)
        )
    }

    // MARK: - Exposed

    public var games: URL { documents.appendingPathComponent("Games", isDirectory: true) }
    public var saves: URL { documents.appendingPathComponent("Saves", isDirectory: true) }

    public func gameDirectory(_ gameId: String) -> URL {
        games.appendingPathComponent(gameId, isDirectory: true)
    }

    public func saveDirectory(_ gameId: String) -> URL {
        saves.appendingPathComponent(gameId, isDirectory: true)
    }

    // MARK: - Hidden

    public var libraryIndex: URL { applicationSupport.appendingPathComponent("library.json") }
    public var commands: URL { applicationSupport.appendingPathComponent("Commands", isDirectory: true) }
    public var events: URL { applicationSupport.appendingPathComponent("Events", isDirectory: true) }
    public var imports: URL { applicationSupport.appendingPathComponent("Imports", isDirectory: true) }
    public var trash: URL { applicationSupport.appendingPathComponent("Trash", isDirectory: true) }

    /// Names the game whose launch is in flight. Its presence at startup means that
    /// launch killed the process -- see the M2 spec §10.5. Nothing else writes here.
    public var launchSentinel: URL { applicationSupport.appendingPathComponent("launching.txt") }

    /// Every directory the app expects to exist. Created once at startup; creating them
    /// lazily at each use invites a half-built layout after a mid-write kill.
    public var allDirectories: [URL] {
        [games, saves, applicationSupport, commands, events, imports, trash]
    }

    public func createDirectories() throws {
        for url in allDirectories {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

public enum VNPlayerPathsError: Error, Equatable {
    case noDocumentsDirectory
    case noApplicationSupportDirectory
}
