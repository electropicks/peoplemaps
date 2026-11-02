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
| `glassEffect(_ glass: Glass = .regular, in: some Shape)` | custom floating controls, chips | confirmed in Xcode 27.1 (iOS 27.1 SDK) |
| `Glass.regular`, `.clear`, `.identity`, `.tint(_:)`, `.interactive()` | variants; `.identity` to switch glass off | confirmed in Xcode 27.1 (iOS 27.1 SDK) |
| `GlassEffectContainer(spacing:)` | one per cluster of nearby glass | confirmed in Xcode 27.1 (iOS 27.1 SDK) |
| `glassEffectID(_:in:)`, `glassEffectUnion(id:namespace:)` | morph map buttons between screens | confirmed in Xcode 27.1 (iOS 27.1 SDK) |
| `.buttonStyle(.glass)`, `.buttonStyle(.glassProminent)` | secondary and primary buttons | confirmed in Xcode 27.1 (iOS 27.1 SDK) |
| `scrollEdgeEffectStyle(_:for:)` | soft edge under the sheet's pinned header | confirmed in Xcode 27.1 (iOS 27.1 SDK) |
| `presentationDetents`, `presentationBackgroundInteraction`, `presentationContentInteraction` | the persistent sheet | stable since iOS 16.4; confirmed in Xcode 27.1 |
| `@Environment(\.accessibilityReduceTransparency)`, `\.colorSchemeContrast`, `\.accessibilityReduceMotion` | fallbacks | stable; confirmed in Xcode 27.1 |
| iOS 27 "clear to tinted" glass slider | users can make all glass more opaque | reported in press, unconfirmed |
| Xcode 27 ignores `UIDesignRequiresCompatibility` | no opting out of glass | Apple forums thread 832543 |

`.containerConcentric` was not found in the Xcode 27.1 SDK; `ConcentricRectangle` exists, so use that for
concentric corners (section 3).

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
| `passedRoute` | `#9CB3A3` | `#56725F` | the part of the followed route already driven, drawn 3.5 pt (the route is 5.5) | vs map land 2.0 / 3.3; vs the route ahead 2.0 / 2.6. Below 3:1 in light on purpose: it is a trail, not information, and the width, the puck at its end and the casing say "behind" without colour |
| `panelFill` | elevated `secondarySystemBackground` | same | opaque content cards in the sheet | text uses `label`/`secondaryLabel` |
| `calmBand` | `#3590D0` `#5393A5` `#928A7B` `#C47632` `#D9605F` | same | calm bar, Breezy to Yikes; blue through grey to orange and rose, not green to red, so it doesn't read as safe and unsafe | landed band black text ≥4.5; band vs `panelFill` ≥3 |
| `mapLand`…`mapPath` | unchanged | unchanged | MapLibre style | — |
| Location | `systemBlue` | `systemBlue` | the map marker and Current location row only. The marker always has a white ring and a faint dark halo, so it separates from the green and grey route lines by lightness, not hue (blue vs white ring 4.0 light; marker vs land 3.6 / 4.3 light/dark) | — |

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

Overture's long tail ("thai_restaurant", "shoe_store", "dermatology") reaches its
group through suffix rules in `PlaceCategory`, after the exact table. Without
them 37% of the all-Seattle index fell through to grey Services.

Map markers: the same fill and glyph, drawn from these tokens, on a 1.5 pt ring of
`systemBackground` (2.5 pt with Increase Contrast). All fills clear 3:1 against
`mapLand` in both modes (lowest: calmer 3.9, food 4.0 light). Glyph ratios in dark
mode use `#1C1C1E`; the lowest are nightlife 4.8 and shops 4.9. Ratios above were
computed with the WCAG formula; the Mac session re-checks rendered pixels with
Xcode's Accessibility Inspector.

**Which places show, and when.** At runtime, from the bundled search index; no
generated data. `Core/PlaceMarkers.swift` thins the whole index once, in the
background, so nothing depends on the camera:

| Tier (zoom) | Shows from | Least gap between centres | On the map in all Seattle | On the busiest phone screen |
|---|---|---|---|---|
| 14 | 13.5, where Home's neighbourhood view lands | 96 pt | 1,243 | 24 |
| 15 | 15 | 72 pt | 4,089 | 42 |
| 16 | 16 | 56 pt | 9,472 | 62 |
| 17 | 17 | 44 pt | 16,458 (of 41,901 places) | 57 |

- Best-ranked first, ties by ID, so the result doesn't depend on input order. Rank
  is the search weight, down 20 for Services and 12 for Health, up 6 for Food,
  Coffee and Nightlife: a neighbourhood's first markers are where people go.
- A marker kept at a zoom stays at every zoom above it, so zooming in only adds.
- Bus stops wait for the last tier and rank below everything, so they only fill
  gaps: 17 of the index's 33. Overture files them under `station` with a Link
  station's weight and no category of their own, so they're told apart by name
  (`PlaceMarker.isBusStop`).
- No marker, though search still finds them: buildings, offices, apartments,
  parking, ATMs, lockers and the like.
- Size 20 pt at zoom 14 to 26 pt at 18, zoom-driven. A tier fades in over the last
  0.12 of a zoom. Keep this narrow: a pinch can stop anywhere, and a wide fade leaves
  a whole tier washed out.
- Shown while browsing (home, search, place card). Never over a route preview or
  guidance. The selected place's marker steps aside for its pin.
- A tap within 22 pt of a marker opens the nearest one's place card, after the
  double-tap wait. Long-press still drops a pin.
- **VoiceOver:** map symbols aren't accessible, so up to 24 on-screen markers get an
  element at their position once the map stops ("Tilikum Place Cafe, Restaurant"),
  nearest the middle first. UI tests use the same elements.
- **Never colour alone:** every marker carries its category glyph.

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
shapes are `outer − padding`. Use `ConcentricRectangle` (confirmed in
Xcode 27.1; `.containerConcentric` does not exist) or compute:

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
  **Locate** (`location`; always shown; centres on the user, and explains itself
  in an alert when it can't: permission not asked or denied, outside the map, no
  fix yet) and **Fit** (`viewfinder`; "Fit routes on map" in preview, "Centre on
  this place" on a place, "Fit map to Seattle" on home). About moves into the sheet (home footer "About PeopleMaps"), so
  the cluster stays at two buttons. Each button 44×44, `.glass` style.
- The cluster rides above the sheet's detent and fades out when the sheet is
  at the large detent (Apple Maps behaviour).
- Attribution: "© OpenStreetMap" stays always visible and linked (ODbL),
  and becomes "© OpenStreetMap contributors · Overture Maps Foundation" once
  Overture Places lands (branch `search/overture-places`). `.caption2`, on a small glass capsule just above the sheet's top edge,
  leading. It moves with the detent. At the large detent only the status bar is
  left above the sheet, so the credit moves inside it, pinned at the bottom
  without the capsule. Size capped at `.large`, one line. The credit is positioned
  from the sheet's global frame, never its height: at low stops the system scales
  the sheet (0.86 at about 80 pt, 0.96 at about 100 pt and over) and floats it above
  the screen's edge, so its height doesn't say where its top is. It is a licence
  term: `testPeekHoldsItsContentAndLeavesTheCreditVisible` holds it above the sheet.
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
`interactiveDismissDisabled()`. Peek = search field + Favourites row, plus the
sheet content's own padding (20 top, 12 bottom), or the last of it is cut off.
Recents and About stay out of sight at the peek: on a taller peek the system leaves
room for the home indicator, and the next row would show half cut off there.
- Search field labelled **"Where to?"**, capsule, `magnifyingglass` leading.
- **Favourites row**, as in Apple Maps: a horizontal row of 56-pt circular
  category badges (`@ScaledMetric`), each with the place's short name
  (`Place.shortName`) in `.caption` under it, up to two lines, centred. Tapping a
  badge opens the place card; long-press removes it, and Edit opens a list with
  swipe to delete. The row ends in an **Add** badge: `plus` on a `systemGray5`
  fill, label "Add", which raises the sheet to `.large` with the search field
  focused; picking a result there favourites it. The row is hidden until there is
  a favourite (owner, 1 November 2026): the star on a place card adds the first.
  No `panelFill` group: the badges sit on the sheet, like Apple Maps.
- **Recents** below, a vertical `panelFill` list with category badges,
  visible from the medium detent. No Featured places (ux-round-1). Empty
  first launch shows one line instead: "Search a place or address, or
  long-press the map" (D4).
- Footer row "About PeopleMaps" (`info.circle`), secondary.

```
╭────────────────────────────╮
│          ───               │
│ ( 🔍 Where to?           ) │
│ Favourites                 │
│  (🍃)    (☕)    (＋)       │  ← peek ends here
│  Gas     Milstead  Add     │
│  Works                     │
│ Recents                    │
│ ┌────────────────────────┐ │
│ │ (☕) Milstead & Co.    › │ │
│ │      Café · Fremont      │ │
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

Proposed (with `ux-round-1` content): sheet sized to fit the card, so medium
doesn't leave half of it empty; large at accessibility sizes.
- Header: 44-pt category badge, name `.title2.bold()`, "Restaurant ·
  Fremont" `.subheadline`. Trailing: favourite (`star`/`star.fill`) and close
  (`xmark`) as small bordered circular buttons (not glass: they sit on
  glass).
- Address line, or "Near 3400 Fremont Ave N".
- **Directions**: full-width `.glassProminent`, `.tint(.directionsFill)`,
  label `directionsText`, mode symbol leading. Two lines that describe what Start
  would take: "Calmer: 12–14 min, 3.4 mi" and "Meh → Breezy, mostly fewer
  unsignalled lefts", or "9–11 min, 2.9 mi" and "Chill, best balance we found"
  with no calmer route (`Docs/STRESS_MODEL.md`, Calm score). "Estimate, no live
  traffic" stays under it.
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
4. **Extra time**: `Picker(.menu)` row "Most extra time for a calmer route: 10 min ›"
   at the medium detent (D5); full segmented at the large detent and in
   landscape.
5. **"Calmer means: Default ›"** row (`slider.horizontal.3`), directly under
   extra time. Shows "Custom" when any preference differs from default.
6. Route cards in one `panelFill` group: Calmer first, Fastest second. Each
   card: 4-pt colour bar (`calmer`/`fastest`), title + "12 min · 5.2 km",
   benefit line in `calmerText` for Calmer, "Estimate, no live traffic" for
   Fastest, checkmark on the selected one. Selecting a card morphs the map
   line opacity (existing code).
7. **Start**: `.glassProminent` tinted, pinned under the scroll, with a bordered
   **Why this route** capsule beside it (D13: green is not a link colour), stacked
   at accessibility sizes. Pinned because a row below Start got clipped at the
   default size. Default stop is 0.66 of the screen, so routes and both buttons
   show without scrolling; accessibility sizes open large.
8. **Calm bar**, in Why this route and at the preview's large stop: the five bands
   left to right with their words, the landed band highlighted, a marker each for
   fastest (above) and calmer (below), no number axis, scores in text. One row per
   level at accessibility sizes.

```
╭────────────────────────────╮
│ Directions              ✕  │
│ ┌────────────────────────┐ │
│ │ ◉ Current location     ⇅│ │
│ │ ● Gas Works Park        │ │
│ └────────────────────────┘ │
│ [🚗 Drive|🚲 Cycle|🚶 Walk] │
│ Extra time: 10 min       ›  │
│ ⚙ Calmer means: Default  ›  │
│ ┌────────────────────────┐ │
│ │▌Calmer 12 min · 5.2 km ✓│ │
│ │▌Avoids 2 unsignalled…   │ │
│ │▏Fastest 12 min · 5.2 km │ │
│ │▏Estimate, no live traffic│ │
│ └────────────────────────┘ │
│ (    Start    ) (Why this route) │
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

Each row: symbol (`light.beacon.max`, `octagon`, `arrow.turn.up.left`,
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
  `light.beacon.max` + text in `calmerText` semibold (see 2, "On glass").
- **Mute, compass + overview**: one horizontal glass capsule (vertical in
  landscape), trailing, same row as the chip: three 44×44 plain buttons with
  dividers. The compass turns with the map's heading and, in the overview,
  only leaves the overview. Banner, chip and buttons share one
  `GlassEffectContainer` so they merge/morph as the chip appears.
- **Rerouting**: same banner, "Finding a calmer way…" with a spinner; copy
  unchanged.
- **Trip bar**: glass, bottom. Arrival · min left · distance left, End as a
  `.bordered` capsule button (destructive role, red tint; not glass, since it
  sits on glass), caption "Estimate,
  no live traffic" below. At accessibility sizes the three stats stack.

Landscape: one leading glass card (banner, chip, trip stats, End), buttons
trailing, as today but glass. Width `min(cardWidth, 40% of width)`, where
`ExploreView` passes `cardWidth` = 330 (D6).

At accessibility sizes the chrome's type stops growing at `accessibility2`: the
banner and the stacked trip bar together fill the screen at larger sizes, which
would push mute, compass and overview off it. Secondary text on glass uses
`.primary` at 75% opacity, because `.secondary` measures under 4.5:1 there.

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

#### Map marker and route line while guiding

- **Marker.** Outside guidance: a blue dot with a white ring; with a known
  heading it gains a beam and a small rim triangle, without one it stays a
  plain dot (no direction is invented). Nothing outside guidance supplies a
  heading yet, so today it is always the dot. During guidance: a blue arrow
  (chevron with a notch, 34 pt, white 3.5 pt outline, dark halo) pointing along
  the course, replacing the dot once a course is known and keeping the last
  course while stopped.
- **Route line.** The line splits at progress: behind is `passedRoute`, 3.5 pt
  (casing 6), ahead keeps the route colour at 5.5 pt. Colour is not the only
  cue: width and the marker at the join carry it. Only the two shapes are
  replaced, every 4 m, so the style is never rebuilt; a reroute starts at
  zero.

### 4.8 Arrival

Current: opaque bottom sheet, green check, notes list, Done
(`nav-arrived.png`).

Decided, not the returning sheet: a bottom glass card inside `GuidanceView`, no
grabber. Check badge (`directionsFill`), "You've arrived at Gas Works Park",
summary line, trip notes in a `panelFill` group, **Done** as `.glassProminent`
tinted `directionsFill`, "Times are estimates. No live traffic." and the voice
tip. `.sensoryFeedback(.success)` fires on arrival.

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
  already does this).
- Camera: every programmatic move goes through `SeattleMap.move`. A move
  within three-quarters of a screen glides (0.5 s ease); a longer one, or one
  that changes zoom by more than 2.5 levels, flies (`fly(to:)`, 1 to 1.8 s)
  so tiles load at a coarse zoom on the way. Reduce Motion: short moves cut,
  long ones dip the map out and in (about 0.4 s) instead of sweeping.
  `--ui-testing` cuts. Sheet padding is applied once the sheet stops moving
  (0.3 s), never per frame. Content-inset changes ease; they never snap.
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
  preference segmented controls move under their label. The Favourites row
  scrolls horizontally at accessibility sizes, with names wrapping to two
  lines.
- **VoiceOver order**: home: search field, favourites (each "Gas Works
  Park, park"), the Add badge ("Add a favourite"), recents, About, then
  map controls (locate, fit), then the map. Preview: close, from, to, swap,
  mode, extra time, Calmer means, calmer card, fastest card, Start, Why this
  route. Guidance: banner (distance + instruction + then), calm note, trip
  stats, End, mute, overview. Use `accessibilitySortPriority` on the sheet so
  it comes before the map controls. Category badges are hidden; the category
  word is in the row label.
- **Contrast**: 4.5:1 for all text (table in section 2), 3:1 for route lines
  and badges against the map.
- Every control keeps its current `accessibilityIdentifier` so UI tests keep
  working; new controls get one (`locate`, `add-favourite`, `extra-time-menu`,
  `route-preferences`, `preference-<factor>`, `reset-preferences`).

## 6a. Glass audit, November 2026

Every floating surface against section 1, from captures in both appearances, on the
all-Seattle map.

| Surface | Glass | Finding |
|---|---|---|
| Sheet | system, no custom background | Real glass. Markers beneath it blur through as soft colour, as they should. |
| Map buttons (home, guidance) | `.regular` | Was inert under the finger. Now `.interactive()`. |
| Credit | `.regular` | Text only, so not interactive. Was hidden behind the sheet; now above it. |
| Turn banner, calm chip, trip bar, arrival card | `.regular` in one container | Fine. Reading text stays short or on `panelFill`. |
| Re-centre pill | `.glass` button | Fine: over the map, not on the sheet. |
| Landscape card | `.regular` | Fine. Lists are on `panelFill`. |
| Directions, Start, Done | `.glassProminent` in the sheet | The one allowed glass-in-glass: the primary action (principle 6). |
| Reduce Transparency | `floatingSurface` | Map buttons and credit vanished in dark mode, `panel` being nearly `mapLand`. The outline guidance had in its own copy of this helper is now in the helper. |

Where glass reads milky in light mode, it's the pale land under it: glass takes its
colour from what's behind. The map palette decides that, not the glass.

## 7. Implementation plan

Small PRs into `main`, in order, each passing `Scripts/verify.sh --ui` on a
Mac with screenshots per the `simulator-evidence` skill (light, dark,
landscape unless noted). Base each on the latest `main` after `ux-round-1`.

1. **iOS 27 deployment target (done).** `Scripts/generate_project.py`
   (`IPHONEOS_DEPLOYMENT_TARGET` is `27.0`) and `Package.swift`
   (`.iOS("27.0")`); the project is regenerated. No `#available(iOS 26, *)`
   checks remain outside `App/ExploreView.swift` and `App/Navigation/`.
   Evidence: verify summary only, no visual change.
2. **Tokens and category model.** `Core/PlaceCategory.swift` (raw category →
   group, symbol), `Tests/PlaceCategoryTests.swift` (every category in the
   current index maps; unknown → services), category colours in
   `App/PeoplemapsApp.swift`, `AccentColor` asset, `App/Neighbourhoods.swift`
   (`symbol` moves to `PlaceCategory`). Evidence: search results light/dark.
3. **Persistent sheet.** `App/ExploreView.swift` (portrait panel → system
   sheet with detents, landscape card keeps a leading floating card on glass),
   remove decorative grabber and `panelHeight` plumbing where the sheet
   reports it), plus the horizontal Favourites row with its Add badge.
   Evidence: home at each detent with and without favourites, landscape,
   AX3 type, Reduce Transparency.
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

## 8. Decided 30 October 2026

1. **Peek detent:** search field plus the Favourites row (4.2).
2. **Parks colour:** teal-green `#0B7A6B`, so green means only "calmer".
3. **About:** moves from the map buttons to the home sheet's footer.
4. **Extra time:** a menu at the medium detent; segmented at the large
   detent and in landscape.
5. **iPad:** iPhone only for now.
