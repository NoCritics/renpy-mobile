import Foundation

/// The text of `WHERE-TO-PUT-THESE.txt`.
///
/// This file is the whole PC half of save transfer. There is no desktop app, no
/// documentation page and no support channel -- if these sentences are wrong or vague,
/// the export is a zip nobody can do anything with.
///
/// The paths are Ren'Py's own, read from `renpy.py:176-204` of the vendored 8.5.3 SDK
/// rather than remembered.
public enum DesktopSaveLocations {

    public static func instructions(title: String, saveDirectory: String?) -> String {
        guard let saveDirectory, !saveDirectory.isEmpty else {
            return noSaveDirectory(title: title)
        }

        return """
        Saves for \(title), exported from VNPlayer on iPhone.

        The save files are in the folder next to this note. To use them on a
        computer, copy them into the game's save folder:

          Windows   %APPDATA%/RenPy/\(saveDirectory)
          macOS     ~/Library/RenPy/\(saveDirectory)
          Linux     ~/.renpy/\(saveDirectory)

        Close the game first. Existing saves with the same name would be replaced,
        so move them somewhere else first if you want to keep them.

        One exception: if there is a folder called "Ren'Py Data" next to the game
        (or in a folder above it), the game uses that instead, and the saves go in
        "Ren'Py Data/\(saveDirectory)".

        Going the other way works too. Copy save files off a computer, put them in
        a .zip, and open it with Import saves in VNPlayer.
        """
    }

    /// `config.save_directory` is None (renpy/config.py:369). Ren'Py then saves to
    /// `<gamedir>/saves` and there is no per-user location to name at all.
    private static func noSaveDirectory(title: String) -> String {
        """
        Saves for \(title), exported from VNPlayer on iPhone.

        This game does not set a save folder name of its own, which means on a
        computer it keeps its saves right beside the game itself, in a folder
        called "saves" inside the game's own folder.

        To use these on a computer, close the game, then copy the save files from
        the folder next to this note into that "saves" folder. If it isn't there,
        create it.

        Existing saves with the same name would be replaced, so move them somewhere
        else first if you want to keep them.

        Going the other way works too. Copy save files off a computer, put them in
        a .zip, and open it with Import saves in VNPlayer.
        """
    }
}
