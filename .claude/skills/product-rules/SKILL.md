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

- First launch stays simple: map, search and featured places. Ask for location only when the user starts guidance or picks Current location.
- Apple-first design: system fonts and materials, white/black with one green accent (`.calmer`), and full light/dark and landscape support.
- Motion uses the shared `Motion` timings (`App/PeoplemapsApp.swift`). Respect Reduce Motion, and keep animations off under `--ui-testing`.
- Accessibility: VoiceOver labels on every control, 4.5:1 text contrast, Dynamic Type that doesn't truncate the essentials.
- Walk, bike and drive each have their own stress factors (`Docs/STRESS_MODEL.md`). Don't apply one mode's rule to another.
- Voice: use the best installed voice (`Core/VoiceChoice.swift`), and spell out street abbreviations. Siri voices are not available to third-party apps.
