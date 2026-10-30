# Design spec: Liquid Glass, colour and iOS 27

Drafted 30 October 2026. Written spec only; nothing in `App/` is changed yet.
A Mac session builds from it after `ux-round-1` merges, because the redesign
touches every `App/` file. Read with `.claude/skills/product-rules/SKILL.md`,
`Docs/RESEARCH_UX_2026.md` (gaps D1–D13), `Docs/NAVIGATION.md` and
`Docs/SEARCH.md`.

Decided, not open: Apple standards, Liquid Glass first, category colours for
place types, green (`.calmer`) stays the calmer-route colour, minimum
deployment target iOS 27.

## 0. Sources and what is unconfirmed

Apple's developer site renders with JavaScript and the container proxy blocks
most third-party guides, so the API names below come from the iOS 26 SDK as
documented at WWDC25 and could not be re-read for iOS 27. **Before writing
code, the Mac session checks each name in Xcode 27's documentation** and
records anything renamed in the PR.

| API (iOS 26 SDK) | Use here | Status |
|---|---|---|
| `glassEffect(_ glass: Glass = .regular, in: some Shape)` | custom floating controls, chips | confirm |
| `Glass.regular`, `.clear`, `.identity`, `.tint(_:)`, `.interactive()` | variants; `.identity` to switch glass off | confirm |
| `GlassEffectContainer(spacing:)` | one per cluster of nearby glass | confirm |
| `glassEffectID(_:in:)`, `glassEffectUnion(id:namespace:)` | morph map buttons between screens | confirm |
| `.buttonStyle(.glass)`, `.buttonStyle(.glassProminent)` | secondary and primary buttons | confirm |
| `scrollEdgeEffectStyle(_:for:)` | soft edge under the sheet's pinned header | confirm |
| `presentationDetents`, `presentationBackgroundInteraction`, `presentationContentInteraction` | the persistent sheet | stable since iOS 16.4 |
| `@Environment(\.accessibilityReduceTransparency)`, `\.colorSchemeContrast`, `\.accessibilityReduceMotion` | fallbacks | stable |
| iOS 27 "clear to tinted" glass slider | users can make all glass more opaque | reported in press, unconfirmed |
| Xcode 27 ignores `UIDesignRequiresCompatibility` | no opting out of glass | Apple forums thread 832543 |

Partial-height system sheets get a glass background on iOS 26+ automatically;
a custom `presentationBackground` replaces it. We rely on the system
behaviour and never set our own sheet background.

## 1. Principles

1. **Two layers.** The map is content. Everything that floats over it is the
   navigation layer: the sheet, the map control cluster, the guidance banner,
   chips and trip bar. Only the navigation layer is glass.
2. **Glass holds controls, not reading.** Buttons, the search field, segmented
   pickers, the turn arrow and short labels can sit straight on glass. Lists,
   route cards, explanations and anything over two lines sit on an opaque
   grouped surface (`.panelFill`) inside the sheet, so their contrast is
   measured against a known colour, not whatever map is underneath.
3. **No glass on glass.** A glass button inside the glass sheet uses
   `.bordered`/plain styles, not `.glass`. One `GlassEffectContainer` per
   cluster (map buttons; guidance top chrome; trip bar).
4. **Regular, not clear.** We use `Glass.regular` everywhere. `.clear` needs a
   dimming layer and our map is busy; it is not used.
5. **One accent, plus category colour.** Green means "the calmer route" and the
   primary action (Directions, Start, Done). Nothing else is green: not links,
   not toggles, not parks. Category colours appear only on place badges (list
   rows, map markers, place card); they never tint glass, text or buttons.
6. **Tint sparingly.** Only primary actions are tinted glass
   (`.glassProminent` with `.tint(.calmer)`). Never tint the sheet or banner.
7. **Honest words survive the redesign.** Every "Estimate", "unknown" and
   source/date line in the current UI stays. No screen says "safe".

## 2. Colour tokens

All tokens live in `App/PeoplemapsApp.swift` (`UIColor` + `ShapeStyle`
extensions) as today; the redesign adds the category set and an
`AccentColor` asset that matches `.calmer`. Values are sRGB.

### Semantic

| Token | Light | Dark | Use | Contrast |
|---|---|---|---|---|
| `calmer` | `#248A3D` | `#30D158` | calmer route line, selected-route bar | line vs map land 3.9 / 8.6 (≥3:1 graphic) |
| `calmerText` | `#1F7A3A` | `#30D158` | green text, turn arrow | 4.8 / 6.9 on `panelFill` |
| `directionsFill` | `#1F7A3A` | `#30D158` | primary button fill / glass tint | label 5.4 white / 10.4 black |
| `directionsText` | white | black | label on the above | as above |
| `fastest` | `#8E8E93` | `#8E8E93` | fastest line and bar | graphic only |
| `panelFill` | elevated `secondarySystemBackground` | same | opaque content cards in the sheet | text uses `label`/`secondaryLabel` |
| `mapLand`…`mapPath` | unchanged | unchanged | MapLibre style | — |
| Location | `systemBlue` | `systemBlue` | puck and Current location row only | — |

Removed: the hard-coded arrival circle colour in `GuidanceView`
(`Color(red: 0x1F…)`) becomes `.directionsFill`. `panel` (opaque sheet
background) goes away with the hand-drawn panel; it remains only as the
Reduce Transparency fallback (section 6).

### Place categories

Ten groups. Each place's raw `category` (from `Scripts/build_search.py`
`category_of`, stored in `entries.category` and read by `Core/SearchIndex.swift`)
maps to one group in a new `PlaceCategory` enum in `Core` (pure Swift, unit
tested, so the mapping is shared and not in a view). Badge = SF Symbol on a
filled circle. Light mode: white glyph on the light fill. Dark mode: glyph
`#1C1C1E` on the brighter dark fill (white on the bright dark fills drops
under 3:1).

| Group | Raw categories (top ones in the Oct 2026 index) | Symbol | Light fill | Dark fill | Glyph:fill L / D | Fill:panelFill L / D |
|---|---|---|---|---|---|---|
| Food | restaurant, fast_food, bakery, deli, ice_cream, pastry | `fork.knife` | `#C75300` | `#FF9F0A` | 4.5 / 8.3 | 4.0 / 6.8 |
| Coffee | cafe | `cup.and.saucer.fill` | `#8A5A2B` | `#C8935A` | 5.9 / 6.3 | 5.3 / 5.2 |
| Nightlife | bar, pub, nightclub, wine, alcohol | `wineglass.fill` | `#8E3FC0` | `#BF5AF2` | 5.8 / 4.8 | 5.2 / 4.0 |
| Shops | any `shop=*` not above: clothes, convenience, supermarket, books, gift, furniture… | `bag.fill` | `#4B49C8` | `#7D7AFF` | 6.8 / 4.9 | 6.1 / 4.0 |
| Parks and nature | park, garden, wood, water, playground, nature_reserve, beach, dog_park | `leaf.fill` | `#0B7A6B` | `#3CC9B0` | 5.2 / 8.2 | 4.7 / 6.8 |
| Sport | fitness_centre, sports_centre, pitch, stadium, swimming_pool | `figure.run` | `#00728F` | `#40C8E0` | 5.5 / 8.6 | 4.9 / 7.0 |
| Transit and travel | station, halt, ferry_terminal, bicycle_parking, parking, fuel, charging_station, marina, hotel | `tram.fill` (station/halt), `ferry.fill`, `bicycle`, `parkingsign`, `fuelpump.fill`, `bolt.car.fill`, `bed.double.fill` | `#0064D2` | `#409CFF` | 5.6 / 6.0 | 5.0 / 4.9 |
| Sights and culture | attraction, museum, viewpoint, gallery, artwork, memorial, monument, historic, theatre, arts_centre, cinema, library | `building.columns.fill` (museum), `binoculars.fill` (viewpoint), `theatermasks.fill`, `books.vertical.fill`, `paintpalette.fill`, `star.fill` (others) | `#C2185B` | `#FF6482` | 5.9 / 6.0 | 5.3 / 4.9 |
| Health | clinic, doctors, dentist, pharmacy, hospital, veterinary | `cross.case.fill` | `#D70015` | `#FF6961` | 5.4 / 6.0 | 4.8 / 4.9 |
| Services and other | bank, atm, hairdresser, beauty, office, craft, building, school, place_of_worship, post_office, community_centre, everything unmapped | `mappin` (plus `building.2.fill` for building/office) | `#6C6C70` | `#AEAEB2` | 5.2 / 7.7 | 4.7 / 6.3 |

Fixed kinds keep their own look: Current location (blue circle,
`location.fill`), address (`Services` grey, `mappin`), dropped pin (`mappin`,
`systemRed` fill, as Apple's convention for a dropped pin).

Parks deliberately use teal-green `#0B7A6B`, not `.calmer`, so a green badge
is never mistaken for "calmer". The hue gap is about 40°; the symbol (leaf)
carries the meaning too. See open question 2.

Map markers: the same fill and glyph at 24 pt (28 pt selected, with a 2 pt
`systemBackground` ring). All fills clear 3:1 against `mapLand` in both modes
(lowest: calmer 3.9, food 4.0 light). Glyph ratios in dark mode use `#1C1C1E`; the
lowest are nightlife 4.8 and shops 4.9. Ratios above were computed with the WCAG
formula; the Mac session re-checks rendered pixels with Xcode's Accessibility
Inspector.

### On glass

Glass has no fixed colour, so text contrast on it can't be precomputed. Rules:
only `label`/`secondaryLabel` and SF Symbols in `.primary` go directly on
glass (the system adapts them); `calmerText` on glass is allowed only for the
turn arrow and the calm-note chip, at semibold weight, and must be checked on
four screenshots: light/dark over the lightest map (water `#D7E6EC`) and the
darkest (`#1A1A1C`). If any fails 4.5:1, the chip gets a `panelFill` capsule
behind its text inside the glass.

## 3. Type, spacing, shapes, symbols

**Type.** System text styles only, Dynamic Type everywhere. Sheet headers
`.title2.bold()`; place name `.title2.bold()`; row title `.body`; row
subtitle `.subheadline` secondary; source/date line `.caption` secondary;
section headers `.footnote.weight(.semibold)` secondary, sentence case (drop
the uppercase headers, matching iOS 26+ lists). Changing numbers
`.monospacedDigit()`. No `minimumScaleFactor` below 0.8; at accessibility
sizes layouts reflow instead (trip bar stacks vertically, D6).

**Spacing.** 4-pt grid. Sheet content inset 16 (landscape card 12). Row min
height 52 (`@ScaledMetric`). Gap between groups 20; inside a group 8. Map
control cluster 16 from the edges and the safe area.

**Corner radii, concentric.** Outer shapes follow the device corner; inner
shapes are `outer − padding`. Use `ConcentricRectangle` / `.containerConcentric`
if Xcode 27 has it (iOS 26 SDK name, confirm); otherwise compute:

| Shape | Radius |
|---|---|
| Sheet / landscape card | system sheet radius (don't set it) |
| Content group inside sheet (16 inset) | 26 → use 22 if the sheet reports ~38 |
| Row badge | circle, 32 pt (`@ScaledMetric`) |
| Buttons, search field, chips | capsule |
| Map control cluster | capsule (vertical) |

Capsules replace today's 12-pt rounded rectangles on buttons and the search
field; that is the Liquid Glass look.

**Symbols.** SF Symbols, `.fill` variants on badges and map buttons, outline
elsewhere. Map controls: `location` / `location.fill` (follow), `viewfinder` (fit). Mode picker: `car.fill`,
`bicycle`, `figure.walk`. Route preferences row: `slider.horizontal.3`.
Maneuvers stay as in `GuidanceOverlay.symbol`. Symbol changes animate with
`.contentTransition(.symbolEffect(.replace))`, opacity under Reduce Motion.

## 4. Screens

Each screen lists current (from `Evidence/`) and proposed. Every screen ships
in light, dark, portrait and landscape.

### 4.1 Map chrome and attribution

Current: `info.circle` + `viewfinder` in a `.regularMaterial` rounded rect
with a shadow, top right; "© OpenStreetMap" pill bottom left over the panel
(`home-favourites-light.png`).

Proposed:
- One vertical glass capsule, top trailing, in a `GlassEffectContainer`:
  **Locate** (`location`; fills when following; the in-context location
  permission moment, D3) and **Fit** (`viewfinder`, "Fit routes on map" in
  preview). About moves into the sheet (home footer "About PeopleMaps"), so
  the cluster stays at two buttons. Each button 44×44, `.glass` style.
- The cluster rides above the sheet's detent and fades out when the sheet is
  at the large detent (Apple Maps behaviour).
- Attribution: "© OpenStreetMap" stays always visible and linked (ODbL),
  and becomes "© OpenStreetMap contributors · Overture Maps Foundation" once
  Overture Places lands (branch `search/overture-places`). `.caption2`, on a small glass capsule just above the sheet's top edge,
  leading. It moves with the detent; it is never hidden behind the sheet.
- Remove all custom `.shadow` calls on glass; glass draws its own.

```
┌──────────────────────────────┐
│                         ╭──╮ │
│        (map)            │◎ │ │  ◎ locate  ⛶ fit
│                         │⛶ │ │
│                         ╰──╯ │
│ (© OpenStreetMap)            │
│╭────────── sheet ───────────╮│
```

### 4.2 Home: "Where to?"

Current: hand-drawn panel with decorative grabber, "Search places" field,
Favourites and Featured places (`home-favourites-light.png`).

Proposed (with `ux-round-1`): a persistent system sheet,
`presentationDetents([.height(peek), .medium, .large])`,
`presentationBackgroundInteraction(.enabled(upThrough: .medium))`,
`interactiveDismissDisabled()`. Peek = search field + one row.
- Search field labelled **"Where to?"**, capsule, `magnifyingglass` leading.
- Favourites then Recents, each a `panelFill` group with category badges.
  No Featured places (ux-round-1). Empty first launch shows one line:
  "Routes with fewer stressful turns, for a few minutes more." (D4).
- Footer row "About PeopleMaps" (`info.circle`), secondary.

```
╭────────────────────────────╮
│          ───               │
│ ( 🔍 Where to?           ) │
│ Favourites                 │
│ ┌────────────────────────┐ │
│ │ (🍃) Gas Works Park    › │ │
│ │      Park · Wallingford  │ │
│ └────────────────────────┘ │
│ Recents                    │
│ ┌────────────────────────┐ │
│ │ (☕) Milstead & Co.    › │ │
│ └────────────────────────┘ │
│ ⓘ About PeopleMaps         │
```

### 4.3 Search and results

Current: panel grows to 90% with its own field and Cancel; rows have grey
badges; no source line (`search-light.png`, `search-apple-maps-light.png`).

Proposed: tapping "Where to?" raises the sheet to `.large` and focuses the
field; Cancel returns to the previous detent. Results are one `panelFill`
list. Each row:

```
(🍴)  Tilikum Place Cafe                    0.4 mi
      Restaurant · 407 Cedar St
      OpenStreetMap, Oct 2026
```

- Badge from `PlaceCategory`; title `.body`; subtitle as today
  (`Place.subtitle`); distance trailing `.subheadline` secondary,
  monospaced digits.
- **Source and date line**, `.caption` secondary: the row reads
  `place.source`, which the Overture branch (`search/overture-places`) sets
  per row in `Core/SearchIndex.swift` ("OpenStreetMap, Oct 2026" or
  "Overture (Foursquare), Oct 2026"). Addresses show it too.
- VoiceOver reads one element: "Tilikum Place Cafe, restaurant, 407 Cedar St,
  0.4 miles, OpenStreetMap, October 2026".
- No results: `ContentUnavailableView` with today's copy, then the "Look up in
  Apple Maps" row (plain grey badge `map`, `arrow.up.forward`), unchanged
  wording. Nothing from Apple is shown in the app.
- `scrollEdgeEffectStyle(.soft, for: .top)` under the pinned field.

### 4.4 Place card

Current: name, subtitle, favourite and close buttons, green Directions,
footnote (`place-light.png`).

Proposed (with `ux-round-1` content): sheet at `.medium`.
- Header: 44-pt category badge, name `.title2.bold()`, "Restaurant ·
  Fremont" `.subheadline`. Trailing: favourite (`star`/`star.fill`) and close
  (`xmark`) as small bordered circular buttons (not glass: they sit on
  glass).
- Address line, or "Near 3400 Fremont Ave N".
- Time line: "12 min by car · calmer route adds about 1 min" then the main
  benefit in `calmerText`: "Avoids 2 unsignalled lefts". "Estimate, no live
  traffic" stays.
- **Directions**: full-width `.glassProminent`, `.tint(.directionsFill)`,
  label `directionsText`, `car.fill` leading.
- Source/date line at the bottom.
- Outside coverage: the existing "Outside the area we cover yet" group,
  unchanged copy, `exclamationmark.triangle` in secondary.

### 4.5 Route preview

Current: places group, mode segmented, extra-time segmented with a caption,
calmer and fastest rows, Start, "Why this route" in green
(`redesign-portrait-dark.png`).

Proposed, top to bottom:
1. Header row: "Directions" `.headline` + close.
2. From / To group (`panelFill`): origin row (Current location, or empty
   "Choose start" in secondary with `location` badge when denied, per
   `ux-round-1`), destination row, swap button trailing.
3. **Mode picker**: segmented, order **Drive, Cycle, Walk**, each with its
   symbol and text (icon-only fails at large type). `.sensoryFeedback(.selection)`.
4. **Extra time**: `Picker(.menu)` row "Extra time for a calmer route: 5 min ›"
   at the medium detent (D5); full segmented at the large detent and in
   landscape.
5. **"Calmer means: Default ›"** row (`slider.horizontal.3`), directly under
   extra time. Shows "Custom" when any preference differs from default.
6. Route cards in one `panelFill` group: Calmer first, Fastest second. Each
   card: 4-pt colour bar (`calmer`/`fastest`), title + "12 min · 5.2 km",
   benefit line in `calmerText` for Calmer, "Estimate, no live traffic" for
   Fastest, checkmark on the selected one. Selecting a card morphs the map
   line opacity (existing code).
7. **Start**: `.glassProminent` tinted, full width. "Why this route ›" becomes
   a plain `label`-coloured row (D13: green is not a link colour).

```
╭────────────────────────────╮
│ Directions              ✕  │
│ ┌────────────────────────┐ │
│ │ ◉ Current location     ⇅│ │
│ │ ● Gas Works Park        │ │
│ └────────────────────────┘ │
│ [🚗 Drive|🚲 Cycle|🚶 Walk] │
│ Extra time: 5 min        ›  │
│ ⚙ Calmer means: Default  ›  │
│ ┌────────────────────────┐ │
│ │▌Calmer 12 min · 5.2 km ✓│ │
│ │▌Avoids 2 unsignalled…   │ │
│ │▏Fastest 12 min · 5.2 km │ │
│ │▏Estimate, no live traffic│ │
│ └────────────────────────┘ │
│ (        Start           ) │
│ Why this route           › │
```

### 4.6 Route preferences sheet ("Calmer means")

A second sheet on top of the persistent one, `.medium` and `.large`,
title "Calmer means" with the current mode in the subtitle ("Driving"). One
`Form`, inset grouped. Mode-specific rows only (`Docs/STRESS_MODEL.md`: don't
apply one mode's rule to another):

| Factor | Drive | Cycle | Walk |
|---|---|---|---|
| Traffic lights | ✓ | ✓ | ✓ (crossings) |
| Stop signs | ✓ | ✓ | Unsignalled crossings |
| Unsignalled lefts | ✓ | ✓ | Unsignalled crossings |
| Busy streets | ✓ | ✓ | ✓ |
| Hills | ✓ | ✓ | ✓ |
| Turns | ✓ | ✓ | ✓ |

Walk has no stop signs or lefts in the stress model; it has unsignalled and
unmarked crossings instead, shown as one "Unsignalled crossings" row in place
of those two. Confirm the per-mode set against the route-preferences PR before
building; the table is a starting point.

Each row: symbol (`trafficlight`, `octagon`, `arrow.turn.up.left`,
`car.2.fill`, `mountain.2`, `arrow.triangle.turn.up.right.diamond`), label,
and a three-way segmented control **Avoid / Normal / Don't mind**. At
accessibility sizes the control drops below the label. Changes recompute the
comparison live behind the sheet.

Footer: **Reset to defaults** (plain button, disabled when already default),
then the note **"Times stay estimates."** `.footnote` secondary. Done in the
toolbar (`.confirmationAction`). No "safe", no scores.

```
╭────────────────────────────╮
│ Calmer means         Done  │
│ Driving                    │
│ 🚦 Traffic lights           │
│   [Avoid|Normal|Don't mind]│
│ 🛑 Stop signs               │
│   [Avoid|Normal|Don't mind]│
│ …                          │
│ Reset to defaults          │
│ Times stay estimates.      │
```

### 4.7 Guidance

Current: opaque white turn card with "Then:" strip, calm chip, square
material buttons, opaque trip bar (`nav-guidance-light.png`).

Proposed (portrait): the persistent sheet is hidden; guidance owns the
screen.
- **Turn banner**: glass, top, full width minus 8. Arrow in `calmerText`,
  distance `.largeTitle.bold()`, instruction `.title3.semibold`. The "Then:"
  row sits inside the same glass with a hairline divider, not a second fill
  (no glass on glass, no opaque strip).
- **Calm chip** below the banner, leading: glass capsule, `octagon` /
  `trafficlight` + text in `calmerText` semibold (see 2, "On glass").
- **Mute + overview**: a horizontal glass capsule, trailing, same row as the
  chip; banner, chip and buttons share one `GlassEffectContainer` so they
  merge/morph as the chip appears.
- **Rerouting**: same banner, "Finding a calmer way…" with a spinner; copy
  unchanged.
- **Trip bar**: glass, bottom. Arrival · min left · distance left, End as a
  `.glass` capsule button (destructive role, red label), caption "Estimate,
  no live traffic" below. At accessibility sizes the three stats stack.

Landscape: one leading glass card (banner, chip, trip stats, End), buttons
trailing, as today but glass. Width `min(360, 40% of width)` instead of fixed
330 (D6).

```
┌──────────────────────────────┐
│╭────────────────────────────╮│
││ ↱  0.7 mi                   ││
││    Turn right onto McGraw St││
││ ─────────────────────────── ││
││ Then: ↰ left onto 1st Ave N ││
│╰────────────────────────────╯│
│(⬡ Stop sign)        (🔊 ⤢)   │
│            (map)             │
│╭────────────────────────────╮│
││ 8:32 PM  12 min  3.0 mi (End)││
││ Estimate, no live traffic    ││
│╰────────────────────────────╯│
```

### 4.8 Arrival

Current: opaque bottom sheet, green check, notes list, Done
(`nav-arrived.png`).

Proposed: the persistent sheet returns at `.medium` with the arrival content:
check badge (`directionsFill`), "You've arrived at Gas Works Park", summary
line, trip notes in a `panelFill` group, **Done** as `.glassProminent`, "Times
are estimates. No live traffic." and the voice tip. `.sensoryFeedback(.success)`.

### 4.9 About and Acknowledgements

Current: `RouteDetails.swift` About sheet with stale copy ("route-comparison
prototype, not turn-by-turn navigation", D12).

Proposed: reached from the home footer row. Standard `NavigationStack` +
inset grouped `List` in a `.large` sheet (system glass toolbar). Sections:
"What calmer means" (one paragraph, the mode list), "Data" (OpenStreetMap
ODbL link, snapshot date, USGS elevation, and "Overture Maps Foundation" once
Overture Places lands on `search/overture-places`),
"Coverage" (current copy), Acknowledgements (MapLibre, Ferrostar BSD-3, OSM,
USGS). Remove "not turn-by-turn navigation". Links in `label` colour with
`arrow.up.forward`, not green.

## 5. Motion

All through `Motion` (`App/PeoplemapsApp.swift`); no new durations.
- Sheet detent changes are the system's; content inside crossfades with
  `Motion.content`.
- Glass morphs (map cluster, guidance chip appearing) use `glassEffectID`
  inside `withAnimation(Motion.panel(reduce))`.
- Under Reduce Motion: no morphs or slides, crossfade only (`Motion.edge`
  already does this); camera moves cut (`Motion.camera`).
- `--ui-testing`: `Motion.off` keeps everything instant, glass included.
- Haptics (D7): selection on mode/extra-time/preference change, impact on
  Start, success on arrival. `sensoryFeedback` follows the system setting.

## 6. Accessibility

- **Reduce Transparency**: standard glass goes frosted automatically. For our
  custom `glassEffect` views, read `accessibilityReduceTransparency` and use
  `Glass.identity` plus an opaque `.panel` background with the same shape.
  One helper, `View.floatingSurface(in:)`, does both so no view branches by
  hand.
- **Increase Contrast** (`colorSchemeContrast == .increased`): glass gets a
  1-pt `separator` border (system controls do this themselves); `calmer`
  route line widens by 1 pt; category glyphs stay as specified (all
  ≥4.5:1).
- **Dynamic Type**: test at `.large`, `.xxxLarge` and `.accessibility3`.
  Rows wrap, never truncate place names past two lines; trip bar stacks;
  preference segmented controls move under their label.
- **VoiceOver order**: home: search field, favourites, recents, About, then
  map controls (locate, fit), then the map. Preview: close, from, to, swap,
  mode, extra time, Calmer means, calmer card, fastest card, Start, Why this
  route. Guidance: banner (distance + instruction + then), calm note, trip
  stats, End, mute, overview. Use `accessibilitySortPriority` on the sheet so
  it comes before the map controls. Category badges are hidden; the category
  word is in the row label.
- **Contrast**: 4.5:1 for all text (table in section 2), 3:1 for route lines
  and badges against the map.
- Every control keeps its current `accessibilityIdentifier` so UI tests keep
  working; new controls get one (`locate`, `extra-time-menu`,
  `route-preferences`, `preference-<factor>`, `reset-preferences`).

## 7. Implementation plan

Small PRs into `main`, in order, each passing `Scripts/verify.sh --ui` on a
Mac with screenshots per the `simulator-evidence` skill (light, dark,
landscape unless noted). Base each on the latest `main` after `ux-round-1`.

1. **iOS 27 deployment target.** `Scripts/generate_project.py`
   (`IPHONEOS_DEPLOYMENT_TARGET` `17.0` → `27.0`), `Package.swift`
   (`.iOS(.v17)` → `.iOS("27.0")` or `.v27` if the tools version has it; bump
   `swift-tools-version` if needed), regenerate the project. Remove
   `#available(iOS 26, *)` checks if any. Evidence: verify summary only, no
   visual change.
2. **Tokens and category model.** `Core/PlaceCategory.swift` (raw category →
   group, symbol), `Tests/PlaceCategoryTests.swift` (every category in the
   current index maps; unknown → services), category colours in
   `App/PeoplemapsApp.swift`, `AccentColor` asset, `App/Neighbourhoods.swift`
   (`symbol` moves to `PlaceCategory`). Evidence: search results light/dark.
3. **Persistent sheet.** `App/ExploreView.swift` (portrait panel → system
   sheet with detents, landscape card keeps a leading floating card on glass),
   remove decorative grabber and `panelHeight` plumbing where the sheet
   reports it. Evidence: home at each detent, landscape, Reduce Transparency.
4. **Map chrome on glass.** `App/ExploreView.swift` (`mapButtons`, locate
   button, attribution), `App/SeattleMap.swift` (padding from the sheet
   detent, follow mode), `floatingSurface` helper. Evidence: home, preview,
   Increase Contrast.
5. **Rows, search and source line.** `App/PlaceRow.swift`,
   `App/PlacePicker.swift`, `App/AppleMapsLookup.swift` (rows read
   `place.source`; no `Core` change). Evidence: search results,
   no results with Apple Maps hand-off, VoiceOver label in the UI test.
6. **Place card and route preview.** `App/ExploreView.swift`,
   `App/RouteDetails.swift` ("Why this route" colour). Evidence: place card,
   preview at medium and large detents, calmer/fastest selected.
7. **Route preferences sheet.** New `App/RoutePreferencesView.swift`,
   `Core` preference model (per mode, persisted), router hook. Its own PR
   whatever order the feature lands in; if the feature merges before this
   spec is built, restyle only. Evidence: sheet per mode, Custom state,
   AX3 type.
8. **Guidance on glass.** `App/Navigation/GuidanceView.swift`. Evidence:
   guidance, rerouting, arrival, landscape, Reduce Transparency, AX3; re-run
   `motion-frames-*` captures.
9. **About and Acknowledgements.** `App/RouteDetails.swift` (`AboutView`),
   `App/Acknowledgements.swift`. Evidence: About light/dark.
10. **Accessibility pass.** VoiceOver order, sort priorities, haptics, AX3
    screenshots of every screen, `ui-summary.json` refreshed.

Run `python3 Scripts/generate_project.py` in any PR that adds an `App/` file
(2, 7).

## 8. Open questions

1. **Peek detent content:** search field only, or search field plus the first
   favourite? (Spec assumes field + one row.)
2. **Parks colour:** teal-green `#0B7A6B` keeps green for "calmer" only. Fine,
   or would you rather parks be plainly green like Apple Maps?
3. **About placement:** move it from the map buttons into the home sheet's
   footer (spec), or keep an info button on the map?
4. **Extra-time control:** menu at the medium detent and segmented at large
   (spec), or segmented always?
5. **iPad:** iPhone-only for now (as `TARGETED_DEVICE_FAMILY = 1`), or design
   the regular-width sidebar in this round?
