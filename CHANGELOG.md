# Changelog

Notable changes for each release. The format follows [Keep a Changelog](https://keepachangelog.com),
and versions follow [Semantic Versioning](https://semver.org). A release's notes on GitHub are
taken from its section here.

## [Unreleased]

### Added

- Dictation's shortcut takes any key: the one above Tab, letters, digits, punctuation, and the
  arrows, with or without ⌘, ⌥ or ⌃. The row keeps a one-line note when a key gives up the
  character it types, and shows "Saved" once it's recorded.

### Fixed

- Dictation keeps working while another app holds Secure Input, as a focused password field
  does. macOS hides key presses from the shortcut's event tap then; the shortcut is now taken
  as a Carbon hotkey for as long as that lasts, so dictation still starts anywhere. The warning
  that used to say an app was blocking the shortcut is gone, since nothing is blocked.

## [1.2.0] - 2026-11-23

### Changed

- Calmer, more refined type: text on dark themes is a soft white like macOS's own instead of a
  near-pure white that read as bold, buttons use regular weight, the hint under each setting is
  11 pt, and page titles are 26 pt.
- Dictation's Parakeet models run on FluidAudio 0.18.3. The first load after updating takes a
  little longer while macOS prepares the model once.

## [1.1.1] - 2026-11-22

### Fixed

- Installing an update quits and reopens Lowtide by itself, instead of waiting until you quit
  it.

## [1.1.0] - 2026-11-22

### Added

- Lowtide updates itself: a daily check of its GitHub releases (Settings › General › Updates,
  or Lowtide › Check for Updates…), installed only when signed by the same developer and
  notarized.
- Menu bar manager on macOS 27: an always-hidden section, and Lowtide's bar of hidden icons
  under «, with a choice between it and macOS's own «.
- Lowtide is open source under the GPL-3.0, built and released in the open.

### Fixed

- Menu bar manager on macOS 27: hidden apps' names no longer stay stuck on screen after an
  icon moves, « sits beside the shown icons instead of across an empty gap, and the divider
  settles at once instead of in many steps.
- Menu bar widgets: the colour presets stay within the page at any window width.

## [1.0.0] - 2026-11-18

The first version of Lowtide, before the project was published.
