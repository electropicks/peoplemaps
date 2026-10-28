# Apple practices, user sentiment and packaging audit (October 2026)

Research only, 27 October 2026, on branch `stress-model` at `2b21e9b` plus the
uncommitted stage-3 navigation screens. Nothing in `App/`, `Core/`, `Scripts/`,
`UITests/` or the Xcode project was changed. Sources are linked inline; most
2026 coverage is secondary press, so items marked *(unconfirmed)* should be
checked against Apple's own documentation before acting.

**Headline:** the product direction (offline, no account, no ads, honest
estimates, one accent colour) matches what people are asking for in 2026 almost
point for point. The gaps are mostly packaging: as it stands the app **cannot
be uploaded to TestFlight** (no app icon, signing disabled, no privacy
manifest) and **real-device navigation would fail** (no location usage string).
Design gaps are second: the custom bottom panel and map buttons do not use the
system sheet or Liquid Glass, which Xcode 27 no longer lets apps opt out of.

---

## 1. Apple design audit

### Where Apple is in 2026

- **Liquid Glass is now the baseline.** WWDC25 introduced it; WWDC26 (iOS 27)
  refined readability and added a user slider from clear to tinted
  ([TechCrunch](https://techcrunch.com/2026/06/08/apple-is-tweaking-its-controversial-liquid-glass-design),
  [MacMyths](https://macmyths.com/wwdc-2026-apple-refines-liquid-glass-across-its-next-generation-operating-systems/)).
  When built with the Xcode 27 SDK, `UIDesignRequiresCompatibility` is ignored,
  so every app gets the new look on iOS 26+
  ([Apple Developer Forums](https://developer.apple.com/forums/thread/832543)).
  Our README says the baseline was built with Xcode 27, so we are already in that world.
- **Glass belongs to the navigation layer** (toolbars, floating controls, sheets),
  not to content; standard components adopt it automatically, and opaque custom
  backgrounds defeat it ([Atelier Socle guide](https://www.atelier-socle.com/en/articles/swiftui-liquid-glass-guide)).
  Apple Maps itself is the reference: a resizable glass sheet with detents and a
  glass control cluster on the map.
- **Permissions in context.** The HIG says to ask when the person uses the
  feature, and to prefer When In Use
  ([HIG: Privacy](https://developer.apple.com/design/human-interface-guidelines/privacy),
  [Core Location](https://developer.apple.com/documentation/bundleresources/choosing-the-location-services-authorization-to-request)).
  `Docs/NAVIGATION.md` decision 5 already says this.
- **Live Activities reach CarPlay.** Since iOS 26 a Live Activity started on the
  phone also shows on the CarPlay Dashboard (small family, falling back to the
  Dynamic Island compact views)
  ([WWDC25 session 216](https://developer.apple.com/videos/play/wwdc2025/216/)).
  Full CarPlay navigation needs a separately approved `carplay-maps` entitlement.
- **Accessibility Nutrition Labels** on the product page (VoiceOver, Larger Text,
  Dark Interface, Sufficient Contrast, Reduced Motion, etc.); claim one only if
  every common task works with it
  ([Apple tech talk](https://developer.apple.com/videos/play/tech-talks/111433/)).

### What we do well already

- Semantic text styles almost everywhere; `@ScaledMetric` for the maneuver arrow;
  `monospacedDigit()` on changing numbers.
- Real light/dark tokens, elevated panel colours, contrast-adjusted `calmerText`
  and `directionsFill` shades.
- Thorough accessibility labels, identifiers, header traits, combined elements;
  the map has a text alternative ("Routes are also described in the panel").
- Landscape layout with a leading floating card, as Apple Maps does.
- Honest copy throughout ("Estimate, no live traffic", "Works offline").
- No location request on launch; browse and compare without permission.

### Gaps, ranked by impact on a simple first launch

| # | Gap | Evidence | Recommendation |
|---|-----|----------|----------------|
| D1 | **The bottom panel is a hand-drawn card, not a sheet.** The grabber (`ExploreView.swift:133`) is decorative: no drag, no detents. Users will try to drag it on the very first screen. | `ExploreView.portraitLayout`; `home-light.png` | Use a persistent `.sheet` with `presentationDetents([.height(…), .medium, .large])`, `presentationBackgroundInteraction(.enabled(upThrough: .medium))` and `interactiveDismissDisabled()`. On iOS 26+ it becomes glass automatically and the map shows through at small detents. Keep the landscape card (or use `.presentationSizing` / an inspector on iPad). |
| D2 | **Map controls use `.regularMaterial` + custom shadow**, not Liquid Glass; the guidance card, chips and trip bar are opaque white cards. They read as iOS 17 next to every other app on iOS 26/27. | `ExploreView.mapButtons`, `GuidanceView`; `nav-guidance-light.png` | `glassEffect()` inside a `GlassEffectContainer` for the map buttons (gate with `#available(iOS 26, *)`, keep material as fallback). Guidance banner: keep it opaque-ish for glance legibility (Apple Maps does), but use the system corner radii and remove custom shadows. Don't tint glass with green except the primary action. |
| D3 | **No "where am I" on the map.** Home never shows the user's position or a locate button; origin defaults to Kerry Park. For a maps app, "from my location" is the expected default. | `startDirections` fallback | Add a location button (`LocationButton` from CoreLocationUI or a standard `location` glyph) in the control cluster. Tapping it is the in-context permission moment. Offer "My location" as an origin row once granted; keep featured places when not. |
| D4 | **First launch explains nothing about the one idea.** Home shows "Featured places" but not what "calmer" means until a route is shown. | `home-light.png` | One line under the search field on first launch ("Routes with fewer stressful turns, for a few minutes more"), dismissible, no onboarding carousel. Users dislike multi-screen onboarding (see §2). |
| D5 | **Two route-option controls stacked** (mode segmented + extra-time segmented) on the preview: dense for a first view. | `redesign-portrait-light.png` | Keep mode; consider moving extra-time behind a compact menu (`Menu` / `Picker(.menu)` "+5 min ▾") at the small detent, full segmented at medium. Apple Maps uses one row of mode chips. |
| D6 | **Dynamic Type at accessibility sizes is unverified.** README says so. Fixed `cardWidth = 330` in landscape and `minimumScaleFactor(0.6)` on trip numbers will clip at AX sizes. | `ExploreView.cardWidth`, `GuidanceView:235` | Add UI-test screenshots at `.accessibility3`; switch layouts with `dynamicTypeSize.isAccessibilitySize` (stack trip-bar numbers vertically). Required before claiming "Larger Text". |
| D7 | **Haptics: none.** | grep: no `sensoryFeedback` | `.sensoryFeedback(.selection, trigger:)` on mode/budget change; `.impact` on Start; `.success` on arrival; a light tap ~100 m before a maneuver for cyclists/walkers (phone in pocket). Respect system haptics setting (automatic with `sensoryFeedback`). |
| D8 | **Screen sleep, audio and lock screen during guidance.** Voice is muted and idle timer not disabled yet (stage 4). | `NavigationController`; NAVIGATION.md | Stage 4 should: set `isIdleTimerDisabled` only while guiding; `AVAudioSession` `.playback` + `.voicePrompt` mode + `.duckOthers`; respect Silent mode toggle per mode. |
| D9 | **Live Activity / Dynamic Island.** Not planned. | — | Add after first TestFlight: maneuver + distance in the compact island, ETA on the lock screen. This is also what makes the CarPlay Dashboard show our turns without a CarPlay entitlement. High value for cyclists (phone on stem, locked). |
| D10 | **iPad.** `TARGETED_DEVICE_FAMILY = "1,2"` ships to iPad, but layouts are untested there. App Review tests iPad builds of iPhone apps. | `generate_project.py` | Either test iPad (regular width: sidebar card like landscape) or set family to `1` for TestFlight. |
| D11 | **Reduce Motion / Reduce Transparency / Increase Contrast** not checked; MapLibre camera animations ignore Reduce Motion. | `SeattleMap` `animated:` calls | Read `accessibilityReduceMotion` and pass `animated: false`; check glass with Reduce Transparency on. |
| D12 | **About sheet is the only home for credits and is stale for navigation**: says "No account or location permission is needed" and omits Ferrostar and USGS. | `RouteDetails.swift:103` | Update copy when location lands; add an "Acknowledgements" row (see P7). |
| D13 | **Accent tint and system colours.** `.tint(.calmer)` is global, so system controls (toggles, links, `Done`) turn green. Fine, but "Why this route" link in green next to green route copy reduces hierarchy. | `PeoplemapsApp` | Declare the accent as an asset-catalog `AccentColor` (P3) so the launch screen and system UI match; keep green for the calmer route and the primary action only. |

Not gaps: we correctly avoid a tab bar (single-task app), avoid custom fonts,
and use SF Symbols for maneuvers.

---

## 2. What people say about apps in 2026

### Maps and navigation

- **Ads in maps are the loudest grievance this year.** Apple Maps started
  sponsored search results in the US and Canada in 2026 with no way to turn them
  off, even for paying subscribers; some users said they'd switch
  ([GadgetReview](https://www.gadgetreview.com/apple-maps-now-has-ads-you-cant-turn-off-not-even-if-you-pay),
  [Cult of Mac](https://www.cultofmac.com/?p=937775),
  [iClarified](https://www.iclarified.com/100386/apple-maps-ads-could-spark-backlash)).
  Waze opened its sponsored on-route pins to Performance Max advertisers in
  September 2026, again with no opt-out
  ([Selectra](https://selectra.info/telecom/actualites/marche/waze-epingles-sponsorisees-detour-publicite)).
- **AI that talks too much.** Gemini replacing Assistant in Google Maps / Android
  Auto drew complaints that it is slow, chatty and can't be switched off; some
  joked about going back to paper maps
  ([autoevolution](https://www.autoevolution.com/news/i-ll-go-buy-a-paper-map-android-auto-users-hate-gemini-request-option-to-disable-it-269825.html)).
  Google's March 2026 3D/"Ask Maps" redesign also brought UI-churn complaints
  ([netzwelt](https://www.netzwelt.de/news/251848-muell-nutzer-neue-google-update-maps-hassen.html),
  [Shopifreaks](https://www.shopifreaks.com/google-maps-adds-gemini-ai-with-3d-navigation-and-conversational-search-in-biggest-update-since-2009/)).
- **Wrong destinations and bad data** remain the top low-star theme across all
  three big apps; Waze is also criticised for ad density and aggressive
  maneuvers ([Unstar review analysis, early 2026](https://unstar.app/blog/google-maps-apple-maps-waze-navigation-apps-ranked-2026); commercial blog, treat as a rough signal).
- **Cut-through routing annoys residents and drivers** — the long-running Waze
  criticism ([AP via Washington Times](https://www.washingtontimes.com/news/2018/apr/17/los-angeles-councilman-says-waze-causing-traffic-a/)).
- **Cyclists say mainstream apps send them down busy roads**, including in
  Seattle: Apple's "avoid busy roads" picked 3rd Ave over the 2nd Ave protected
  lane; rerouting nags you back to the original line
  ([Seattle Bike Blog](https://seattlebikeblog.com/2021/05/03/apple-maps-now-has-bicycling-directions-and-they-are-ok-compared-to-googles-dusty-service),
  [Galaxus](https://www.galaxus.de/en/page/how-bad-do-apple-maps-bike-routes-suck-apple-yes-33246)). Older, but still the reason people use specialist apps.
- **Paywalls on core features sour loyalty.** Komoot's 2025 move of device sync
  behind Premium and its acquisition brought loud backlash
  ([DC Rainmaker](https://dcrainmaker.com/2025/03/komoots-expanded-paywalls-trying-to-make-sense-of-it.html),
  [BikeRadar](https://www.bikeradar.com/news/komoot-redesign-2025)).
- **What people like:** Apple Maps praised for a clean look and CarPlay; iOS 26
  Preferred Routes and iOS 27 offline-map and avoid-highway voice requests show
  Apple leaning into personal, calmer routing too
  ([Apfelpatient](https://www.apfelpatient.de/en/generally/apple-maps-ios-27-all-new-features-at-a-glance)).

### Apps in general

- People delete apps that were needed once, that take storage, or that nag:
  notification fatigue is a top-five reason
  ([Adobe via PPC Land, 2026](https://ppc.land/adobe-finds-72-of-shoppers-delete-retail-apps-after-one-use/)).
  Forced sign-up in the first session and weak onboarding are common uninstall
  triggers ([Braze](https://www.braze.com/resources/articles/app-uninstalls-totally-unscientific-look-makes-customers-pull-plug)).
- Most users have switched off all notifications for at least one app
  ([Deloitte Ireland](https://www.deloitte.com/ie/en/about/press-room/ireland-sets-screen-time-limits.html)).

### Implications for PeopleMaps

1. **"No ads, no sponsored places, ever" is now a selling point** — say it on the
   App Store page and in About. It already is true (README: "No results are
   sponsored").
2. **Be the opposite of chatty.** Voice should say the turn and, at most, one calm
   fact. No assistant, no AI branding. "Works offline, no account" is the pitch.
3. **Permissions: one, late, explained.** Location only on Start (or the locate
   button), When In Use only, no notifications prompt at all for v1.
4. **First launch = map + search + one sentence.** No carousel, no sign-up.
5. **Explain the route choice in human terms** (we already do: "2 fewer left
   turns across traffic without a signal"). This is the trust lever the big apps
   lack. Never "safe".
6. **Don't nag back to the original route** when the user leaves it; reroute
   quietly (Ferrostar throttling + our calm reroute screen already do this).
7. **Small and storage-light.** Ship the compressed graph (see P5).
8. **If it ever costs money, never paywall what's free today.** Komoot shows the
   cost of taking features away.
9. **Seattle-specific credibility.** Cycling users already know where Apple fails
   (2nd Ave lane). Use a few local, verifiable examples in screenshots.

---

## 3. Packaging, App Store readiness and docs

Findings from `Scripts/generate_project.py`, the generated project, `Package.swift`,
`Core/Resources`, `THIRD_PARTY.md`, `Data/LICENSE.md` and the README.

### Blockers for a TestFlight upload

| # | Finding | Fix |
|---|---------|-----|
| P1 | **No app icon / asset catalog.** The generator only adds `.swift`, `.json`, `.md`; there is no `Assets.xcassets`. Uploads without a 1024 px icon are rejected. | Add `App/Assets.xcassets` with `AppIcon` (single 1024 px, plus dark and tinted variants; iOS 26+ also supports a layered Icon Composer `.icon` file) and `AccentColor` (#248A3D / #30D158). Teach the generator `.xcassets` (folder reference, `lastKnownFileType = folder.assetcatalog`) and set `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`, `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor`. |
| P2 | **No location usage string.** `GENERATE_INFOPLIST_FILE = YES` with no `INFOPLIST_KEY_NSLocationWhenInUseUsageDescription`. On a device, `CoreLocationProvider` will get no authorization (and App Review rejects binaries that link CoreLocation usage without a purpose string). Simulator runs hide this because they use the simulated provider. | Add e.g. "PeopleMaps uses your location only while you're following a route, to show your next turn. It never leaves your iPhone." Do **not** add `UIBackgroundModes location` until background guidance exists (guideline 2.5.4 rejections: [Apple forums](https://developer.apple.com/forums/thread/771202)). |
| P3 | **Signing disabled** (`CODE_SIGNING_ALLOWED = NO`), no `DEVELOPMENT_TEAM`, bundle id `org.peoplemaps.prototype`. | Release config: automatic signing with the team id, a bundle id under a domain you control (`org.peoplemaps` needs to be yours, otherwise use a reverse-DNS you own). Keep Debug simulator unsigned if useful. |
| P4 | **No privacy manifest.** The app has none; Ferrostar 0.59.0 ships none but compiles `UserDefaultsNavigationCache` (UserDefaults is a required-reason API). MapLibre ships its own. Missing declarations fail upload with ITMS-91053 ([Apple forums](https://developer.apple.com/forums/thread/749940)). | Add `App/PrivacyInfo.xcprivacy`: `NSPrivacyTracking = false`, no tracking domains, `NSPrivacyCollectedDataTypes` empty (location is processed on device and not collected), `NSPrivacyAccessedAPITypes` with `NSPrivacyAccessedAPICategoryUserDefaults` / `CA92.1` (needed once we persist anything, and to cover Ferrostar). Teach the generator `.xcprivacy`. Re-check with Xcode's *Generate Privacy Report* on an archive. |
| P5 | **Export compliance key missing.** Every upload will ask. | `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO` (we use no custom crypto). |

### Should fix before external testers

| # | Finding | Fix |
|---|---------|-----|
| P6 | **Bundle size.** `seattle-graph.json` 39 MB → 4.6 MB gzipped; `seattle-map.geojson` 12 MB → 1.6 MB. The IPA is zip-compressed so the *download* is already small, but the *installed* size counts the full 51 MB. | Ship the `.gz` files and unpack to `Library/Caches` (or decode straight from a stream) on first launch, as planned. Longer term, a binary format (e.g. a flat binary or SQLite) loads faster than JSON. On-Demand Resources is deprecated in favour of Background Assets / Apple-hosted asset packs ([WWDC25 session 325](https://developer.apple.com/videos/play/wwdc2025/325), [forum](https://developer.apple.com/forums/thread/807744)); use that only when adding more cities. |
| P7 | **Licence notices incomplete.** `THIRD_PARTY.md` lists MapLibre and OSM but not **Ferrostar** (BSD 3-Clause, © Stadia Maps — redistribution in binary form requires the notice in documentation or other materials) nor its transitive packages, nor **USGS 3DEP** (public domain; credit requested). Only `MapLibre-LICENSE.md` is bundled. | Add Ferrostar (+ its Swift dependencies from `Package.resolved`) to `THIRD_PARTY.md`; bundle an `Acknowledgements` screen (or a Settings.bundle `Acknowledgements.plist`) reachable from About. Keep the visible "© OpenStreetMap" link (ODbL attribution) — already done well. |
| P8 | **Launch screen** is the generated blank one. With a 39 MB JSON parse, users see white then "Opening Seattle…". | `INFOPLIST_KEY_UILaunchScreen` dictionary with `UIColorName = LaunchBackground` (map land colour, light/dark) so launch → map is seamless; shorten parse with P6. |
| P9 | **Localization not set up.** No String Catalog; strings are literals (good — SwiftUI `Text("…")` are already `LocalizedStringKey`), but string-interpolated instructions and `String` values are not extractable. | Add `Localizable.xcstrings` (Xcode extracts on build) even for English only, so plurals ("1 fewer left turn" / "2 fewer…") use the catalog's plural rules instead of code. Set `SWIFT_EMIT_LOC_STRINGS = YES`. |
| P10 | **Orientation keys:** portrait + landscape for iPhone set; iPad keys not set (`UISupportedInterfaceOrientations~ipad`) while the family includes iPad. iPad apps must support all orientations for multitasking. | Either drop iPad for now or add iPad orientations and test. |
| P11 | **App category & age rating** to set in App Store Connect: Navigation; 4+. Navigation apps get a standard "Continued use of GPS…" style warning expectation — add a short note in the description that guidance runs in the foreground only. |
| P12 | **Review notes.** Coverage is a small part of Seattle; reviewers in Cupertino will see "outside coverage". | Review notes: explain coverage, give two place pairs, and mention the debug-free simulated route is not available in Release (or provide a short screen recording). |
| P13 | **Repo hygiene before GitHub:** `Spikes/` (1 GB, untracked, not ignored — contains its own DerivedData), `CLAUDE_HANDOFF.md`, absolute simulator UDIDs in README. | Add `Spikes/*/DerivedData/` to `.gitignore` or drop `Spikes/`; move handoff notes out. |

### Documentation conventions

- README is thorough and honest. Two stale lines now: "This is route comparison,
  not navigation" and "No … location permission … required" — update when stage 4
  lands.
- `PeoplemapsCore` is a Swift package: add a DocC catalog (`Core/PeoplemapsCore.docc`
  with a landing page linking the stress model) — `swift package generate-documentation`
  works with the swift-docc-plugin. Optional, but idiomatic for a package.
- Add `PRIVACY.md` (what's on device, what never leaves) — you'll need a privacy
  policy URL for App Store Connect anyway; a GitHub Pages copy of it is enough.
- Add `CHANGELOG.md` / TestFlight "What to Test" notes per build.

---

## Top 10 actions

### Do before first TestFlight

1. **App icon + AccentColor asset catalog**, wired through `generate_project.py` (P1, D13).
2. **`NSLocationWhenInUseUsageDescription`**, no background mode yet (P2).
3. **`PrivacyInfo.xcprivacy`** with no tracking, no collected data, UserDefaults `CA92.1` (P4).
4. **Signing, bundle id you own, `ITSAppUsesNonExemptEncryption = NO`** (P3, P5).
5. **Ship gzipped data and a coloured launch screen** so the first seconds look like a map, not a spinner (P6, P8).
6. **Acknowledgements: Ferrostar BSD-3, USGS, OSM, MapLibre** in-app and in `THIRD_PARTY.md`; fix the About copy (P7, D12).
7. **iPhone-only for TestFlight** unless iPad is tested (D10, P10).

### Later

8. **Make the panel a real resizable sheet and move map controls to Liquid Glass** (D1, D2) — the biggest step toward feeling native on iOS 26/27.
9. **Locate button + "My location" origin, haptics, Dynamic Type AX layouts** (D3, D6, D7) — then claim Accessibility Nutrition Labels.
10. **Live Activity for guidance** (Dynamic Island, lock screen, CarPlay Dashboard) after foreground guidance is solid on a real phone (D9).
