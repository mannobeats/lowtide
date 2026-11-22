<p align="center">
  <img src="Resources/logo.svg" width="96" alt="Lowtide">
</p>

<h1 align="center">Lowtide</h1>

<p align="center">
  Your whole Mac in one calm, native app.
  <br>
  <a href="https://github.com/mannobeats/lowtide/releases/latest">Download</a> ·
  <a href="CHANGELOG.md">Changelog</a> ·
  <a href="CONTRIBUTING.md">Contributing</a> ·
  <a href="SECURITY.md">Security</a>
</p>

<p align="center">
  <a href="https://github.com/mannobeats/lowtide/actions/workflows/ci.yml"><img src="https://github.com/mannobeats/lowtide/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/mannobeats/lowtide/releases/latest"><img src="https://img.shields.io/github/v/release/mannobeats/lowtide" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue" alt="GPL-3.0"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-black" alt="macOS 26 or later">
</p>

Lowtide keeps your Mac in shape from one window. It tells you at a glance whether anything is
wrong, keeps your apps up to date, frees up space, watches for threats and leaked passwords,
shows who your Mac is talking to, and tidies the menu bar. If you write code, it also looks after
your developer tools, terminals and servers.

It's a native Mac app, written in Swift, free and open source.

## What it does

### For everyone

- **Home:** one answer to "is anything wrong?", your Mac's vitals, and what was noticed lately.
- **Apps:** every installed app with everything it keeps on disk, updates for all of them in one
  place, and their add-ons.
- **Cleanup:** caches, old downloads and installers, what deleted apps left behind, a map of
  what fills your disk, and duplicate files. Everything goes to the Trash, so nothing is lost by
  mistake.
- **Protection:** suspicious software, passwords and keys left exposed in files, which apps can
  use your camera, microphone and files, and a watch on what new installs change.
- **Network:** a live map of every connection your apps make and where it goes, DNS, and a
  report of what your Mac did overnight.
- **System:** power use, temperatures and fans, memory, and every running process.
- **Extensions:**
  - **Dictation:** hold a key and speak, in any app. The speech models run on your Mac.
  - **Menu bar manager:** hide the menu bar icons you rarely need, and keep favourites and live
    stats in a panel under the notch.
  - **Menu bar widgets:** CPU, memory, network and more, live in the menu bar.
  - **Command bar:** one shortcut to open apps, files and Mac settings, do quick sums, find
    emoji, run actions, and ask questions answered by Apple's on-device model.

### For developers

- **Toolchain:** everything Homebrew, npm, pnpm, Cargo, Go, uv and other package managers installed, the
  runtimes and their versions, a doctor that finds broken setups, and a recipe that sets up a new
  Mac like this one.
- **Terminal:** a native terminal with sessions, snippets and searchable history.
- **Remote:** SSH hosts and fleets, saved credentials in the Keychain, and port forwards.
- **Cleanup** also clears build folders (`node_modules`, `target`, Xcode data) and package caches,
  and **Network** shows the servers running on your Mac and can capture packets.

## Private by design

Everything runs on your Mac. There are no accounts, no analytics and no telemetry. The only
requests that leave your Mac are:

- update checks: Lowtide's own (one request a day to GitHub's releases API, which you can turn
  off in Settings › General), and the apps and tools you have installed (their developers'
  update feeds, Homebrew's catalog, package registries);
- the dictation models you choose to download;
- the servers you connect to yourself over SSH.

IP addresses are placed on the map with a database that ships inside the app, and the command
bar's assistant uses Apple's on-device model.

## Install

Download `Lowtide-<version>.dmg` from the [latest release](https://github.com/mannobeats/lowtide/releases/latest),
open it and drag Lowtide to Applications. Releases are signed with a Developer ID and notarized
by Apple.

**Requirements:** macOS 26 or later on Apple silicon.

**Updates:** Lowtide checks for a new release once a day and offers it; it never installs one
without asking. **Lowtide › Check for Updates…** checks now. An update is installed only if it's
signed by the same developer and notarized; the old copy goes to the Trash.

### Permissions

Lowtide asks for each permission when you first use the feature that needs it. Everything
else works without them.

| Permission | What it's for |
|---|---|
| Accessibility | Dictation types into other apps; the menu bar manager reads and arranges icons |
| Full Disk Access | Cleanup, Leftovers and Secrets see every app's data, and removals reach protected folders |
| Microphone | Dictation listens only while you hold its shortcut |
| Input Monitoring | The dictation shortcut works in every app |
| Screen & System Audio Recording | The menu bar manager shows the real pictures of the icons it hides |
| Automation | Finder and System Events empty the Trash, eject disks and manage login items |

An optional privileged helper, which you approve in System Settings › Login Items, removes
root-owned leftovers without asking for your password each time.

## Build from source

You need macOS 26 and Xcode 26 or later. There's no Xcode project: the app is a Swift package
built by small scripts.

```sh
git clone https://github.com/mannobeats/lowtide.git && cd lowtide
scripts/build.sh --open            # build into /Applications/Lowtide.app and open it
scripts/test.sh                    # unit tests
scripts/check.sh                   # compile only, errors and warnings
```

Optional helpers, built once and copied in by `build.sh`:

```sh
scripts/build-privileged.sh        # the helper that removes root-owned files
scripts/build-voice.sh             # the dictation helper (MLX and Core ML, slow)
```

`build.sh` signs with the first Developer ID or Apple Development certificate in your
keychain, or ad hoc when there's none. Releases are made by CI from a version tag; see
[docs/RELEASING.md](docs/RELEASING.md).

Lowtide is two targets: `LowtideKit` holds all the logic and is tested without a UI, and
`Lowtide` is the app. The only package dependency is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains the structure and the rules, and
[DESIGN.md](DESIGN.md) the look.

## Contributing

Bug reports, ideas and pull requests are welcome: read [CONTRIBUTING.md](CONTRIBUTING.md) first.
Please report security issues privately, as [SECURITY.md](SECURITY.md) explains.

## License

Lowtide is free software under the [GNU General Public License v3.0](LICENSE). Third-party code and
data it includes are listed with their licenses in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
IP geolocation by [DB-IP](https://db-ip.com) (CC BY 4.0).
