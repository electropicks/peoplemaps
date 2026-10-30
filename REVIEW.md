# Review guide

For people and for Claude reviewing a PeopleMaps PR. Review findings are advice: a person approves the merge.

## Passes

1. **Correctness.** Routing and stress model: does each mode keep its own rules? Do the router tests still cover the changed path? Search: ranking, address lookup, typo fallback. Navigation: reroute, arrival, permission paths.
2. **Honesty.** No "safe" anywhere a user reads or hears it. Estimates are called estimates. Unknown tags stay unknown. No Apple Maps data (`Docs/SEARCH.md`).
3. **Data.** `Core/Resources/` changed only through the importer, with the code change in the same PR and sizes noted. New sources need a licence entry in `Data/LICENSE.md`.
4. **App.** Light, dark and landscape. VoiceOver labels. Reduce Motion. Animations go through `Motion`. Evidence screenshots for visible changes.
5. **Performance.** Launch path (graph decode, map parse), memory, and work done in SwiftUI `body`.

## Severity

- **Important:** wrong routes or instructions, a "safe" claim, licence or Apple terms problems, crashes, broken offline use, failing or deleted tests, hand-edited generated files, launch or memory regressions.
- **Nit:** naming, comment wording, small style. Group nits in one comment; don't block on them.

## Skip

Generated files' contents (review the generator instead), `Evidence/` binaries, and lockfile-only churn.
