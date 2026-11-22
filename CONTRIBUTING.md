# Contributing to Lowtide

Thanks for helping. Lowtide is a native Mac app with a high bar for polish, so a little
reading first saves a round of review.

## Before you start

- **Bugs:** search the [issues](https://github.com/mannobeats/lowtide/issues) first, then open one
  with the bug template: your macOS version, Lowtide's version (Lowtide › About), what you did,
  what you expected and what happened.
- **Features:** open an issue to talk it over before writing a large change. Small fixes can go
  straight to a pull request.
- **Security issues:** never in a public issue. See [SECURITY.md](SECURITY.md).

## Setting up

You need Xcode 27.2 or later. The app itself runs on macOS 26 and later.

```sh
scripts/build.sh --open   # build into /Applications/Lowtide.app and open it
scripts/check.sh          # compile only: errors and warnings
scripts/test.sh           # unit tests (they run one at a time on purpose)
```

To try a change without replacing your installed copy, `scripts/run-page.sh <name> <route>`
builds a private copy beside it and captures one page's window.

## How the code is organized

Read these before changing code:

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): the structure, the APIs, who owns what, and the rules.
- [DESIGN.md](DESIGN.md): the look. Views use the design tokens, never raw colours or sizes.

In short:

- Logic goes in `Sources/LowtideKit` (no SwiftUI) and gets tests in `Tests/LowtideKitTests`.
  Views go in `Sources/Lowtide`.
- Data crosses from one space to another only through `App/Integration.swift`.
- The only package dependency is SwiftTerm. Use Apple's frameworks or write it; please don't
  add packages.
- Anything that removes files sends them to the Trash or asks for confirmation first.
- Nothing leaves the Mac except update checks and downloads the person asked for. No analytics.

## Pull requests

- One change per pull request, with a description of what it changes and how you checked it.
- `scripts/check.sh` has no new warnings and `scripts/test.sh` passes. CI runs both.
- New logic has tests. A bug fix comes with a test that fails without it.
- UI changes include a screenshot (Privacy Mode, ⇧⌘P, hides names and paths).
- Write commit messages that say what changed for the person using the app.

By contributing, you agree that your contributions are licensed under the
[GPL-3.0](LICENSE), the same as the rest of Lowtide.

## Code of conduct

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
