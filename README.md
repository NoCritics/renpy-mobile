# VNPlayer

A free, open-source iOS player for Ren'Py 8 visual novels. Put a `.zip` on your phone,
add it, read. No ads, no purchases, no accounts, no time limits.

VNPlayer never downloads a game by itself. Every game arrives because you chose a file.

> **Note (August 2026):** the newest release predates save export/import and the in-game
> controls. Until the next release is tagged, take the build from
> [Actions](https://github.com/NoCritics/renpy-mobile/actions/workflows/ios-build.yml) —
> newest green run on `main`, **Artifacts → `VNPlayer-ipa`**, unzip, use the `.ipa`
> inside. *Delete this note once a release is cut.*

---

## Install

Windows PC, a USB cable that syncs (not charge-only), and a free Apple ID. About 20
minutes the first time.

1. **Install [Sideloadly](https://sideloadly.io/).**
2. **Install Apple's USB drivers.** Sideloadly can offer to do this for you. Installing
   manually, use [iTunes from apple.com](https://www.apple.com/itunes/) — or search the
   Microsoft Store for **Apple Devices**, Apple's newer replacement for it. Do **not**
   use the Microsoft Store version of *iTunes*, which leaves the drivers out.
3. **Connect your iPhone by USB** and unlock it. Tap **Trust This Computer** if asked.
4. **Open Sideloadly** and check your iPhone appears in its dropdown.
5. **Enable Developer Mode** on the phone:
   **Settings → Privacy & Security → Developer Mode → On**.
   Restart when asked, then confirm Developer Mode again after the reboot.
   *(iOS 16+. Required — the app will not launch without it.)*
6. **Download `VNPlayer.ipa`** from the
   [latest release](https://github.com/NoCritics/renpy-mobile/releases/latest).
7. **Drag the `.ipa` into Sideloadly.**
8. **Enter your Apple ID and password** in Sideloadly. This makes a signing certificate
   on your own PC; nothing is sent to this project and no payment method is involved.
9. **Click Start** and wait.
10. **Trust the certificate** on the phone:
    **Settings → General → VPN & Device Management → Developer App →** your Apple ID
    **→ Trust**. *(The step almost everyone forgets.)*
11. **Open VNPlayer.**

Stuck? [`docs/INSTALL.md`](docs/INSTALL.md) has the same steps with screenshots' worth
of detail and a troubleshooting section.

## Add and play games

1. Get a Ren'Py game's `.zip` onto the phone — Safari, iCloud Drive, AirDrop, anything
   the **Files** app can see.
2. **VNPlayer → Add game**, and pick the `.zip`.
3. Wait for the import. A large game takes a few minutes.
4. **Hold the phone sideways.** VNPlayer is landscape-only.
5. Tap the game to play.

A strip of icons sits on the right edge while you read. It fades out and comes back when
you touch it: go back a line, skip, the game's own **Save**, **Load** and **Settings**
pages, a magnifier, back to your library, and save-file export/import.

Saves work through the game's own Save and Load screens — the same ones you would use on
a PC.

## Important

- **A free Apple ID signature expires after 7 days.** The app stops opening. Re-run
  Sideloadly with the same `.ipa` to re-sign it — **do not delete the app first**;
  installing over the top keeps your games and saves.
- **Back up your saves before re-signing.** **VNPlayer → Back up saves** gives you one
  file with every game's saves in it. Importing never overwrites a save you already
  have.
- **A free Apple ID allows 3 sideloaded apps at once.** Remove another if you are at the
  limit.
- **Ren'Py 8 only.** Ren'Py 7 games are refused with a message rather than failing
  strangely.
- **Saves can contain code.** That is true of Ren'Py everywhere, not just here. Your own
  saves are fine; a save from someone you do not know is exactly as trustworthy as that
  person. VNPlayer warns you when a file did not come from its own Export, and it cannot
  check the file for you.

## Status

Milestones A through D are merged: the engine shell, the iOS build pipeline, the library
and `.zip` import, the in-game overlay, and save transfer. A commercial 1.2 GB visual
novel imports and plays by touch on an iPhone 13 Pro Max.

**Save export and import have not yet been tested on a device** —
[`docs/STATE.md`](docs/STATE.md) carries the checklist and is the honest account of what
is verified versus what merely compiles.

## More

- [Full install guide](docs/INSTALL.md)
- [Where the project stands](docs/STATE.md)
- [Design](docs/superpowers/specs/2026-08-24-renpy-ios-player-design.md)
- [Research](docs/2026-08-24-research-renpy-ios-player.md)

---

Not affiliated with or endorsed by the Ren'Py project.

Ren'Py is MIT-licensed with LGPL-derived portions. This program contains free software
licensed under a number of licenses, including the GNU Lesser General Public License.
