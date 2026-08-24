# Installing VNPlayer on your iPhone

VNPlayer is unsigned software: Apple has not approved it, so you sign it yourself with
your own free Apple ID using a tool called **Sideloadly**. This takes about 15 minutes
the first time. No jailbreak, no paid developer account, no Mac required — everything
below runs on Windows.

**What you get right now:** a diagnostic screen, not a visual novel reader yet. It
proves the app is running our engine on your phone. That is the correct, expected
result today — see step 8.

## Before you start

You need:

- A Windows PC with a USB cable that can both charge and sync your iPhone.
- An iPhone. Any iOS version from the last few years works; iOS 16 and later need one
  extra step (step 4).
- A free Apple ID (the same kind you'd use for the App Store). If you don't want to use
  your main one, any free Apple ID works — this does not require a paid Apple Developer
  Program membership.
- [Sideloadly](https://sideloadly.io/) installed on your PC.
- Apple's USB drivers. Install one of these (Sideloadly needs it to talk to your
  phone):
  - **iTunes from [apple.com](https://www.apple.com/itunes/)** — download the installer
    from Apple's own site, not the Microsoft Store version, which does not include the
    drivers Sideloadly needs.
  - or the **Apple Devices** app from the Microsoft Store, which is Apple's newer
    replacement for iTunes and also includes the drivers.

## 1. Download the `.ipa`

Go to the [latest release](https://github.com/NoCritics/renpy-mobile/releases/latest)
and download `VNPlayer.ipa` (about 27 MB). If there is no release yet, download it from
the **Artifacts** section of the most recent successful run of the
[iOS build workflow](https://github.com/NoCritics/renpy-mobile/actions/workflows/ios-build.yml)
instead — you'll need a free GitHub account to download workflow artifacts.

## 2. Install Sideloadly and the USB drivers

Install Sideloadly and iTunes (or Apple Devices) as listed above, in either order. If
Sideloadly was already open, restart it after installing the drivers so it can find
them.

## 3. Connect your iPhone

Plug the iPhone into the PC with a USB cable. Unlock the phone. A **"Trust This
Computer?"** prompt appears on the phone — tap **Trust** and enter your passcode if
asked. Sideloadly should now show your device name in its device dropdown.

## 4. Turn on Developer Mode (iOS 16 and later only)

Skip this step if your phone is on an iOS version older than 16 — go to step 5. If
you're not sure, do this step anyway; it's harmless on older versions.

Sideloaded apps will not run on iOS 16+ until Developer Mode is on, and it's off by
default.

1. On the iPhone, open **Settings → Privacy & Security**, scroll to the bottom, and tap
   **Developer Mode**.
2. Turn it on. The phone will ask to restart — let it.
3. After the restart, unlock the phone. A dialog appears asking to confirm turning on
   Developer Mode. Confirm it and enter your passcode.

This is a real, required step, not an optional extra — the app will not launch without
it on a modern iPhone.

## 5. Sign in with your Apple ID

In Sideloadly, enter the Apple ID and password you want to sign the app with, in the
Apple ID field. Sideloadly uses this only to generate a free signing certificate for
your device locally — it is not uploaded anywhere by this project, and no App Store
account or payment method is involved.

## 6. Install the app

1. Drag `VNPlayer.ipa` into Sideloadly's main window (or click the file icon and browse
   to it).
2. Confirm your device is selected in the dropdown.
3. Click **Start**.
4. Sideloadly signs the app and installs it. This can take a few minutes the first
   time, especially if it needs to download supporting tools. Watch its log for
   progress; a successful run ends with the app icon appearing on your phone's home
   screen.

If it fails partway, see **Troubleshooting** below before retrying.

## 7. Trust the developer certificate on your phone

The app is installed but iOS will refuse to open it until you trust the certificate
that signed it — this is the step almost everyone misses.

1. On the iPhone, open **Settings → General → VPN & Device Management**.
2. Under "Developer App", tap the entry for your Apple ID (it will look like an email
   address).
3. Tap **Trust "[your Apple ID]"**, then confirm **Trust** again.

## 8. Launch it

Tap the VNPlayer icon on your home screen. You should see a screen of white text
listing something like:

```
VNPlayer shell is running
alive for 7s
Ren'Py 8.5.3.26051504
Python 3.12.8
platform: darwin
basedir: ...
...
vnshell: imported OK
```

**This is success.** VNPlayer does not read visual novels yet — this build only proves
the engine boots and keeps running on your phone. A wall of text with a counter ticking
up is the app working correctly, not a crash or a bug.

One detail you may notice: the bundle identifier baked into the `.ipa` is
`io.github.nocritics.vnplayer`, but Sideloadly rewrites it during signing to include
your own signing team, so what actually shows up on the device is something like
`io.github.nocritics.vnplayer.RSL349SL6N` (the suffix is specific to your Apple ID).
That's expected — it's not a different or corrupted app.

## Free Apple ID limits

Signing with a free Apple ID (rather than a paid Apple Developer Program membership)
comes with two limits, both from Apple, not from this project:

- **The signature expires after 7 days.** After that, the app icon greys out and it
  will not launch. To fix it, open Sideloadly, plug the phone back in, and repeat step
  6 with the same `.ipa` — no need to uninstall first.
- **A maximum of 3 sideloaded apps per device** at a time with a free Apple ID. If
  you're already at the limit, remove another sideloaded app before installing this
  one.

## Troubleshooting

**The app doesn't appear on the home screen after Sideloadly says it finished.**
Check Sideloadly's log for a red error line — a common cause is being signed in with
the wrong Apple ID, or a stale Apple ID session. Sign out and back in within Sideloadly
and retry step 6.

**iOS refuses to launch it ("Unable to Install" or the icon has a small exclamation
mark).** You almost certainly skipped step 7 (trusting the developer certificate) or,
on iOS 16+, step 4 (Developer Mode). Do both and try again.

**It worked for a week, then stopped launching.** This is the 7-day free-Apple-ID
expiry described above, not a bug. Re-install with Sideloadly.

**It shows a black screen, or a wall of text, and nothing else happens.** That is the
expected, correct result right now — see step 8. VNPlayer is pre-alpha and does not yet
import or play visual novels; this diagnostic screen is proof the engine is running.

**It crashes immediately, or the diagnostic screen never appears.** First check
**Settings → Privacy & Security → Analytics & Improvements → Analytics Data** on the
phone for a recent entry named after the app, and save a copy — it's the most useful
thing to report. For more detail, you can capture the phone's live console output from
a PC with a terminal:

```
bash scripts/ios/device_log.sh 30
```

This requires [libimobiledevice for Windows](https://github.com/jrjr/libimobiledevice-windows)
and a USB connection to an unlocked, trusted phone; it writes 30 seconds of the device's
log to `logs/device.log` and prints a summary of anything from VNPlayer. Ren'Py's own
log lines are only readable in this capture because the build patches `Log.m` to use
`%{public}s` instead of Apple's default redacted `%s` (see
`scripts/ios/enable_public_log.sh`) — a pre-alpha debugging affordance that makes this
app's log visible to anyone with USB access to the phone, and one this project intends
to revisit before any wider release.

## What's next

This build proves the engine runs on iOS. It does not yet import `.zip` visual novels,
show a library, or accept touch input — that's the next milestone. Check
[the repository](https://github.com/NoCritics/renpy-mobile) for progress.
