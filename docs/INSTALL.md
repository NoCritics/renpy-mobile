# Putting VNPlayer on your iPhone

VNPlayer reads Ren'Py visual novels on an iPhone. You add a game as a `.zip` file, and
it plays.

Apple has not approved this app, so you sign it yourself with your own free Apple ID,
using a free tool called **Sideloadly**. That sounds alarming and isn't — it is the
normal way to run an app Apple hasn't published. No jailbreak, no paid developer
account, no Mac. Everything below runs on a Windows PC.

**Set aside about 20 minutes the first time.** After that it's a five-minute job.

## The one thing to know before you start

**A free Apple ID signature lasts 7 days.** After a week the app stops opening. This is
Apple's rule and there is no way around it without paying them.

Fixing it takes five minutes: plug the phone in, run Sideloadly again, done. Your games
and saves stay where they are. It is a chore, not a disaster — but it is a chore that
comes back every week, so it's worth knowing on day one rather than discovering it on
day eight.

**Before you re-sign, back up your saves.** It takes ten seconds and it means a bad
week can't cost you a playthrough. See [Backing up your saves](#backing-up-your-saves).

---

## What you need

- **A Windows PC** and a USB cable that charges *and* syncs. Charge-only cables are
  common and will not work. If the phone charges but the PC never notices it, that's
  the cable.
- **An iPhone.** Tested on an iPhone 13 Pro Max running iOS 26.6. Older phones should
  work but nobody has tried, so treat them as untested rather than supported.
- **A free Apple ID.** The same kind you use for the App Store. If you'd rather not use
  your main one, make a second — it costs nothing and needs no payment method.
- **[Sideloadly](https://sideloadly.io/)**, installed on the PC.
- **Apple's USB drivers.** Sideloadly needs them to talk to the phone. Install either:
  - **iTunes from [apple.com](https://www.apple.com/itunes/)** — from Apple's own site,
    *not* the Microsoft Store version, which leaves out the drivers, or
  - the **Apple Devices** app from the Microsoft Store, Apple's newer replacement.

## 1. Get the app file

Go to the [latest release](https://github.com/NoCritics/renpy-mobile/releases/latest)
and download **`VNPlayer.ipa`** (about 28 MB). No account needed. The file is ready to
use as-is.

<details>
<summary>If you were told to use a specific build instead</summary>

Every change to the project builds a new copy of the app before it becomes a release.
Open the
[build page](https://github.com/NoCritics/renpy-mobile/actions/workflows/ios-build.yml),
click the newest run with a green tick, and download **`VNPlayer-ipa`** from the
**Artifacts** section at the bottom.

Two differences: you need a free GitHub account, and **it arrives as a `.zip`**. Unzip
it and use the `VNPlayer.ipa` inside — handing Sideloadly the `.zip` will not work.
These builds are also deleted after 90 days.
</details>

## 2. Install Sideloadly and the drivers

Install both, in either order. If Sideloadly was already running, close and reopen it
afterwards so it notices the drivers.

## 3. Plug in the phone

Unlock it. The phone asks **"Trust This Computer?"** — tap **Trust** and enter your
passcode. Sideloadly should now show your phone's name in its dropdown.

If it doesn't: try a different USB cable before anything else.

## 4. Turn on Developer Mode

*iOS 16 and newer. Harmless on older versions, so just do it either way.*

Sideloaded apps will not run without this, and it's off by default.

1. On the phone: **Settings → Privacy & Security**, scroll to the bottom, tap
   **Developer Mode**.
2. Turn it on. The phone asks to restart — let it.
3. After restarting, unlock the phone. A box appears asking you to confirm Developer
   Mode. Confirm, and enter your passcode.

This is required, not optional. The app will not open without it.

## 5. Sign in

In Sideloadly, type the Apple ID and password you want to sign with.

Sideloadly uses this to make a signing certificate on your own PC. Nothing is sent to
this project, and no payment method is involved.

## 6. Install

1. Drag `VNPlayer.ipa` into Sideloadly's window.
2. Check your phone is the one selected in the dropdown.
3. Click **Start**.

It takes a few minutes the first time — it may download extra tools as it goes. When it
finishes, the VNPlayer icon appears on your home screen.

If it fails partway, read [Troubleshooting](#troubleshooting) before trying again.

## 7. Trust the certificate

The app is on the phone, but iOS won't open it until you say the signature is one you
trust. **This is the step almost everyone forgets.**

1. On the phone: **Settings → General → VPN & Device Management**.
2. Under **Developer App**, tap the entry named after your Apple ID.
3. Tap **Trust**, then confirm.

## 8. Open it

Tap the icon. You should see an empty library with an **Add game** button.

That's it — the app is working. Now put a game in it.

---

## Adding a game

VNPlayer reads Ren'Py visual novels packaged as `.zip` files — the PC version of the
game, not an iPhone-specific one.

1. Get the game's `.zip` onto the phone. Any route works: AirDrop it from a computer,
   download it in Safari, or put it in iCloud Drive. It just needs to be somewhere the
   **Files** app can see.
2. In VNPlayer, tap **Add game** and pick the `.zip`.
3. Wait. A large game takes a few minutes, and the app shows its progress.

VNPlayer strips out the parts of the download meant for Windows, Mac and Linux, which
usually saves a hundred megabytes or more per game.

**If a game is refused**, the message says why in plain words — the file isn't really a
zip, the archive is damaged, it's a Ren'Py 7 game (not supported yet), or there isn't
enough space. The message is the explanation; there's nothing hidden in a log.

**The app never downloads anything by itself.** Every game arrives because you chose a
file.

## Playing

Tap the game to start it. **Hold the phone sideways** — VNPlayer is landscape-only.

A column of icons sits down the right-hand edge. It fades out while you read and comes
back when you touch it:

| | |
|---|---|
| ↺ | Go back a line |
| » | Skip |
| ▤ | The game's own Save page |
| ▤ | The game's own Load page |
| ⚙ | The game's own Settings |
| ⌕ | Magnifier — makes everything bigger, and blurrier |
| ▣ | Back to your library |
| ⇧ | Export this game's saves to a file |
| ⇩ | Import saves from a file |

The Save, Load and Settings icons open the game's *own* screens — the same ones you'd
see on a PC, with all its slots and its own options.

## Backing up your saves

Worth doing before every re-sign, and before deleting anything.

**To back up everything:** in your library, tap **Back up saves**. You get one file
containing every game's saves. Send it wherever you keep things safe — AirDrop to a
computer, Save to Files, email it to yourself.

**To back up one game:** press and hold the game in your library, then **Export saves**.

**To restore:** tap **Import saves** and pick the file. VNPlayer tells you exactly what
it's about to do before it does it — how many saves, and how many will go into empty
slots — and waits for you to agree.

**Importing never overwrites a save you already have.** If a slot is taken, the
incoming save goes into a free one instead. You cannot lose a playthrough by importing
the wrong file.

### Using saves on a computer

An exported file is an ordinary `.zip`, so a computer opens it with nothing installed.
Inside is a note called **WHERE-TO-PUT-THESE.txt** naming the exact folder to copy the
saves into for that game, on Windows, Mac and Linux.

It works in the other direction too: zip up a game's save folder from your computer,
send it to the phone, and import it.

> **One caution.** A Ren'Py save file can contain program code — this is true of Ren'Py
> everywhere, not just here. Saves you made yourself are fine. A save from someone you
> don't know is exactly as trustworthy as that person. VNPlayer warns you when a file
> didn't come from its own Export, and it cannot check the file for you. Nobody can.

## When it stops opening after a week

The icon greys out, or tapping it does nothing. That's the 7-day signature expiring —
not a fault, and nothing is lost.

1. Back up your saves first, if you haven't lately.
2. Plug the phone into the PC.
3. Open Sideloadly, drag in the same `VNPlayer.ipa`, click **Start**.

Don't delete the app first — installing over the top keeps your games and saves.

**You can have 3 sideloaded apps at a time** on a free Apple ID. If you're at the
limit, remove another one first.

---

## Troubleshooting

**Sideloadly can't see the phone.**
Try another USB cable — this is the most common cause by a wide margin. Then check the
phone is unlocked and that you tapped **Trust** on it.

**Sideloadly finishes, but there's no icon on the home screen.**
Look in Sideloadly's log for a red line. Usually the Apple ID sign-in went stale: sign
out and back in inside Sideloadly, then retry step 6.

**iOS says "Unable to Install", or the icon has a small exclamation mark.**
You skipped step 7 (trusting the certificate), or on iOS 16+ step 4 (Developer Mode).
Do both.

**It worked for a week and then stopped.**
That's the expiry. See above.

**A game won't import.**
Read the message — it says which of the specific reasons applies. If it says the
archive is damaged, download the game again; a partial download is the usual cause.

**The app closes by itself while a game is running.**
Note which game and roughly when, then look in **Settings → Privacy & Security →
Analytics & Improvements → Analytics Data** for a recent entry named after the app.
Save a copy of it — that file is the single most useful thing to send, and getting it
needs nothing but the phone.

<details>
<summary>If you have the source code checked out</summary>

With the repository cloned, Git Bash, and
[libimobiledevice for Windows](https://github.com/jrjr/libimobiledevice-windows)
installed, you can capture the phone's live log over USB:

```
bash scripts/ios/device_log.sh 30
```

That writes 30 seconds of device log to `logs/device.log` and prints anything from
VNPlayer. Most people reading this guide downloaded only the `.ipa` and won't have any
of that — use the Analytics Data route above.
</details>

## Two things that look wrong and aren't

**The app's name on the phone has a long code after it.** The `.ipa` is built as
`io.github.nocritics.vnplayer`, and Sideloadly adds your own signing team to the end
while installing, giving something like `io.github.nocritics.vnplayer.XXXXXXXXXX`. That
suffix is yours and is meant to be there.

**The magnifier makes text blurry.** It enlarges the picture the game draws rather than
re-laying-out the text, so everything gets bigger *and* softer. Games position their
text by exact pixel positions, so changing the font size would push dialogue outside
its box. Blurrier but complete beats sharp but cut off.

---

VNPlayer is free and open source. The code, and what's being worked on next, are at
[github.com/NoCritics/renpy-mobile](https://github.com/NoCritics/renpy-mobile).
