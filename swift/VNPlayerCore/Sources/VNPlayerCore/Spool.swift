import Foundation

/// One message each way between Swift and Python.
///
/// A directory of one-message files, not an append-only log. The append-only version is
/// what the spike proved and what M1 shipped, and it has a data-loss race that both
/// consultation reviewers found independently: `FileTransport.receive()` reads the whole
/// file and then deletes it, so anything written between the read and the delete is
/// destroyed unread. A partially-written line is also lost permanently, because the JSON
/// parse fails and the reader moves on.
///
/// It never bit us because the spike wrote one command per tap, by hand. Under a launch
/// flow with events going both ways it would.
///
/// Here, the writer writes `<name>.json.tmp` and renames it to `<name>.json`. Rename
/// within a directory is atomic, so a reader sees a file either not at all or complete.
/// The reader deletes each file after reading it. There is no window in which a message
/// can be lost and no partial state to parse.
public struct SpoolMessage: Equatable {
    public let name: String
    public let payload: [String: Any]

    public init(name: String, payload: [String: Any]) {
        self.name = name
        self.payload = payload
    }

    public static func == (lhs: SpoolMessage, rhs: SpoolMessage) -> Bool {
        lhs.name == rhs.name
            && NSDictionary(dictionary: lhs.payload).isEqual(to: rhs.payload)
    }
}

public final class Spool {

    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Monotonic so that filename order is send order. A UUID alone would sort randomly,
    /// and a launch answered out of order is worse than one answered late.
    private static var counter: UInt64 = 0
    private static let counterLock = NSLock()

    private static func nextName() -> String {
        counterLock.lock()
        defer { counterLock.unlock() }
        counter += 1
        // Milliseconds since epoch, then a per-process counter to break ties inside the
        // same millisecond, then a UUID fragment so two processes cannot collide.
        let millis = UInt64(Date().timeIntervalSince1970 * 1000)
        let unique = UUID().uuidString.prefix(8)
        return String(format: "%013llu-%06llu-%@", millis, counter, String(unique))
    }

    @discardableResult
    public func write(_ payload: [String: Any]) throws -> String {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let name = Self.nextName()
        let final = directory.appendingPathComponent("\(name).json")
        let temporary = directory.appendingPathComponent("\(name).json.tmp")

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: temporary)

        // The atomic step. Everything above this line is invisible to the reader,
        // because the reader only ever looks at *.json.
        try fileManager.moveItem(at: temporary, to: final)

        return name
    }

    /// Reads and consumes every complete message, oldest first.
    public func drain() -> [SpoolMessage] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else {
            return []
        }

        let messages = contents
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var result: [SpoolMessage] = []

        for url in messages {
            defer { try? fileManager.removeItem(at: url) }

            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let payload = object as? [String: Any]
            else {
                // Unreadable or not an object. Deleted by the defer above rather than
                // left to be retried forever: a message that cannot be parsed once will
                // not parse later either, and leaving it would block nothing but would
                // grow without bound.
                continue
            }

            result.append(SpoolMessage(
                name: url.deletingPathExtension().lastPathComponent,
                payload: payload
            ))
        }

        return result
    }

    /// Removes everything without reading it. Used at startup: commands written before
    /// the app was last killed are stale by definition, and replaying them would relaunch
    /// a game the user did not ask for -- possibly the one that killed the app.
    public func clear() {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: []) else { return }
        for url in contents {
            try? fileManager.removeItem(at: url)
        }
    }
}
