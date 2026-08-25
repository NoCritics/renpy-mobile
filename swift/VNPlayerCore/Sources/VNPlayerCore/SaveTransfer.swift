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

        // The format number is read BEFORE the manifest it describes, and the ordering is
        // the whole point. Decoding first would mean a future format that actually changed
        // the layout -- the only kind of change this number is incremented for -- fails to
        // decode and gets reported as "that isn't a save file", when the true answer is
        // "update the app". `format` is the one field every future version must still
        // carry, so it is safe to read from a minimal shape.
        struct FormatProbe: Decodable { let format: Int }

        if let probe = try? decoder.decode(FormatProbe.self, from: data),
           probe.format > currentFormat {
            throw SaveTransferError.formatTooNew(probe.format)
        }

        guard let manifest = try? decoder.decode(SaveManifest.self, from: data) else {
            throw SaveTransferError.notASaveArchive
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
