import Foundation

/// A Ren'Py save slot, and the file name it actually occupies.
///
/// The file name is NOT `<slot>.save`. `renpy/__init__.py:144` sets
/// `savegame_suffix = "-LT1.save"` and `savelocation.py:150` joins `slotname + suffix`,
/// so slot `3-2` is the file `3-2-LT1.save`. A rename that drops the suffix produces a
/// file Ren'Py will not list and will not load.
public struct SaveSlot: Equatable, Hashable {

    public static let suffix = "-LT1.save"

    /// `"3"`, `"auto"`, `"quick"`. Everything before the FINAL dash of the slot name.
    public let page: String
    public let number: Int

    public init(page: String, number: Int) {
        self.page = page
        self.number = number
    }

    /// Parse a file name from a Ren'Py save directory. Returns nil for anything that is
    /// not a save file -- `persistent`, a stray `.txt`, a `.save` without the suffix.
    public init?(fileName: String) {
        guard fileName.hasSuffix(Self.suffix) else { return nil }

        let slotName = String(fileName.dropLast(Self.suffix.count))
        guard !slotName.isEmpty else { return nil }

        // The final dash, not the first. `auto-1` is page "auto", number 1.
        guard let dash = slotName.lastIndex(of: "-") else { return nil }

        let page = String(slotName[slotName.startIndex..<dash])
        let numberText = String(slotName[slotName.index(after: dash)...])

        guard !page.isEmpty, let number = Int(numberText), number > 0 else { return nil }

        self.page = page
        self.number = number
    }

    public var slotName: String { "\(page)-\(number)" }
    public var fileName: String { slotName + Self.suffix }
}

/// One incoming save file and where it will land.
public struct Placement: Equatable {
    /// The file's name at the source, which may repeat across a plan.
    public let sourceName: String
    public let destination: SaveSlot
    /// True when the slot it asked for was taken and it was given another.
    public let movedToNewSlot: Bool

    public init(sourceName: String, destination: SaveSlot, movedToNewSlot: Bool) {
        self.sourceName = sourceName
        self.destination = destination
        self.movedToNewSlot = movedToNewSlot
    }
}

/// Decides where imported saves go, and guarantees nothing is displaced.
///
/// Pure: no file system, no archive, no dates. That is deliberate. This is the rule with
/// the sharpest consequence for being wrong -- getting it wrong costs someone a
/// playthrough -- so it has to be exhaustively testable in milliseconds.
public enum SlotPlacement {

    /// The lowest unused number on `page`. Fills holes rather than appending, so a save
    /// directory does not grow a sparse tail after repeated imports.
    public static func nextFree(page: String, taken: Set<SaveSlot>) -> SaveSlot {
        var number = 1
        while taken.contains(SaveSlot(page: page, number: number)) {
            number += 1
        }
        return SaveSlot(page: page, number: number)
    }

    /// Place every incoming save, never onto an occupied slot.
    ///
    /// `existing` are the file names already in the destination directory. Entries that
    /// do not parse as saves are dropped: only saves belong in a save directory, and
    /// writing a non-save there would be a new kind of mess.
    public static func place(incoming: [String], existing: Set<String>) -> [Placement] {
        var taken = Set(existing.compactMap(SaveSlot.init(fileName:)))
        var result: [Placement] = []

        for name in incoming {
            guard let wanted = SaveSlot(fileName: name) else { continue }

            if !taken.contains(wanted) {
                taken.insert(wanted)
                result.append(Placement(sourceName: name,
                                        destination: wanted,
                                        movedToNewSlot: false))
                continue
            }

            // Occupied. Note that `taken` accumulates as we go, so two incoming files
            // wanting the same slot get two different destinations rather than both
            // being sent to the same one.
            let free = nextFree(page: wanted.page, taken: taken)
            taken.insert(free)
            result.append(Placement(sourceName: name,
                                    destination: free,
                                    movedToNewSlot: true))
        }

        return result
    }
}
