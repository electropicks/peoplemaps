---
name: product-rules
description: PeopleMaps honesty and UX rules for anything a user reads or hears. Use when writing or changing UI text, voice prompts, route explanations, stress-model labels, README or App Store copy, error and empty states, or when designing a new screen.
---

# Product rules

PeopleMaps suggests the route a Seattle local would pick: the calmer one, not just the fastest. Trust comes from never overclaiming.

## Words

- **Never call a route, street or crossing "safe" or "safer".** Use "calmer", "less stressful", "fewer unsignalled lefts". This applies to UI text, voice, docs and commit messages that become release notes.
- Times are **estimates**: there's no live traffic, closures or signal timing. Never say "will take" or "fastest possible".
- Missing OSM tags are **unknown** and are said to be unknown. Never guess opening hours, sidewalks, signals or bike lanes.
- Open data goes stale, so show its source and date where results are listed (for example "OpenStreetMap, Oct 2026").
- Explain the calmer route in local terms: "Avoids the unsignalled left onto 45th", not a score.
- Place names come from data; don't invent or "clean" them beyond the spoken-text normaliser (`Core/SpokenText.swift`).

## UX

- First launch stays simple: the map and a "Where to?" search, then Favourites and Recents once there are some. No featured or suggested places yet.
- Location: once the map shows on first launch, ask for When-In-Use with the system prompt, once. When allowed, every route starts from Current location (Directions, the preview, the pickers) and Home frames the user's neighbourhood. When denied or unavailable, the start is an empty "Choose start" field and no route shows until it is filled. Never fill in a made-up default place. Start still checks permission, because guidance needs it.
- Apple-first design: system fonts and materials, white/black with one green accent (`.calmer`), and full light/dark and landscape support.
- Motion uses the shared `Motion` timings (`App/PeoplemapsApp.swift`). Respect Reduce Motion, and keep animations off under `--ui-testing`.
- Accessibility: VoiceOver labels on every control, 4.5:1 text contrast, Dynamic Type that doesn't truncate the essentials.
- Walk, bike and drive each have their own stress factors (`Docs/STRESS_MODEL.md`). Don't apply one mode's rule to another.
- Voice: use the best installed voice (`Core/VoiceChoice.swift`), and spell out street abbreviations. Siri voices are not available to third-party apps.
