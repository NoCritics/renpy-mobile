import Foundation

/// The display title and stable id derived from an archive, before Ren'Py has ever run.
///
/// Deriving this natively is not a convenience. Ren'Py knows a game's name from
/// `config.name`, which is only readable by booting the engine into that game -- and we
/// need the id *first*, to decide where to put the files and which save directory the
/// game will be handed. So the archive's own naming is all we have to work from.
public struct GameIdentity: Equatable {
    /// Shown to the user. Preserves case and spacing.
    public let title: String
    /// Filesystem-safe, stable, and the key that binds a game to its saves.
    public let id: String

    public init(title: String, id: String) {
        self.title = title
        self.id = id
    }
}

public enum GameIdentityDeriver {

    /// Suffixes Ren'Py's own distribution builder appends. Order matters only in that
    /// each is tried against the end of the name; a name may carry several
    /// ("Game-1.2-pc"), so stripping repeats until nothing more comes off.
    private static let platformSuffixes = ["-pc", "-mac", "-macos", "-linux", "-market", "-all", "-win", "-steam"]

    /// Derive from the archive's single top-level directory name, falling back to the
    /// archive's own filename when the archive has no single root.
    ///
    /// - Parameters:
    ///   - topLevelDirectory: the sole top-level directory inside the archive, if there
    ///     is exactly one. `nil` when there are none or several.
    ///   - archiveFileName: the archive's filename, with or without extension.
    public static func derive(topLevelDirectory: String?, archiveFileName: String) -> GameIdentity {
        let raw = topLevelDirectory ?? stripArchiveExtension(archiveFileName)
        let title = stripDistributionSuffixes(raw)
        return GameIdentity(title: title, id: slug(title))
    }

    /// Strips `.zip`, and also the `.tar` in `.tar.gz`-style names, so a double
    /// extension does not leave a stray `.tar` in the title.
    static func stripArchiveExtension(_ name: String) -> String {
        var result = name
        for ext in [".zip", ".gz", ".bz2", ".xz", ".7z", ".rar", ".tar"] {
            if result.lowercased().hasSuffix(ext) {
                result = String(result.dropLast(ext.count))
            }
        }
        return result
    }

    /// Removes trailing platform markers and version numbers, repeatedly, because real
    /// distribution names stack them: "MyGame-1.2.3-pc".
    static func stripDistributionSuffixes(_ name: String) -> String {
        var result = name
        var changed = true

        while changed {
            changed = false

            for suffix in platformSuffixes where result.lowercased().hasSuffix(suffix) {
                result = String(result.dropLast(suffix.count))
                changed = true
                break
            }
            if changed { continue }

            if let stripped = strippingTrailingVersion(result) {
                result = stripped
                changed = true
            }
        }

        return result.trimmingCharacters(in: CharacterSet(charactersIn: " -_."))
    }

    /// Removes a trailing `-1`, `-1.2`, `-1.2.3`, `-v1.2` and similar.
    ///
    /// Deliberately requires the separator: a game genuinely called "Portal 2" must not
    /// become "Portal", so a version is only recognised after a hyphen or underscore.
    private static func strippingTrailingVersion(_ name: String) -> String? {
        guard let separatorIndex = name.lastIndex(where: { $0 == "-" || $0 == "_" }) else {
            return nil
        }

        var tail = String(name[name.index(after: separatorIndex)...])
        if tail.lowercased().hasPrefix("v") { tail = String(tail.dropFirst()) }

        guard !tail.isEmpty else { return nil }

        // Every component between dots must be numeric, and there must be at least one.
        let components = tail.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return nil }
        for component in components {
            guard !component.isEmpty, component.allSatisfy({ $0.isNumber }) else {
                return nil
            }
        }

        return String(name[name.startIndex..<separatorIndex])
    }

    /// Lowercase, non-alphanumerics collapsed to single hyphens, trimmed.
    ///
    /// Unicode letters and digits are kept, not stripped: a Japanese title should slug
    /// to something recognisable rather than to nothing at all. `isLetter`/`isNumber`
    /// are Unicode-aware, so this holds for any script.
    static func slug(_ title: String) -> String {
        var out = ""
        var lastWasHyphen = false

        for character in title.lowercased() {
            if character.isLetter || character.isNumber {
                out.append(character)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                out.append("-")
                lastWasHyphen = true
            }
        }

        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Resolves a collision against ids already in use by appending -2, -3, ...
    ///
    /// An empty slug also lands here, because "" is not a usable directory name; it
    /// becomes "game", then "game-2" and so on.
    public static func uniqueId(_ preferred: String, taken: Set<String>) -> String {
        let base = preferred.isEmpty ? "game" : preferred

        if !taken.contains(base) { return base }

        var counter = 2
        while taken.contains("\(base)-\(counter)") {
            counter += 1
        }
        return "\(base)-\(counter)"
    }
}
