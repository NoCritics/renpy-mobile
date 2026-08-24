# VNPlayer

A free, open-source iOS player for Ren'Py 8 visual novels. Import a `.zip`, tap, read.
No ads, no purchases, no time limits.

Status: pre-alpha. Milestone A (engine shell) and Milestone B (iOS build pipeline) are
complete — a GitHub Actions runner builds an unsigned `.ipa` that installs on a real
iPhone via Sideloadly and boots our Python shell layer, confirmed on hardware. It does
not yet import or play visual novels; see `docs/IOS-BUILD.md` for what has actually been
measured.

- Install it: `docs/INSTALL.md`
- Latest release: https://github.com/NoCritics/renpy-mobile/releases/latest (404s until
  the first tag is pushed — no release exists yet; `docs/INSTALL.md` has a working
  fallback via the Actions workflow's Artifacts in the meantime)
- Design: `docs/superpowers/specs/2026-08-24-renpy-ios-player-design.md`
- Research: `docs/2026-08-24-research-renpy-ios-player.md`

This project is not affiliated with or endorsed by the Ren'Py project.

Ren'Py is MIT-licensed with LGPL-derived portions. This program contains free software
licensed under a number of licenses, including the GNU Lesser General Public License.
