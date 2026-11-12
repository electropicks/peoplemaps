# Design spec: Liquid Glass, colour and iOS 27

Drafted 30 October 2026. Written spec only; nothing in `App/` is changed yet.
A Mac session builds from it after `ux-round-1` merges, because the redesign
touches every `App/` file. Read with `.claude/skills/product-rules/SKILL.md`,
`Docs/RESEARCH_UX_2026.md` (gaps D1–D13), `Docs/NAVIGATION.md` and
`Docs/SEARCH.md`.

Decided, not open: Apple standards, Liquid Glass first, category colours for
place types, a dusk blue (`.calmer`) for the route line, minimum deployment
target iOS 27. The look comes from the owner-approved mockup (November 2026):
`QuietAccent` phone 3 for the route panel and accent, `EvergreenGlass` for home.

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
| `UISheetPresentationController.Detent.backgroundEffect`, `UIGlassEffect(style:)` | the sheet's glass (`SheetGlass`) | iOS 26.1; confirmed in Xcode 27.1 |

`.containerConcentric` was not found in the Xcode 27.1 SDK; `ConcentricRectangle` exists, so use that for
concentric corners (section 3).

Partial-height system sheets draw their own glass, under any
`presentationBackground`, and on a pale map it reads as plain off-white.
`SheetGlass` sets each partial detent's `backgroundEffect` to `UIGlassEffect`,
which lets the map show through; SwiftUI has no modifier for it. An empty
`UIVisualEffect` doesn't remove the panel, so home at rest has no sheet at all
(4.2).

## 1. Principles

1. **Two layers.** The map is content. Everything that floats over it is the
   navigation layer: the sheet, the map control cluster, the guidance banner,
   chips and trip bar. Only the navigation layer is glass.
2. **Glass holds what you glance at; solid holds what you read.** The route
   panel, place card, home and guidance sit straight on glass, split by hairlines,
   with no opaque cards. Long reading (Behind the routes, Settings, the large stop)
   is on a solid `panel`. Text on glass is checked from rendered pixels
   (section 2, "On glass").
3. **No glass on glass.** A glass button inside the glass sheet uses
   `.bordered`/plain styles, not `.glass`. One `GlassEffectContainer` per
   cluster (guidance top chrome; trip bar). A single glass
   shape, such as the map buttons on home, needs no container.
4. **Clear, with a veil where it needs one.** `.clear` is what a person reads as
   glass over this pale map: `.regular` frosts it to off-white, which is what the
   owner couldn't see on the phone. Busy-map legibility comes from `glassVeil`
   (`.light`) on text surfaces such as guidance, as Apple asks for `.clear`.
   `--glass-regular` swaps it in Debug builds.
   **Deliberate deviation from Apple, who reserve `.clear` for media-rich
   backgrounds and recommend `.regular` for text:** the guidance turn banner,
   rerouting card, trip bar and landscape card (`legible: true` in
   `floatingSurface`) use `.regular` under the same `glassVeil`, because a route
   line behind the text showed through and these are read at a glance while
   driving. Map buttons, chips and the home capsule stay `.clear`.
   **The sheet is `.regular` under `glassVeil` in both appearances** (home, search, place card,
   preview), and its frost is a `.regularMaterial` in the sheet's presentation background, not
   only the system glass. The owner's phone showed "QUEEN ANNE" and "Lake Union" printing across the
   Recents rows through `.clear` glass with a 30% dark tint. The system's `UIGlassEffect` on a
   detent also stops drawing, with the effect still set, once a sheet is presented over the sheet
   (Settings) and closed, and once the map behind it is touched; setting a new effect or calling
   `invalidateDetents()` does not bring it back. The material is not affected, so the legibility
   never depends on the glass drawing. Large is the solid `panel`.
5. **No accent on controls, plus category colour.** Controls and text use the
   label colour, set where they are drawn. The explore panel and the app take the
   system's tint, the `AccentColor` asset (dusk blue), so a text button that acts
   ("Choose start", "Try again", Cancel while comparing, an alert's buttons) reads as an
   action; until 10 November 2026 the app's tint was `.primary`, white in dark mode
   (the sheet research of 10 November 2026, step 3). Modal sheets (Settings, details,
   favourites, preferences, picker) still set `.primary` themselves. A switch's
   track when on is `switchTint()`: under `.primary` it is a white track
   under a white knob in dark mode, with nothing to tell on from off. Dusk blue (`.calmer`) is a
   colour on the map (the route line, its leader and the selected pin) and the on-state of a switch. Green no longer
   means calmer, and no fill anywhere is a saturated blue or green. Rating colour
   appears only on the rating word and bar. Category colours appear only on place
   badges (list rows, map markers, place card); they never tint glass, text or
   buttons.
6. **Glass stays neutral.** The sheet and banner are never tinted. Start and the
   other primary actions (Directions, Start, Done, Share report) are the system's
   `.glassProminent` button tinted `primaryActionFill` and labelled in `primaryActionText`,
   which the system makes opaque under Reduce Transparency and on an opaque sheet (10 November
   2026, replacing a solid `.borderedProminent` fill that switched with a `solidSurface` flag;
   on trial on the owner's phone). The fill is the label's slate with white
   words in light mode (9 November 2026: near-white on the pale sheet did not read as a
   button on the owner's phone), dusk blue with white words in dark mode (a lifted grey
   was no clearer there, and white at 86% was a slab brighter than anything else on a dark
   card). Dusk blue is the hue the switches take, the one a control may (principle 5). They are tokens, so they
   can move to dusk blue later.
7. **Honest words survive the redesign.** Every "Estimate", "unknown" and
   source/date line in the current UI stays. No screen says "safe".

## 2. Colour tokens

All tokens live in `App/PeoplemapsApp.swift` (`UIColor` + `ShapeStyle`
extensions), with an `AccentColor` asset that matches `.calmer`. Values are sRGB.
Contrast figures are WCAG, computed from the values; "on glass" ones are from
rendered pixels (below).

### Semantic

| Token | Light | Dark | Use | Contrast |
|---|---|---|---|---|
| `calmer` | `#4A6F97` | `#7FA3CC` | route line (white casing in light, black in dark), leader, selected pin, destination dot, a switch track when on | vs land 4.6 / 6.1, vs water 3.4 / 3.9 (≥3:1 graphic) |
| `switchOn` | `#4A6F97` | `#4A6F97` | a switch's track when on. Not `calmer` in dark: `#7FA3CC` under the white thumb is 2.6:1 and reads as off | track vs a near-black card `#1C1C1E` 3.3, vs the white thumb 5.2 |
| `fastest` | `#6B7872` | `#AEBAB3` | fastest line, dotted | vs land 4.1 / 7.9 |
| `passedRoute` | `#A6B3C0` | `#53616F` | the part of the followed route already driven, drawn 3.5 pt (the route is 5.5) | vs land 1.9 / 2.5; vs the route ahead 2.5 / 2.4. Below 3:1 on purpose: it is a trail, not information, and the width, the puck at its end and the casing say "behind" without colour |
| `primaryActionFill` | `#20384F` | `#4A6F97` | tint of the `.glassProminent` primary actions: Directions, Start, Done, Share report | |
| `primaryActionText` | white | white | label on the above | light: 12.1 on the fill; dark: 5.2 on the fill (computed) |
| `glassVeil` | white 34% | `#101412` 50% | over `.clear` on text surfaces: guidance, landscape card, credit; over `.regular` and a `.regularMaterial` on the sheet | |
| `glassVeilDense` | white 72% | `#101412` 72% | Increase Contrast | |
| `glassHairline` | `#142D23` 14% | white 14% | dividers on glass | decorative |
| `glassTrack`, `glassWell`, `glassChosen` | `#142D23`/white, low alpha | same | rating track, close and mode wells, chosen mode | graphic only |
| `panelFill` | elevated `secondarySystemBackground` | same | cards in solid modal sheets only, never on glass | text uses `label`/`secondaryLabel` |
| `userLocation` | `#4A8FD6` | `#4A8FD6` | the map marker (the route ring) and Current location row only. A white outer ring, white centre and a faint dark halo keep it clear of the route line by lightness (vs land 3.0 / 4.7) | |

### Costs and gains

A gain (what the calmer route avoids) takes a tick. A cost (minutes over the fastest route)
takes `minus.circle` in `onGlass`, never a tick: on the arrival card, and in "Behind the routes".

### Rating

The rating is a real progress bar: fill width is the 0 to 100 calm score, track
`glassTrack`, fill and word coloured by level (`CalmMeter`). Blue through grey to
orange and rose, not green to red, so it doesn't read as safe and unsafe. VoiceOver
reads "Chill, 69 out of 100".

| Level | Fill | Word light | Word dark | Word on glass, palest and darkest panel, L / D |
|---|---|---|---|---|
| Breezy | `#7FB2D6` | `#285A7E` | `#A3D0F0` | 6.0 / 6.8 |
| Chill | `#6FAFA8` | `#1F5F5A` | `#93D8D0` | 6.1 / 6.8 |
| Mixed | `#B8AE9A` | `#5F5646` | `#D3CBB8` | 5.9 / 6.8 |
| Spicy | `#D19A6B` | `#84491A` | `#F0BE8F` | 5.8 / 6.6 |
| Yikes | `#CF8A88` | `#8C3B39` | `#F0AFAD` | 6.1 / 6.0 |

Fills are 1.8 to 2.3 against the pale panel in light, 4.0 to 5.0 in dark. Below 3:1
in light is accepted because the word next to the bar says the same thing.

### Map

| Token | Light | Dark |
|---|---|---|
| `mapLand` | `#F1F2EC` | `#1A2421` |
| `mapStreet` | `#FBFBF8` | `#2C3A35` |
| `mapArterial` | `#EFE5C6` | `#4A4631` |
| `mapWater` | `#B9D5DF` | `#24454F` |
| `mapPark` | `#CCDFCF` | `#27463A` |
| `mapPath` | `#C9D4C3` | `#33423B` |
| `mapLabel` | `#4F6359` (5.7 on land) | `#BDCBC3` (9.5) |
| `mapWaterLabel` | `#3D6878` (4.0 on water) | `#B4D3DE` (6.5) |

Water names are italic title case, districts tracked capitals. A district name a
shown route runs through steps aside. The mockup's motorway `#E9D3B5` isn't drawn:
`Scripts/build_tiles.py` merges motorway, trunk, primary and secondary into one
`arterial` layer with no class, so it needs a tile rebuild and a data release.

### Place categories

Ten groups. Each place's raw `category` (from `Scripts/build_search.py`
`category_of`, stored in `entries.category` and read by `Core/SearchIndex.swift`)
maps to one group in a new `PlaceCategory` enum in `Core` (pure Swift, unit
tested, so the mapping is shared and not in a view). Badge = SF Symbol on a
filled circle. Muted to sit with the quiet map. Light mode: white glyph on the
light fill. Dark mode: glyph `#1C1C1E` on the brighter dark fill.

| Group | Raw categories (top ones in the Oct 2026 index) | Symbol | Light fill | Dark fill | Glyph:fill L / D | Fill:land L / D |
|---|---|---|---|---|---|---|
| Food | restaurant, fast_food, bakery, deli, ice_cream, pastry | `fork.knife` | `#BE6E46` | `#E09A72` | 3.8 / 7.3 | 3.4 / 6.9 |
| Coffee | cafe | `cup.and.saucer.fill` | `#927050` | `#C8A583` | 4.5 / 7.4 | 4.0 / 7.0 |
| Nightlife | bar, pub, nightclub, wine, alcohol | `wineglass.fill` | `#8C64A0` | `#BC97CF` | 4.7 / 6.9 | 4.2 / 6.4 |
| Shops | any `shop=*` not above: clothes, convenience, supermarket, books, gift, furniture… | `bag.fill` | `#646CB0` | `#9BA2DB` | 4.9 / 7.0 | 4.3 / 6.5 |
| Parks and nature | park, garden, wood, water, playground, nature_reserve, beach, dog_park | `leaf.fill` | `#48886C` | `#7DBD9F` | 4.2 / 7.8 | 3.7 / 7.3 |
| Sport | fitness_centre, sports_centre, pitch, stadium, swimming_pool | `figure.run` | `#3F8A8F` | `#74BCC1` | 4.0 / 7.9 | 3.6 / 7.4 |
| Transit and travel | station, halt, ferry_terminal, bicycle_parking, parking, fuel, charging_station, marina, hotel | `tram.fill` (station/halt), `ferry.fill`, `bicycle`, `parkingsign`, `fuelpump.fill`, `bolt.car.fill`, `bed.double.fill` | `#428096` | `#78B3C8` | 4.4 / 7.4 | 3.9 / 6.9 |
| Sights and culture | attraction, museum, viewpoint, gallery, artwork, memorial, monument, historic, theatre, arts_centre, cinema, library | `building.columns.fill` (museum), `binoculars.fill` (viewpoint), `theatermasks.fill`, `books.vertical.fill`, `paintpalette.fill`, `star.fill` (others) | `#B0607C` | `#DB93AD` | 4.4 / 7.1 | 3.9 / 6.7 |
| Health | clinic, doctors, dentist, pharmacy, hospital, veterinary | `cross.case.fill` | `#B85F60` | `#E29A9A` | 4.3 / 7.6 | 3.9 / 7.1 |
| Services and other | bank, atm, hairdresser, beauty, office, craft, building, school, place_of_worship, post_office, community_centre, everything unmapped | `mappin` (plus `building.2.fill` for building/office) | `#77797C` | `#ADAFB2` | 4.4 / 7.7 | 3.9 / 7.2 |

Fixed kinds keep their own look: Current location (`userLocation` circle,
`location.fill`), address (`Services` grey, `mappin`), dropped pin (`mappin`,
`systemRed` fill, as Apple's convention for a dropped pin).

Overture's long tail ("thai_restaurant", "shoe_store", "dermatology") reaches its
group through suffix rules in `PlaceCategory`, after the exact table. Without
them 37% of the all-Seattle index fell through to grey Services.

Map markers: the same fill and glyph, drawn from these tokens, on a 1.5 pt ring of
`systemBackground` (2.5 pt with Increase Contrast). All fills clear 3:1 against
`mapLand` in both modes (lowest: food 3.4 light), and all glyphs clear 3:1 against
their fills (lowest: food 3.8 light).

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

Glass has no fixed colour, so contrast on it is measured from captures, on the
all-Seattle map over land and water. Text uses `label`, `GuidanceOverlay.onGlass`
(`.primary` at 75%, since `.secondary` measures under 4.5:1 there) or a rating
word. Measured on `.clear`, 2 November 2026:

Worst case over the map under each surface, in contrast ratio:

| Where | Background, light | Background, dark | Primary, L / D | `onGlass`, L / D |
|---|---|---|---|---|
| Sheet (`.regular`, `.regularMaterial` and `glassVeil`), 4 November 2026 | `#F7F7F7` | `#1F2322` | 17.3 / 12.1 | 9.3 / 7.6 |
| Home capsule and chips (no veil) | white to `#CEECF7` | `#38423F` to `#3F626D` | 17.0 / 6.6 | none on them |
| Guidance banner, route under the text (`.regular`) | `#E6F5FA` to `#FCFCF9` | `#202826` to `#203337` | 18.8 / 13.2 | 9.8 / 8.1 |
| Trip bar | white to `#EBF8ED` | `#242B29` to `#293C35` | 19.2 / 11.7 | 9.9 / 7.4 |
| Landscape card | white to `#C3D6DC` | `#242B29` to `#45565B` | 14.0 / 7.7 | 8.2 / 5.2 |

The banner row above was re-measured on 3 November 2026 over the route line, which runs under the banner in the capture, after
it moved from `.clear` to `.regular`. On `.clear` the line showed through as `#9BB4CF` (light) and `#52677D` (dark),
and the same method gave 9.8 / 5.8 for primary text and 6.5 / 4.1 for `onGlass`: dark `onGlass` was under 4.5:1. On
`.regular` the line no longer shows, and along its path the worst background is `#F2F6F5` / `#252E2F` (19.3 / 13.9 primary,
9.9 / 8.5 `onGlass`). Method: every background pixel in the banner outside the text boxes, taking the worst against the
text colour (black or white; `onGlass` is that at 75% over the pixel); WCAG ratios.

The sheet row was re-measured on 4 November 2026, after it moved from `.clear` under a 30% dark tint (dark only) to `.regular` and
a material under `glassVeil`. Same method, applied to the ring of 5 pt around every text box in the sheet, leaving out other texts and
icons, over the map panned so that a neighbourhood label (Queen Anne), the lake and Fremont's label pass under the sheet's body, and
over the preview and search screens. Worst case, primary / `onGlass`:

| | Light | Dark |
|---|---|---|
| `.clear` (before) | 13.3 / 8.0 | 9.5 / 6.2 |
| `.regular` + material + `glassVeil` | 17.3 / 9.3 | 12.1 / 7.6 |

The place card's estimate line sits in the primary action's fill: in light mode white on slate, 12.1;
in dark mode white on dusk blue (`PlaceCardUITests.testDirectionsIsNotABrightSlabInDarkMode` reads both from the screen and fails
under 4.5, or if the fill is brighter than mid-grey; the ratio itself has not been written down here yet). How far the map shows through the
empty body of the sheet, as the standard deviation of its brightness (0 to 255) with a label under it: 16.8 and 11.5 (dark),
15.9 and 15.7 (light) before; 0.5, 0.6 and 0.3, 0.4 after. The labels are no longer readable through the body. Run
`EvidenceTour.testSheetLegibility` (`TEST_RUNNER_PEOPLEMAPS_EVIDENCE=1`, once per appearance); `HomeAndSearchUITests` fails if the
raised sheet is not frosted at rest, after Settings closes, or after the map is panned.

Rating words on the sheet are 5.9 or more in light and 6.1 or more in dark.
Behind the routes is solid: its headers and footers measure 9.7 / 10.0, once they use
`onGlass` instead of the list's own grey (3.1). A marker under the landscape card shows
through as a soft shape; text over one still measures 7.5.

Glass on a real phone can differ from the Simulator, so the phone has the last word.

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

- One vertical glass capsule, top trailing, in a `GlassEffectContainer`:
  **Locate** (`location`; always shown; centres on the user, and explains itself
  in an alert when it can't: permission not asked or denied, outside the map, no
  fix yet) and **Fit** (`viewfinder`; "Fit routes on map" in preview, "Centre on
  this place" on a place, "Fit map to Seattle" on home). Settings is a row on the home sheet (4.2), so
  the cluster stays at two buttons. Each button 44×44, `.clear` glass.
- The cluster rides above the sheet's detent and fades out when the sheet is
  at the large detent (Apple Maps behaviour).
- Attribution: "© OpenStreetMap" stays always visible and linked (ODbL),
  and becomes "© OpenStreetMap contributors · Overture Maps Foundation" once
  Overture Places lands (branch `search/overture-places`). `.caption2`, on a small glass capsule just above the sheet's top edge,
  leading. It moves with the detent. At the large detent only the status bar is
  left above the sheet, so the credit moves inside it, pinned at the bottom
  in a `safeAreaBar`, so a list scrolling behind it stays legible. Size capped at `.large`, one line. The credit is positioned
  from the sheet's global frame, never its height: at low stops the system scales
  the sheet (0.86 at about 80 pt, 0.96 at about 100 pt and over) and floats it above
  the screen's edge, so its height doesn't say where its top is. It is a licence
  term: `testPeekHoldsItsContentAndLeavesTheCreditVisible` holds it above home's
  controls, and `testMapCreditStaysVisibleWhenTheSheetIsRaised` keeps it on screen.
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

Home is one system sheet that is always there, and it holds the only search field (owner, 10 November 2026: the floating
"Where to?" pill stacked over the sheet's own field read as two search bars). It has two stops and no large one.

- **Lowest stop (peek).** As tall as the controls (`HomeHeight.controls`): favourite chips, the 44-pt "Where to?" field in a
  `glassWell` with a round More button (`home-more`) beside it, and on first launch the hint "Search a place or address, or
  long-press the map" (D4) as a `.footnote` caption in `onGlass` under the field. In a well of its own above the field it
  passed for a second field (9 November 2026). Recents and the rows below are laid out under the fold, hidden from touch and
  VoiceOver, so they slide into view as the sheet rises.
- **Raised.** More, or a flick up, raises it to a stop as tall as everything it holds (`raiseHome`, `PortraitSheet`), up to 70%
  of the screen, past which it scrolls: the controls, Recents, then the rows **Edit favourites** and **Settings**. At the
  system's medium a fresh install showed half a screen of empty panel under the field and one row (9 November 2026). A flick
  down returns to the peek.

Home's stops are the only measured ones, since favourites and Recents change what it holds: a new height is added beside
the old one and selected, and the old one is dropped once the sheet has glided there, so it never jumps. The place card and
the preview have designed heights instead (4.4, 4.5). Home has no large stop (decision, 4 November 2026): at large it was a
flat, square-edged, opaque page with the map dimmed, holding a hint, the field and one row. Search is the screen that goes
large, where results need the room.

The two rows are set like the Recents rows above them (`HomeRow`), so they read as rows to tap and not as a footnote: a
glyph (`star`, `gearshape`) on a 32-pt `glassWell` circle where a place's badge sits, the title in `.body` label colour,
a trailing chevron, 52 pt tall (46 in landscape), with the hairline between them inset past the glyph.

- **Favourite chips:** a horizontal row of capsules, a 30-pt category badge and the
  place's short name (`Place.shortName`). Tapping one opens the place card;
  long-press removes it. The row ends in a round **Add**, which raises the sheet to
  `.large` with the search field focused; picking a result favourites it. The row
  is hidden until there is a favourite (owner, 1 November 2026).
- **Recents:** on the sheet's glass, split by hairlines, with category badges. No
  Featured places (ux-round-1).

```
                         (map)
 ( © OpenStreetMap · Overture )
 ( (🍃) Gas Works Park ) ( + )
 ( 🔍 Where to?        ) ( ⋯ )
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
- No results: the "Look up in Apple Maps" row (plain grey badge `map`,
  `arrow.up.forward`) first, where a result would be, then `ContentUnavailableView`
  with today's copy; unchanged wording. Under the empty state the row fell behind the
  keyboard and the credit on a smaller phone or at larger text (9 November 2026).
  VoiceOver still hears the empty state first. The start and destination pickers do the
  same. Nothing from Apple is shown in the app.
- `scrollEdgeEffectStyle(.soft, for: .top)` under the pinned field.
- **Before anything is typed** the sheet is never a blank page (9 November 2026): Recents, or on a fresh install the line
  "Search a place, an address or a street", then six shortcuts in two columns (`SearchShortcuts`): Coffee, Food,
  Groceries, Parks, Gas and Pharmacy. Each is set like a favourite chip, a 30-pt category badge and a word in a
  `glassWell` capsule, and types its word into the field, so the results are the index's own category search
  (`Docs/SEARCH.md`, Category words), nearest first. The header is "Nearby" when the map can show the user and
  "In Seattle" otherwise. They are searches, not suggested places: nothing is featured. One column at accessibility sizes.

### 4.4 Place card

Proposed (with `ux-round-1` content): sheet sized to fit the card, so medium
doesn't leave half of it empty; at accessibility sizes the same fit stop, capped at 70% of the screen, the card scrolling and its type held at `accessibility3`.
- Header: 44-pt category badge, name `.title2.bold()`, "Restaurant ·
  Fremont" `.subheadline`. Trailing: favourite (`star`/`star.fill`) and close
  (`xmark`) as small bordered circular buttons (not glass: they sit on
  glass).
- Address line, or "Near 3400 Fremont Ave N".
- **Directions**: full-width `.primaryAction()`, label `primaryActionText`. The mode
  symbol sits under the badge and the words start under the name, left-aligned like the
  header above them (at accessibility sizes the name has the full width, and the symbol
  takes its own). It says **Directions**, so the card's one action names what it does,
  over the route Start would take: "Calmer: 12–14 min, 3.4 mi", or "9–11 min, 2.9 mi"
  with no calmer route; "Estimating…" holds that line until the estimate lands. Under the button, as notes and not as part of it: "Mixed →
  Breezy, mostly fewer unsignalled lefts" or "Chill, best balance we found"
  (`Docs/STRESS_MODEL.md`, Calm score), then "Estimate, no live traffic".
- **The card is laid out once.** Every line is there from the first frame (the calm note as a blank until the estimate
  lands, held to one line at standard sizes), and the sheet's fit stop is a height designed for the card at each text
  size (`SheetHeights`, from captures on 10 November 2026), plus a line when the estimate starts somewhere else. Before,
  the stop was the card's measured height: a `.height` detent of a new value is a new detent, so the card opened at one
  height and moved when it was measured, and again when the estimate added lines, which read as a flicker
  (`PlaceCardUITests.testCardDoesNotMoveWhenTheEstimateLands`). A shorter card (outside the area we cover) leaves glass
  under it; a taller one scrolls.
- The card rests at its own height and has no other stop (large stays at accessibility
  sizes, where it can outgrow the fit stop): raised, it was the card over a blank panel.
- Source/date line at the bottom.
- Outside coverage: the existing "Outside the area we cover yet" group,
  unchanged copy, `exclamationmark.triangle` in secondary.

### 4.5 Route preview

A floating glass panel, content straight on the glass, split by hairlines, no
cards. It opens at a height designed for it at each text size (`SheetHeights.preview`, room for a two-line reason
under the calmer route), with the route and map above.
Top to bottom:

1. **Header.** Destination (`choose-destination`), distance, "From Current location"
   (`choose-origin`, or an empty "Choose start"), "Estimate, no live traffic", close.
   The two places are buttons with a full-size target each and no overlap: the
   destination's reaches up into the sheet's top margin and the start's down to the
   rating, so the two lines stay close.
2. **Big rating word and time range.** `route-calmer`, or `route-fastest` with no
   calmer route. Then the rating bar, full width.
3. **Reason line:** what it costs and its biggest gain, "1 min more than fastest, 2
   fewer unsignalled lefts" (`reasonLine`).
4. **Fastest row:** "Fastest: Mixed", its time, its own smaller bar. Its target reaches
   8 pt into the gaps above and below it. Selecting a route morphs the map line opacity.
   With two routes each one's time ends in a radio mark (`ChoiceMark`: `circle`, or
   `checkmark.circle.fill` when chosen, in the label colour), so the pair reads as a
   choice before it is made. One route alone has no mark.
5. **Why this route** and **Calmer means** (`route-preferences`), each a semibold
   `.subheadline` in the system's `.bordered` capsule tinted `.primary` (`wellButton()`), inside a
   full-size target: not glass and not an accent (principles 3 and 5). As bare bold text they read
   as labels.
6. **Pinned:** icon-only travel modes (Drive, Cycle, Walk, named for VoiceOver and
   in the large content viewer) beside **Start** (`.primaryAction()`).

**Targets.** The system draws the sheet about 4% smaller at its partial stops (it floats
8 pt in from each side), so a 44-pt frame measures 42 on screen. Targets on the sheet are
laid out at `Layout.target`, 46 pt, which is 44 on screen.
`RoutePreviewUITests.testPreviewControlsHaveFullSizeTargets` measures them and taps their edges.

Raised (0.72 of the screen, or large, or in landscape and at accessibility sizes)
it also shows **swap** and the **Extra time** menu. At accessibility sizes it opens raised, not large, so the map stays above it; the scrolling body holds its type at `accessibility2` and the calm word at 48 pt, with the footer pinned.

```
╭────────────────────────────╮
│ Gas Works Park     3.4 mi ✕│
│ From Current location      │
│                            │
│ Breezy         12–14 min ◉ │
│ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░ │
│ 1 min more than fastest,   │
│ 2 fewer unsignalled lefts  │
│ ────────────────────────── │
│ Fastest: Mixed  11–13 min ○│
│ ▒▒▒▒▒▒▒▒░░░░░░░░░░░░░░░░░░ │
│ ────────────────────────── │
│ (Why this route) (Calmer means)│
│ (🚗 🚲 🚶)   (    Start    ) │
╰────────────────────────────╯
```

**Behind the routes** (`RouteDetails`) is a solid `panel` sheet, since it's long
reading: a row per route with word, "NN of 100" and bar (`CalmBar`, `calm-bar`),
then the reasons and metrics.

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

Portrait: the persistent sheet is hidden; guidance owns the screen. Every surface
is `.clear` with `glassVeil` (`.light`), and `glassVeilDense` with Increase Contrast.
The turn banner, rerouting card, trip bar and landscape card are `.regular` under the same veil (principle 4).
- **Turn banner**: glass, top, full width minus 8. Arrow in `.primary`,
  distance `.largeTitle.bold()`, instruction `.title3.semibold`. The "Then:"
  row sits inside the same glass with a hairline divider, not a second fill
  (no glass on glass, no opaque strip).
- **Calm chip** below the banner, leading: glass capsule, `octagon` /
  `light.beacon.max` + text in `.primary` semibold (see 2, "On glass").
- **Mute + report flag**: two round system glass buttons side by side (stacked
  in landscape), trailing, same row as the chip: `.buttonStyle(.glass(.clear))`,
  `.buttonBorderShape(.circle)`, `.controlSize(.large)`, 50 pt across, in one
  `GlassEffectContainer`. After a tap the flag widens to a "Marked" capsule.
  With Reduce Transparency or Increase Contrast they use `.regular` glass (6a).
  Banner, chip and buttons share the outer `GlassEffectContainer` so they
  merge/morph as the chip appears.
- **Camera button** (`guidance-camera`): the same round system glass button,
  alone in the bottom trailing corner, beside the attribution and above
  the trip bar (above the attribution in landscape). That keeps it clear of the
  banner, the recording pill (top leading) and the mute/flag cluster. One tap
  moves to the next state, and the glyph shows the current one with the symbol
  replace transition (a cross-fade under Reduce Motion):
  `location.north.line.fill` follows the direction of travel, `safari` follows
  the phone's compass, `map` shows the whole route. Labels are "Travel direction
  up", "Compass direction up" and "Whole route"; the hint names what a tap does.
  After a free look the button keeps the glyph of the state before the pan and
  a tap returns to it.
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
would push mute, the flag and the camera button off it. Secondary text on glass uses
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

- **Marker.** One family, the route ring, inspired by the ring-shaped stops in
  the app icon, in `userLocation` blue (never green) with a faint dark halo. With
  no heading, or standing still outside guidance, it is a 28 pt blue disc with a
  2.5 pt white outer ring and a 12 pt white centre, so it reads as a thick blue
  ring; no direction is invented. With a known course, outside guidance or in it,
  the same ring's outline grows into one rounded point in the direction of travel,
  like a teardrop, tip 24 pt from the centre; the white centre and outer ring
  stay. There is no beam, rim tip or separate arrow. The view turns with the map.
  While guiding the point is the GPS course above about 2 m/s and the phone's
  compass below it, at a stop, or when the course is invalid, with a short blend
  between the two so it never jumps; with neither it keeps the last heading. The two forms crossfade over
  0.2 s; with Reduce Motion there is no animation.
- **Route line.** The line splits at progress: behind is `passedRoute`, 3.5 pt
  (casing 6), ahead keeps the route colour at 5.5 pt. Colour is not the only
  cue: width and the marker at the join carry it. Only the two shapes are
  replaced, every 4 m, so the style is never rebuilt; a reroute starts at
  zero.

### 4.8 Arrival

A bottom glass card inside `GuidanceView`, not the returning sheet, no grabber.
Check badge on `glassWell`, "You've arrived at Gas Works Park", summary line, trip
notes split by hairlines, **Done** as `.primaryAction()`, "Times are estimates. No
live traffic." and the voice tip. `.sensoryFeedback(.success)` fires on arrival.

### 4.9 Settings

Replaced "About PeopleMaps" (9 November 2026): one long list that opened on two cards of prose, with the controls people
use three screens down. Reached from the home sheet's **Settings** row (4.2). A `.large` sheet on the solid `panel`
(principle 2): `NavigationStack`, inline title, inset grouped `List`, and the close button on every page. Code:
`App/Settings/`.

**The root list is rows only** and fits one screen at the default text size. It holds no paragraph: a footer is one
sentence, two at most, and every explanation is a page behind a row. Sections, in order:

1. **Map.** "On this phone" with the map in use as its value (Seattle, King County), then the King County offer. At rest
   the offer is one row, "Download King County" with the download size as its value ("Update King County" when an older
   release is on the phone), over a footer that says what it covers, the space it takes and that it downloads over Wi-Fi.
   Past that it is one row that says where King County stands and a row for each thing to do: "Downloading" (bar,
   "x MB of y MB") with Pause; "Waiting for Wi-Fi" with Use cellular and Pause; "Paused" with Resume; the plain reason
   with Retry; "Verifying"; and "Ready" ("Ready. Switches at next launch", with Switch now only when no route is shown and
   the person is not navigating) with Remove King County, which asks first. Colour comes only from the system; the bar is
   the standard `ProgressView`. After the switch the place card says "PeopleMaps covers King County and a little beyond."
   outside coverage, and a place no road reaches inside it says "No road route to this place in PeopleMaps. It may need a
   ferry or a road outside the map, as Vashon, the Kitsap shore and Skykomish do."
2. **Trip logs.** "Usage log" and "Detailed log", each with its state as its value ("Off", "On", "On · 3 trips",
   "On · 2 trips, 1.4 MB"; the size only from 1 MB up) and its own page. While the detailed log is on, "Start recording"
   sits on the root, since it is the one log action people repeat: a trailing `play.circle` in the secondary grey, and "Stop recording" (`stop.circle`) with the time so far
   while one runs. If location is off, a row under it says the recording did not start. Footer: "Off by default. Kept on
   this phone unless shared."
3. **Feedback.** "Report a problem", and "Saved reports" with its count once there is one. Footer: "Or shake the phone on
   any screen."
4. **About.** "What calmer means", "Map data and coverage", "Acknowledgements". Under the list, centred: "PeopleMaps
   0.1.0 · 793bdf6", the version and, when the build was given one, its commit (`PM_BUILD_COMMIT`, empty by default,
   through `PMBuildCommit` in `App/Info.plist`; `Scripts/run-simulator.sh` passes it).

**Pages.** The same list. An explanation is a `SettingsNote`: a `.body` semibold heading over a `.subheadline` paragraph,
one to a row.

- **Usage log:** "Keep a usage log", "Exact places" while it is on, and "Kept on this phone" with the count; "Share usage
  log", "Send to PeopleMaps" and "Clear usage log" once there is a trip.
- **Detailed log:** "Keep a detailed log" and "Kept on this phone" ("2 trips, 1 recording, 1.4 MB"; an empty log is
  "0 trips", never a zero size); "Share detailed log", "Send to PeopleMaps" and "Clear detailed log".
- **The log pages explain in footers**, as the system's Settings does: grey footer text under the group it is about, a
  paragraph each, and no rows of notes. What the log keeps sits under the switch; where it stays and what sending does sits
  under the actions (under the switch while the log is empty). It says everything `Docs/PRIVACY.md` says about the log in
  fewer words; change them together.
- **Send to PeopleMaps** (`Docs/REPORTS.md` 4.8) never dims and never changes its words while it works: the system's
  spinner stands in the row's value slot, then "Sent" (or "Already sent"). "Delete sent logs" joins the group only once a
  send is over. A send or delete that did not happen is a system alert, not text that moves the list.
- **Clear asks first.** The dialog hangs off a view of its own behind the page. On a list or section that holds a
  `ShareLink` it stops the share sheet presenting (PR 68).
- **Saved reports:** tap one to add words or share it again, swipe to remove it.
- **What calmer means:** one sentence, then Driving, Cycling and Walking, each a row with its mode symbol. Footer, kept
  word for word: "These are transparent preferences, not safety ratings. Times and stress are estimates, with no live
  traffic."
- **Map data and coverage:** what stays on the phone; Sources ("Map data from" the date of the extract in use, read from
  the search index, the OpenStreetMap ODbL link, USGS elevation, and the count of street and path segments); Coverage
  and what the map doesn't know, ending "These routes haven't been checked on the road, so go by the signs in front of you."
- **Acknowledgements:** OpenStreetMap, Overture, USGS, MapLibre and Ferrostar with their licences. Links in label colour
  with `arrow.up.forward`.

**Type and colour.** Section headers are `.footnote` semibold. Headers, footers, row values and note paragraphs use
`GuidanceOverlay.onGlass`, since the list's own grey is about 3:1 on its background. The root has no row icons, so every
row starts on one line. Nothing takes an accent: rows and buttons are label colour, the two destructive rows the system's
red, switches `switchTint()`. The navigation bar is solid, in the list's background colour, so a row is cut off under the
title; the system's scroll edge effect blurred section headers into a ghost there. The last words of a footer are joined
with no-break spaces where the line would otherwise end on one word. At accessibility sizes a row's value moves under
its title.

### 4.10 Report a problem

A system page sheet with a solid grouped `Form` (`ReportComposerView`; what it collects is `Docs/REPORTS.md` section 11): the note,
"Include exact locations" and "What's included", and the line that says nothing leaves the phone until it is shared.

The note is focused as the sheet opens, since typing is the point, so the keyboard is up from the start. **Share report**
(`share-report`) is therefore not a row in the form, where it sat under the keyboard: it is the sheet's one `.primaryAction()`,
pinned in a bottom `safeAreaBar` that rides above the keyboard. A drag down the form puts the
keyboard away (`scrollDismissesKeyboard(.interactively)`) and leaves the sheet open. The button's type stops at `accessibility1`,
so at the largest sizes it stays one line and the note keeps its room.

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
  hand. The sheet gets a solid `panel` (`sheetBackdrop`).
- **Increase Contrast** (`colorSchemeContrast == .increased`): glass takes
  `glassVeilDense` and a 1-pt `separator` border (system controls do this
  themselves); `calmer` route line widens by 1 pt.
- **Dynamic Type**: test at `.large`, `.xxxLarge` and `.accessibility3`.
  Rows wrap, never truncate place names past two lines; trip bar stacks;
  preference segmented controls move under their label. The Favourites row
  scrolls horizontally at accessibility sizes, with names wrapping to two
  lines.
- **VoiceOver order**: home: search field, favourites (each "Gas Works
  Park, park"), the Add badge ("Add a favourite"), recents, Settings, then
  map controls (locate, fit), then the map. Preview: to, from, close, calmer
  route, fastest route, Why this route, Calmer means, modes, Start; swap and extra
  time when raised. Guidance: banner (distance + instruction + then), calm note, trip
  stats, End, mute, overview. Use `accessibilitySortPriority` on the sheet so
  it comes before the map controls. Category badges are hidden; the category
  word is in the row label.
- **Contrast**: 4.5:1 for all text (section 2), 3:1 for route lines and badges
  against the map. Rating fills are the one accepted exception (section 2, Rating).
- Every control keeps its current `accessibilityIdentifier` so UI tests keep
  working; new controls get one (`locate`, `add-favourite`, `extra-time-menu`,
  `route-preferences`, `preference-<factor>`, `reset-preferences`).

## 6a. Glass audit, November 2026

Every floating surface, from captures in both appearances on the all-Seattle map,
after the owner phone-tested `.regular` twice and couldn't see glass.

| Surface | Glass | Finding |
|---|---|---|
| Sheet at its partial stops | `UIGlassEffect(.regular)` per detent (`SheetGlass`) under a `.regularMaterial` and `glassVeil` | Fixed 4 November: `.clear` plus a dark tint let labels print through, and the system glass stops drawing after Settings closes or the map is touched. The material carries the frost. |
| Sheet at large | solid `panel` | Long lists and the keyboard. |
| Home at rest | no sheet; `.clear` chips, capsule and More | Refracts the map; the dark map's streets show through. |
| Map buttons | `.clear`, `.interactive()` | |
| Credit, turn banner, calm chip, trip bar, landscape card, arrival card | `.clear` + `glassVeil` | |
| Re-centre pill | `.glass` button | Over the map, not on the sheet. |
| Directions, Start, Done | `.primaryAction()` | The one allowed glass-in-glass: the primary action (principle 6). |
| Guidance mute, flag and camera | `.glass(.clear)` buttons | Over the map. With Reduce Transparency or Increase Contrast the system turns `.clear` dark under a dark symbol in light mode, so they take `.glass(.regular)` there, which stays light in light mode. |
| Why this route, Calmer means | `wellButton()`: `.bordered`, tinted `.primary` | A well, not glass (principle 3). |
| Behind the routes, Settings, pickers | solid or system modal | Reading, not glance. |
| Reduce Transparency | `floatingSurface`, `sheetBackdrop` | Solid `panel`, with an outline. |

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
9. **Settings and Acknowledgements.** `App/Settings/` (4.9). Evidence:
   `EvidenceTour.testSettingsScreens` and `testSettingsLargeTextAndLandscape`.
10. **Accessibility pass.** VoiceOver order, sort priorities, haptics, AX3
    screenshots of every screen, `ui-summary.json` refreshed.

Run `python3 Scripts/generate_project.py` in any PR that adds an `App/` file
(2, 7).

## 8. Decided 30 October 2026

1. **Home at rest:** search field plus the favourite chips, floating with no sheet
   (4.2, changed November 2026).
2. **Parks colour:** a muted green; green no longer means calmer (section 2).
3. **About:** moves from the map buttons to the home sheet's footer. It became Settings in November 2026 (4.9).
4. **Extra time:** a menu on the raised preview and in landscape, not on the panel
   as it opens (changed November 2026).
5. **iPad:** iPhone only for now.
