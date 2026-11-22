# Lowtide

Native Mac app that keeps a Mac in shape: apps and their updates, cleanup, protection, network,
system monitor, and for developers terminal and remote servers and the toolchain, plus extensions
(dictation, menu bar manager, widgets, command bar with on-device Ask). Swift 6 / SwiftUI +
AppKit, SwiftPM, macOS 26+. Everything runs on the Mac; the only requests out are update checks
and models a person chooses to download.

- Build: `scripts/build.sh [--release] [--open]` → `/Applications/Lowtide.app`. Compile only:
  `scripts/check.sh`. Helpers, built separately and copied in by build.sh:
  `scripts/build-voice.sh` (dictation, MLX, slow, once), `scripts/build-privileged.sh`,
  `scripts/build-icon.sh` (Icon Composer → Support/).
- Tests: `scripts/test.sh` (serial on purpose: suites drive real processes and timers).
  Self-test: `LOWTIDE_HOME=/tmp/lowtide-selftest /Applications/Lowtide.app/Contents/MacOS/Lowtide --selftest`.
- Releases: tag `vX.Y.Z` and CI signs, notarizes and publishes; the app updates itself from
  GitHub releases (`SelfUpdate`). See `docs/RELEASING.md`. Public repo: no personal data in code,
  docs or commits (commit as the GitHub no-reply address).
- Look at a page: `scripts/run-page.sh <name> <route>` (builds a private copy, captures the window).
- Read before working: `docs/ARCHITECTURE.md` (structure, APIs, ownership, rules), `DESIGN.md` (look).
  Keep Lowtide's identity: its glyphs, hero art, rail and page layouts.
- Logic in `Sources/LowtideKit` (no SwiftUI, tested); views in `Sources/Lowtide`. Cross-space data
  flows only through `App/Integration.swift`. One package dependency (SwiftTerm).
- Removals go to the Trash or through a confirmation. No raw colours or sizes in views.
