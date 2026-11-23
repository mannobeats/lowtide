# Lowtide design system

A native Mac workspace where one developer keeps their Mac, toolchain and servers in order.
Feeling: calm, quick, confident. Native chrome (sidebar, toolbar, menus, Settings follow macOS
exactly); the content has the product's own voice.

Every screen answers: Where am I? What can I do? Where can I go?

This is Lowtide's Graphite look. The custom parts are the identity: keep them.

## Shell

- Icon rail (72 pt) on the window's sidebar material: the logo, search (⌘K), each space as its own
  glyph over its name, the current one in a flat filled pill with a solid brand
  glyph; Privacy (lit in the brand colour while on) and Settings at the bottom. ⌘1–⌘8.
- Source list (248 pt) for the space: its name as the title, 28 pt rows with 16 pt glyphs
  (filled when current), group headings 11 pt semibold, an 8 pt brand-tinted selection, count
  capsules (quiet, amber when they ask for action). It slides shut for Home and Network.
- Content: an opaque card inset 8 pt from the frame, corner 14, hairline, no shadow. No
  titlebar row: the page starts at the card's top. Search is the rail's magnifier and ⌘K, Ask is
  in the command bar (⌘J), Privacy sits above Settings in the rail, Quick connect and New
  terminal live in the terminal's tab strip and on ⇧⌘K and ⌘T. Network alone keeps a slim 44 pt
  row for its tabs. The window's top 8 pt, the card's top 12 pt (`TopEdge`), the sidebar header
  and the rail's top drag the window; a double-click there does what Desktop & Dock says
  (`TitlebarArea`). ⌃⌘S or the toggle in the sidebar header hides the source list; clicking the
  current space in the rail brings it back.
- The page on the `bg` canvas with the space's hue as a breath of colour at the top (`SpaceWash`).
- Bottom status line (only when it has something): live facts and running jobs.

## Spaces (hue)

Home 195 · Apps 245 · Cleanup 165 · Protection 290 · Network 215 · System 35 · Developer 265 ·
Extensions 320. Each space's hero object (`HeroArt`) is rim-lit in its hue.

## The mark

A moon setting into a calm sea: a warm moon on the horizon and three lines of light below it, each
shorter than the last, the way the tide goes out and shows what was underneath. The app icon
(`Icon/AppIcon.icon`: moon and tide layers on a night-ocean gradient, glass by the system), the
rail logo (`Resources/logo.svg`) and the menu bar template (`Resources/menubar.svg`) are the same
drawing. Nothing else in the app uses it.

## Glyphs and art

Lowtide's own glyph set (`NavIcon`, 24 grid, 1.5 stroke, outline and filled-when-selected) for
every space, page, action and Settings pane; SF Symbols only for utility glyphs. One meaning per
glyph; no decorative icons next to text. Hero objects (`HeroArt`) are graphite glass slabs with
the space's mark embossed.

## Page anatomy

1. Hero: `HeroGlyph` (the space's object, rim-lit in its hue) + one sentence that answers the
   question ("35 apps online, all behaving"), one line of detail, one primary action.
2. A `PageToolbar` row when the page has views or filters (`Segmented`, `FilterField`).
3. Groups as `Pane`s / `.card()`s, lists inside them, 20 pt between groups, page margins 28 pt.

Instrument pages (the live map, Packets, DNS, Localhost, Processes, the terminal) give the room
to the instrument. The live map is one flat plane with the page: drawn on the canvas, its grid
fading out at the edges, the summary (sentence, numbers, action) at its top left and its views
and tools at the top right with no cards under them; the side column is a flush pane behind a
hairline and hides with ⌥⌘0. Small controls over a canvas use `.flatSurface()`. List pages use the one-row `PageHeader(compact: true)`.
Full screen on the terminal or the map is immersive: no rail, sidebar, tabs row or status line.
4. Every state designed: loading (`ScanningState`), empty (`EmptyState` with the one thing to do),
   error (`ErrorState` with retry), partial (what's known so far, with progress).

## Colour

Roles from the theme (`palette`): `bg` canvas · `panel` chrome · `surface` raised groups ·
`overlay` popovers/sheets/toasts · `fill` inputs and quiet capsules · `hover` / `selected` /
`selectedBrand` · `line` / `lineStrong` hairlines · `ink`…`ink4` text (ink4 only placeholder or
disabled) · `brand` primary action, selection, focus, links · `ok` healthy · `warn` act (amber) ·
`bad` broken or destructive (red, never decoration) · `terminal`.
A state colour always comes with a word or an icon. Themes: Automatic (Situation dark / Paper light)
plus Graphite, Arctic, Amber, Crimson, Phosphor and imported theme files (the format of `Resources/themes`).

## Type (SF, macOS sizes)

11 counts/kbd · 12 meta/labels · 13 body · 14 command bar rows · 15 row titles · 17 sheet/pane titles · 22 page titles ·
26 a hero's sentence · 36 big hero numbers. SF Mono only for code, paths, hosts, versions, numbers in
columns. Figures that line up: `.monospacedDigit()`.

Calm, not loud: on dark themes the main text is about 91% light (macOS's own #E4E5E5), never pure
white, which glows and reads as bold on a dark ground; secondary text a step below. Buttons and
links are regular weight, a selected segment medium; semibold only for headings and titles. A
setting's hint is 11 pt under its 13 pt label.

## The command bar

One fixed frame, 750 × 474 (680 × 440 as ⌘K in the window): the field (56, 17 pt text, "Ask ⌘J"
on the right), the views as chips, the list filling the rest, the footer (where you are, ↵ and ⌘K).
Typing never resizes it. Corners 16 continuous; rows 40 with 8 pt corners inside an 8 pt inset, so
the shapes nest; 24 pt icons. A frosted backdrop with the theme's panel colour over it (the Glass
setting thins it) and a hairline edge, lighter at the top. It appears at once: no opening motion.

## Shape and depth

Radius 6 chips · 8 controls/rows · 12 lists/panes/popovers · 14 content card · 16 sheets/hero tiles.
Flat by default. `.card()`: surface fill and a hairline ring, no shadow or lit edge. Primary
buttons are solid brand, no gradient. Shadows only on what floats over the page:
`.overlaySurface()` (menus, popovers, toasts, the ⌘K sheet), the command bar, the dictation pill, a
tab being dragged. Never invent a shadow.

## Motion

Spring (response 0.3, bounce 0.15) for things that move to a new place (segmented thumb, sheets);
ease-out 140/220/360 ms for fades; a page change fades in and rises 4 pt in 180 ms. Under Reduce
Motion movement goes, fades stay. Live data animates its numbers (`.contentTransition(.numericText())`).

## Words

Sentence case. Name the thing and the number ("3 updates waiting", "Clear 3.7 GB"). Buttons are
verbs. No "Error:" prefixes; say what happened and what to do. Amber = act, red = broken.
