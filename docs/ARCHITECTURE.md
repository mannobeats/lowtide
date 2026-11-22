# Lowtide's architecture

How Lowtide is built, where things go, and the rules that keep it one coherent app. Read this
and [DESIGN.md](../DESIGN.md) (the look) before changing code.

**Every page is whole.** It ships with its full behaviour, every state (loading, empty, error,
partial), and tests. Lowtide has a personality: the custom glyphs, hero objects, the radar and
map, the mission components, the way each page is laid out. Keep them; don't replace a custom
part with a generic one or invent a new layout for an existing page.

## Stack

- macOS 26+, Swift 6.2 language mode, SwiftPM (`Package.swift`). No Xcode project.
- `Sources/LowtideKit`: all logic. No SwiftUI. AppKit/Foundation/IOKit/Security are fine. Testable alone.
  Public API (`public`) for what the app uses. Default isolation is **nonisolated**; use `actor`s
  for shared mutable state, `Sendable` value types for data.
- `Sources/Lowtide`: the app (SwiftUI + AppKit bridges). Default isolation is **MainActor**.
- Dependencies: **only SwiftTerm** (terminal). Everything else is Apple frameworks or our own code.
  Do not add packages. Instead: JSON → Codable · HTTP → `HTTP` (LowtideKit/Core/HTTP.swift) ·
  processes → `Shell` · plists → PropertyListSerialization · hashing → CryptoKit · file changes →
  `FileWatcher` (FSEvents) · secrets → `Keychain` · storage → `Vault.shared` (SQLiteDatabase) ·
  IP geolocation → our own MMDB reader · packets → our own decoder on the system's libpcap
  (linked) · power and clocks → IOKit/IOReport, declared with `@_silgen_name` (IOReport is a
  private library: `dlopen("/usr/lib/libIOReport.dylib")`).

## Layout and ownership

```
Sources/LowtideKit/Core/            shared services used by every area
Sources/LowtideKit/<Area>/          an area's logic, models and parsers
Sources/Lowtide/Spaces/<Space>/     a space's pages and their parts
Sources/Lowtide/Design/             tokens and components
Sources/Lowtide/Shell/, App/        the window, sidebar, ⌘K, launch and updates
Sources/Lowtide/Shared/             shared views: Treemap; Mission/ (Radar, SignalLog,
                                    TelemetryBar) for Network; Runs/ for Protection;
                                    Footprint/ (one app's or leftover's files)
Tests/LowtideKitTests/<Area>Tests.swift   an area's tests
```

Spaces (rail order, ⌘1–⌘8): Home, Apps, Cleanup, Protection, Network, System, Developer
(sidebar groups Toolchain, Terminal, Remote; code folders `Spaces/Toolchain`, `Spaces/Terminal`,
`Spaces/Servers`), Extensions (code in `Spaces/Extensions/<Name>/`). Network shows its pages as
tabs; Home has no sidebar. Pages and routes: `Sources/Lowtide/App/Pages.swift`.

Fleet is a view of Hosts; Exposed secrets and Decoy keys are one Secrets page with two views;
⌘K, the command bar and Ask are one search (Ask is a mode of it).

Each space has, in `Sources/Lowtide/Spaces/<Space>/`:
- one file per page (`NetworkLivePage.swift` …).
- `<Space>Actions.swift`: actions for ⌘K / the command bar / menus (`AppAction`).
- `<Space>Lifecycle.swift`: `launch()` / `terminate()` for always-on background work (started at
  app launch, stopped at quit, never lazily from a page), `selfTests` (steps for `--selftest`),
  and `<Space>Commands` (menu bar items, e.g. New Terminal ⌘T).

A change to Core, Design or the shell affects every space: keep it small and say why in the
pull request.

## Core APIs (Sources/LowtideKit/Core)

- `Shell.run(program, args, timeout:, environment:, input:, directory:) async throws -> CommandOutput`
  (stdout, stderr, status, ok, message). Uses the login-shell PATH, quiet env for package
  managers, kills on Task cancel/timeout. `Shell.check` (throws on failure, returns stdout),
  `Shell.stream(program, args) { line in }` for long operations, `Shell.resolve`,
  `Shell.isAvailable`, `Shell.environment()` (for PTYs), `Shell.loginPath`.
- `Paths.data` / `Paths.cache` / `Paths.logs` / `Paths.home` / `Paths.tilde(path)` / `Paths.safeID`.
  `LOWTIDE_HOME` relocates data for tests.
- `JSONStore.load(name, default:)` / `JSONStore.save(value, to:)`: atomic JSON in the data folder.
- `Vault.shared` (`SQLiteDatabase` actor; migrations in `Vault.migrations`):
  `execute(sql, [bindings])`, `query(sql, [bindings]) -> [SQLRow]` (`row.string("col")`,
  `.int`, `.bool`), `transaction { db in }`. Append migrations; never edit one.
- `Keychain.set/get/has/delete(account)`: service `dev.lowtide.app`.
- `Trash.move([paths]) async -> Outcome` (`moved` with where each landed, `refused` with reasons):
  every removal goes to the Trash. `Trash.remove(paths, prompt:)` also moves root-owned paths
  (privileged helper, else one password prompt). Undo: `Toasts.shared.putBack(outcome.undoable)`
  (`Trash.putBack` underneath). Never `rm`.
- `ToolLock.shared.with("brew") { … }`: one run per tool at a time across every space (brew, npm,
  pnpm, docker, simctl…). Hold it around anything that changes a tool's state.
- `Admin.run(command, prompt:) async -> Result` (main actor): one password prompt, kept 5 min.
  `Admin.quote(arg)` for shell-safe arguments.
- `HTTP.data(url)` / `HTTP.json(T.self, from:)`: the only network client (update checks, model
  downloads). Nothing else leaves the Mac. No analytics, ever.
- `SelfUpdate`: Lowtide's own updates from its GitHub releases (`docs/RELEASING.md`).
- `FileWatcher(paths:) { changed in }`: FSEvents.
- `Format.bytes/rate/ago/duration/percent/count` (in Lowtide use `LowtideFormat.*`, since Lowtide
  has its own names).
- `Fuzzy.score/best`, `Permission` (state + request + settings URL), `LoginItem`, `Log.<area>`
  (os.Logger; never log what people typed or said, or secrets), `AppResources.url("geo/…")`
  (bundled files in `Resources/`), `LowtideError`.

## App APIs (Sources/Lowtide)

- Navigation: `AppModel.shared.open(.packets)`, `.show(page)` (also brings the window forward),
  `.privacy` (Privacy Mode). Pages are in `App/Pages.swift` (`Page`, `SpaceID`).
- `Jobs.shared.start("Updating 3 tools", page: .appsUpdates, success: "Updated") { job in
  job.detail = "…"; job.progress = 0.4; try await … }`: long work that survives navigation;
  the status bar shows it, errors become toasts.
- `Toasts.shared.show("Moved 3 items to the Trash", action: "Undo") { … }`, `.failure(title, error)`.
- `SidebarBadges.shared`: `.counts[.appsUpdates] = 4` (+ `.warning.insert(page)` for amber),
  `.totals[.appsInstalled] = 214` (quiet total), `.dots.insert(.overnight)` (report waiting).
- `StatusLine.shared.set("net", "en0 up · 192.168.1.4", tone: .ok)`: the window's bottom line.
- `StatusMenu.providers.append { [StatusMenu.Line("3 updates waiting", symbol: …) { … }] }`:
  lines in the menu bar icon's menu.
- `WindowRouter.showMain()`, `WindowRouter.showSettings()`.
- `.confirmation($request)` with `ConfirmRequest(title:message:confirm:action:)` before anything
  destructive or consequential.
- Environment: `@Environment(\.palette)`, `\.spaceHue`, `\.privacy`. Use `Sensitive(text:)` or
  `.privacyBlur(privacy)` for IPs, hostnames, user names, paths with user names.

## Design system (read DESIGN.md)

Art (`Sources/Lowtide/Design/Art.swift`):
`NavIcon("updates", filled: active, size: 16)`: every glyph in `Resources/glyphs` (61 names:
about addons appearance apps ask cleanup cleanup-caches command-bar connections credentials
decoys developer dictation discover dns doctor downloads duplicates extensions features fleet
forwards general history home hosts install-watch installed inventory leftovers live localhost
login-items menubar network new-terminal overnight packets permissions privacy processes
protection quick-connect recipe refresh runtimes search secrets sensors sessions settings setup
shortcuts silicon snippets space-lens system threats toolchain updates widgets). Use them for
every space, page, action and Settings pane; SF Symbols only for utility icons (chevrons, close,
plus, search, arrows). `HeroArt("network", size:)`: the glass hero objects
(apps cleanup command-bar developer dictation empty extensions home menubar network protection
system widgets), rim-lit in the space's hue. `Logo`.

Components in `Sources/Lowtide/Design/Components`:
`PageScaffold { hero } content: { … }` (standard scrolling page) · `PageHero(title, detail:,
art: "apps") { actions }` (a space's hero) · `PageHeader(title, description:) { tabs }
action: { … }` (a page's header) · `CountCapsule(value:, warning:)` · `PageToolbar` · `Pane(title, subtitle:) { accessory } content: { … }` ·
`.card()` · `.overlaySurface()` · `Hairline` · `ListRow(title, subtitle:) { leading } trailing: { … }`
· `KeyValueRow` · `GroupHeading` · `StatTile` · `Badge(text, tone:)` · `StatusDot` · `KeyCap` ·
`Segmented($selection, [(value, "Label")], counts:)` · `FilterField($text)` · `IconButton(symbol,
help:)` · buttons `.buttonStyle(.primary | .secondary | .quiet | .destructive)` or `.lowtide(kind,
size: .small)` · `Sparkline(values:)` · `Meter(value:)` · `Gauge(value:)` · `EmptyState` ·
`ScanningState` · `ErrorState` · `FileIcon(path:)` / `IconCache` · `TreemapView(items:)` ·
`Checkbox(state, label:)` / `CheckMark` / `Checks<ID>` (checked rows, ⇧-click runs) ·
`SelectionBar(count:noun:status:progress:working:clear:)` · `SplitList` / `SplitRow` (list +
detail) · `FilterField($text, width:)` · `FlowLayout` · `PrefsGroup` / `PrefsRow` / `PrefsSwitch`
/ `PrefsNotice` (settings rows) · `Files.reveal/open/copy/quickLook` and `PathMenu(path)`.
Tokens: `Font.ui(.sm, .medium)`, `Font.title(.xl)`, `Font.mono(.xs)`; `Radius.*`, `Space.*`,
`Motion.spring/base/fast`; colours only from `palette` (`palette.ink.color`, `palette.surface`,
`tone.color(palette)`). **No raw colours, sizes, radii or shadows in pages.** SF Symbols only
(check the name exists). Tables: SwiftUI `Table` (it's NSTableView underneath; fast for thousands
of rows) with sortable columns.

Native behaviour: every row people can act on has a context menu; Delete/Return/Space work in
lists (`.onDeleteCommand`, `.onKeyPress`); Space previews files (Quick Look); destructive actions
confirm or go to the Trash with Undo; nothing is focused when a page opens; text is selectable
where people copy (paths, IPs, versions); every icon-only button has `.help`.

Simplicity rules decided with the owner: one sentence per hero, one primary action per view, no
"Off" rows (collapse them into one line), no lists of zeros (hide idle rows), never show the same
events twice, no decorative icons, no contradictions (a hero saying "all clear" over a list of
problems).

## Concurrency (Swift 6)

- Views and models: main actor (default in Lowtide). Models are `@Observable final class`.
- Heavy work (parsing, scanning, hashing) off the main thread: an `actor`, or a `nonisolated`
  `@concurrent` function. Never block the main thread > 50 ms.
- C callbacks (IOKit, FSEvents, CoreAudio, event taps): `nonisolated static` functions; hop back
  with `Task { @MainActor in … }`. Closures handed to Dispatch/C APIs from a main-actor type must
  be `@Sendable` or Swift 6 crashes at runtime.
- No `@unchecked Sendable` / `nonisolated(unsafe)` without a comment saying why it's safe.
- Polling: a single `Task` loop per worker with `try await Task.sleep(for:)`, cancelled in
  `terminate()`. Pause expensive sampling when nothing is visible that needs it.

## Build, test, look

```
scripts/check.sh                          # compile; errors and warnings
scripts/test.sh                           # unit tests (one at a time on purpose)
scripts/run-page.sh <name> network/live   # build a private copy, open a page, capture a PNG
```

`LOWTIDE_SCRATCH` and `LOWTIDE_TEST_SCRATCH` pick other build folders, for working in several
checkouts at once. `run-page.sh` prints the PNG path: **look at every page you change** with real
data, and fix what looks wrong: clipped text, empty bands, misaligned edges, unreadable contrast.
Zero warnings. Unit-test every parser and rule in LowtideKit with real-world input (copy real
command output into the test, including the odd lines). Add self-test steps for flows that need
the app.
