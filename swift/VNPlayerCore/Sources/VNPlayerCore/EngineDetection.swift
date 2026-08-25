import Foundation

/// Which Ren'Py generation a distribution was built with, as far as its file layout can
/// tell us.
public enum DetectedEngine: String, Codable, Equatable {
    case renpy7
    case renpy8
    /// The archive carries no signal either way. This is NOT a failure -- see below.
    case unknown
}

/// Detects the engine from names and small text files, never from bytecode.
///
/// **The M2 spec was wrong about how to do this, and the parent spec before it.** Both
/// said to read `.rpyc` magic, "v1 is Ren'Py 7, v2 is Ren'Py 8". That is not what the
/// magic means: `renpy/script.py:58` defines `RPYC2_HEADER = b"RENPY RPC2"` and BOTH
/// Ren'Py 7 and Ren'Py 8 write it. The v1/v2 distinction is the rpyc container format,
/// which last changed long before Ren'Py 7. Reading it would have classified every game
/// as Ren'Py 8 and silently let Ren'Py 7 games through to fail as a black screen -- the
/// exact outcome the check exists to prevent.
///
/// The signals below are real, in order of confidence:
///
/// 1. `renpy/vc_version.py` contains `version = '8.5.3.26051504'`. Definitive when the
///    distribution ships the engine, which full PC releases do.
/// 2. `lib/py3-*` (Ren'Py 8) versus `lib/py2-*` or `lib/*-i686` (Ren'Py 7). Also from
///    the shipped runtime, and present in every full PC release.
/// 3. Nothing. A `game/`-only archive carries no engine marker at all.
///
/// Case 3 is common and must not block the import: refusing everything we cannot
/// classify would reject a large share of perfectly good Ren'Py 8 games. An unknown
/// engine imports, and if it turns out to be Ren'Py 7 it fails at launch with an error
/// surfaced by §10's `launchFailed` — worse than catching it here, better than refusing
/// a game that would have worked.
public enum EngineDetector {

    /// - Parameters:
    ///   - relativePaths: every path in the distribution, relative to its root.
    ///   - vcVersionContents: the text of `renpy/vc_version.py`, if the archive has one.
    public static func detect(relativePaths: [String], vcVersionContents: String?) -> DetectedEngine {
        if let text = vcVersionContents, let major = majorVersion(fromVCVersion: text) {
            switch major {
            case 7: return .renpy7
            case 8...: return .renpy8
            // 6 and below are far past anything this app targets; treat as Ren'Py 7 so
            // the user gets the "not supported yet" message rather than a black screen.
            default: return .renpy7
            }
        }

        for path in relativePaths {
            let components = path.split(separator: "/").map(String.init)
            guard components.count >= 2, components[0].lowercased() == "lib" else { continue }

            let runtime = components[1].lowercased()
            if runtime.hasPrefix("py3-") { return .renpy8 }
            if runtime.hasPrefix("py2-") || runtime.hasSuffix("-i686") { return .renpy7 }
        }

        return .unknown
    }

    /// Pulls the major version out of `version = '8.5.3.26051504'`.
    ///
    /// Hand-scanned rather than regex-matched so the failure mode is "returns nil"
    /// rather than "throws on a malformed file we did not anticipate".
    static func majorVersion(fromVCVersion text: String) -> Int? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("version") else { continue }

            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let rhs = trimmed[trimmed.index(after: equals)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t'\"" ))

            let firstComponent = rhs.prefix(while: { $0.isNumber })
            if !firstComponent.isEmpty, let value = Int(firstComponent) {
                return value
            }
        }
        return nil
    }

    /// The distribution root is the directory containing `game/`.
    ///
    /// Returns the path prefix of that directory ("" when `game/` is at the archive
    /// root), or nil when there is no `game/` anywhere -- which is what makes an archive
    /// "not a Ren'Py game".
    ///
    /// Picks the SHALLOWEST `game/`. A game that ships an example or a mod containing its
    /// own nested `game/` would otherwise be rooted at the wrong place.
    ///
    /// **Case-sensitive first, and that is not fussiness.** A very common distribution
    /// layout is a wrapper folder literally named `Game/` containing the real `game/`:
    ///
    ///     Game/game/script.rpy
    ///
    /// A case-insensitive shallowest-match calls the wrapper the game directory, decides
    /// the distribution root is "", and then extracts everything one level too deep --
    /// producing `Game/game/...` on disk, which Ren'Py cannot load. Ren'Py itself always
    /// writes the directory lowercase, so a case-sensitive pass finds the right one; the
    /// insensitive pass remains as a fallback for archives repacked on a case-folding
    /// filesystem, where the real directory may have been renamed.
    public static func distributionRoot(relativePaths: [String]) -> String? {
        if let exact = shallowestRoot(relativePaths, caseSensitive: true) { return exact }
        return shallowestRoot(relativePaths, caseSensitive: false)
    }

    private static func shallowestRoot(_ relativePaths: [String], caseSensitive: Bool) -> String? {
        var best: String?
        var bestDepth = Int.max

        for path in relativePaths {
            let components = path.split(separator: "/").map(String.init)
            let index = components.firstIndex {
                caseSensitive ? $0 == "game" : $0.lowercased() == "game"
            }
            guard let found = index else { continue }

            // A path that IS the game directory and nothing more tells us nothing about
            // where the root is; we need something inside it.
            guard found + 1 < components.count else { continue }

            if found < bestDepth {
                bestDepth = found
                best = components[0..<found].joined(separator: "/")
            }
        }

        return best
    }
}
