# Problem reports

Drafted 31 October 2026. Design only; nothing in `App/`, `Core/` or `.github/`
changes with this document. Three tasks build from it in parallel: the backend
(section 5 to 7), the app client (section 2, 3 and 8), and the issue pipeline
(section 6, 9 and the replay tool in section 2.5). Each section names its
interfaces so the tasks can be built and tested apart. One small prerequisite
comes first: the importer writes the graph hash into `Data/provenance.json`
(2.5 step 1), which the app client and the replay tool both read. The
user-facing version of the data rules is `Docs/PRIVACY.md`; keep the two in
step.

Read with `.claude/skills/product-rules/SKILL.md` (no "safe", times are
estimates, unknown is said to be unknown), `Docs/NAVIGATION.md` and
`Docs/ARCHITECTURE.md`.

Decided, not open: Cloudflare Workers and D1 in `Backend/`, served from a
domain we own (7.5) and written so the handlers do not depend on either
(7.1); one GitHub issue per sent report, filed by the Worker only after a
maintainer approves it with one tap (6.1), labelled `app-report`; a silent
"Flag this moment" button during guidance and a "Flagged moments" list at home;
no accounts, a random per-install ID; endpoints snapped to the nearest street
intersection unless the user turns on exact locations for that report; raw
reports kept 90 days (plus Cloudflare's restore window, 5.3), aggregates
after; no IP addresses stored or logged; replay in
`Core` is the point.

## 1. Goals and non-goals

Goals:

- A user who hears a wrong turn, gets a strange calmer route or sees bad map
  data can mark the moment with one tap and send it later, with nothing typed
  on the road.
- Every sent report can be replayed on a Linux box: rebuild the
  `RouteRequest`, run `NativeRouter` on the same data version, rebuild the
  `NavigationPlan`, and land on the same step.
- Nothing leaves the phone without a tap. The user sees every field before
  sending, and can delete what they sent.
- Maintainers work from GitHub issues, so a later workflow can triage them
  automatically.

Non-goals:

- Crash reporting, analytics, usage metrics of any kind.
- Accounts, sign-in, email, push notifications about a report's progress.
- Screenshots or audio. A snapshot is numbers and text we already have.
- App Attest or any device attestation in the first TestFlight builds. It is
  required before App Store release (4.5).
- Reports while the app is offline. Flagging is offline; sending needs a
  connection and says so.

## 2. Data model

Two things exist. A **snapshot** is what the app records on the phone when the
user taps Flag. A **report** is a snapshot plus what the user adds at home,
and is what the app sends. Both are `Codable` in `Core/Reports.swift` so the
replay tool and the tests share them with the app.

### 2.1 Snapshot fields

Recorded on the phone at flag time. "Personal" says whether the field can say
something about the person on its own or with the rest of the report. "Sent"
says what leaves the phone by default.

| Field | Type | Purpose | Personal | Sent by default |
|---|---|---|---|---|
| `id` | UUID string | Identifies the report; the idempotency key for retries | no | yes |
| `flaggedAt` | ISO 8601 | On the phone: ordering the list. Sent rounded down to the hour, UTC, so retention and duplicates can be judged | low (hour only) | hour only |
| `request.mode` | `walk`, `bike`, `drive` | Rebuild the `RouteRequest` | no | yes |
| `request.extraMinutes` | 0 to 20 | Rebuild the `RouteRequest` | no | yes |
| `request.preferences` | object or null | Rebuild the request once the "Calmer means" sheet lands (`Docs/DESIGN.md` 4.6); null until then | no | yes |
| `request.origin`, `request.destination` | endpoint (2.2) | Rebuild the `RouteRequest`. Exact on the phone, snapped when sent | **yes** exact; low snapped | snapped |
| `request.rerouted` | bool | The route being followed came from a reroute, so `origin` is where the user was when the engine rerouted, not where the trip began | no | yes |
| `chosen` | `calmer` or `fastest` | Which card the user picked; which route to compare the replay against | no | yes |
| `route.dataVersion` | 12 hex chars | First 12 hex chars of the SHA-256 of the bundled `seattle-graph.bin`, read from the search index's `graphSHA256` meta row that the importer writes; the app never hashes the file. The replay checks out the same data | no | yes |
| `route.edgeIDs` | [Int] | The directed edges travelled, `Route.edgeIDs`. Exact for this data version; the plan replays from these alone | low (a public route) | yes |
| `route.wayIDs` | [Int64] | OSM way IDs along the route, consecutive duplicates collapsed, so the route reads on any data version and in the issue | low | yes |
| `route.hash` | 64 hex chars | SHA-256 of `Route.id` (edge IDs joined by `-`); a replay compares hashes first | no | yes |
| `route.meters`, `route.seconds`, `route.stress` | Double | The metrics the user saw; a replay must reproduce them | no | yes |
| `route.alternativeHash` | string or null | Hash of the route not chosen (calmer when fastest was chosen and vice versa), null when no calmer route existed | no | yes |
| `position.stepIndex` | Int | The engine's step (`NavigationController.stepIndex`) | low | yes |
| `position.shownStepIndex` | Int | The step on the card: `stepIndex + 1` (the card announces the next maneuver), capped at the last step, except during the set-off card, when it is `stepIndex` (0) and the card still says "Head north on…" | low | yes |
| `position.distanceToManeuver` | metres | Where along the step the user was; the route point is derived from this and the plan, so no coordinate is needed | low | yes |
| `position.remainingMeters`, `position.remainingSeconds` | Double | What the trip bar showed | no | yes |
| `position.cell` | `r<row>c<col>` | The 550 m grid square of the route point at flag time, for the aggregate counts (5.2) | low | yes |
| `location` | exact position (2.2) or null | GPS fix at flag time: lat, lon, horizontal accuracy, course. Null unless exact locations are on for this report | **yes** | no |
| `spoken` | up to 3 of `{text, secondsBefore}` | The last instructions the voice said (after `SpokenText.normalize`), newest last, and how many seconds before the flag each was spoken. The voice says the destination's name in "Arrive at <name>" and "You've arrived at <name>"; the snapshot replaces the name with "your destination" in every text, so an address or saved-place name never enters a report | no | yes |
| `nav.state` | `guiding`, `rerouting`, `paused`, `arrived` | What the engine was doing | no | yes |
| `nav.rerouteCount` | Int | Reroutes so far in this trip | no | yes |
| `nav.muted` | bool | Voice reports with the voice off are read differently | no | yes |
| `nav.voiceQuality` | `default`, `enhanced`, `premium` | From `Core/VoiceChoice.swift`; which tier spoke. Never the voice identifier | no | yes |
| `nav.units` | `mi` or `km` | What the banner and voice used | no | yes |
| `app.version`, `app.build` | strings | `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` | no | yes |
| `device.model` | string | Apple model identifier (`iPhone16,2`) | low | yes |
| `device.os` | string | `iOS 27.1` | low | yes |

Not recorded, on purpose: the device name, locale, time zone, language,
battery, carrier, other apps, screen size, anything from Contacts, Calendar or
Photos, the saved places, recents and favourites, and the trip's history
before the flag. A snapshot is the current moment only.

### 2.2 Endpoints and positions

```jsonc
// endpoint, snapped (the default)
{ "kind": "intersection", "lat": 47.62980, "lon": -122.35931, "osmNode": 53070456, "placeID": "way/37056567" }
// endpoint, exact (only with the per-report toggle on); the snapped form rides along for the public issue
{ "kind": "exact", "lat": 47.62950, "lon": -122.35990, "placeID": "way/37056567",
  "snapped": { "lat": 47.62980, "lon": -122.35931, "osmNode": 53070456 } }
// endpoint removed by the user in review; route replay is not possible, plan replay is
null
// exact position at flag time (only with the toggle on); otherwise the key is null
// accuracy 0 to 10,000 m; course -1 to 360 degrees, or null when the fix has none
{ "lat": 47.63712, "lon": -122.35588, "accuracy": 8, "course": 71 }
```

- **Snapping.** `NativeRouter.nearestIntersection(to:mode:)`, new, public:
  the nearest graph node within 400 m that the mode can use, is in the mode's
  main connected component and has three or more road legs (the router's
  `legs` table). A node with two or more legs if none has three. If none
  within 400 m, the endpoint becomes `null` and the review screen says
  "No intersection near the start; start removed". Coordinates are the node's,
  to five decimals; `osmNode` is `GraphNode.osm`, stable across data versions.
- **`placeID`** is kept only for a public named place: `Place.kind == .place`
  and a category that is not `address`, `dropped pin` or `current location`.
  Addresses, pins and the user's position never carry an ID or a name. A
  public place ID lets the replay use the importer's own snap node
  (`Place.snap`), which is what the app used.
  The ID must also match `^(node|way|relation)/\d{1,19}$`, the only form
  `validate.ts` accepts (at most 32 characters). Any other ID is omitted, such
  as the reroute start `Place(id: "current-location", category: "gps")` built
  in `App/Navigation/OwnRouteProvider.swift`, or a `pin/…` ID
  (`ReportEndpoint.publicPlaceID`). The key is omitted, not sent as `null`.
  The Worker would also accept `"placeID": null` and passes it through, but
  the app never sends it, so the stored body has one shape.
- **`location.course`** is `null` when the fix has no heading (the key stays,
  as `null`); otherwise -1 to 360, the range `validate.ts` accepts. `accuracy`
  is 0 to 10,000.
- Both forms are stored on the phone (exact plus the snapped version computed
  at flag time, while the graph is loaded), so the review screen can switch
  between them without recomputing. Only the chosen form is sent.
- The exact form is also to five decimals (about a metre). More is noise.

### 2.3 Report fields

Added at home. The report is the snapshot plus:

| Field | Type | Purpose | Personal | Sent |
|---|---|---|---|---|
| `category` | `wrong_instruction`, `calmer_bad_choice`, `map_data`, `voice_timing`, `other` | What kind of problem; the issue label | no | yes |
| `note` | string, 0 to 280 chars, or null | One sentence in the user's words. The UI says it will be public and asks not to put names or addresses in it | user's choice | yes |
| `exactLocations` | bool | Per report, default false. True sends the exact endpoints and `location` | no | yes (the flag itself) |
| `sentAt`, `serverID`, `issueURL` | on the phone only | The receipt, so the list shows "Sent, issue #123" | no | never sent |

The install ID and token (4.1) are not report fields. The ID travels in the
bearer token, never in the body, so a report body on disk, in an export or in
an issue says nothing about which install sent it.

### 2.4 The JSON the app sends

`POST /v1/reports`, body `application/json`, at most 64 KB. Keys in this
order; the Worker canonicalises (sorted keys, no whitespace) before hashing,
so order does not matter for idempotency.

```json
{
  "schema": 1,
  "id": "6F1D2C8E-3B0A-4F0B-9C1C-2D4E5A6B7C8D",
  "flaggedAt": "2026-10-31T19:00:00Z",
  "category": "wrong_instruction",
  "note": "It said turn left but the left was a one-way the wrong way.",
  "exactLocations": false,
  "request": {
    "mode": "drive",
    "extraMinutes": 5,
    "preferences": null,
    "origin": { "kind": "intersection", "lat": 47.62980, "lon": -122.35931, "osmNode": 53070456, "placeID": "way/37056567" },
    "destination": { "kind": "intersection", "lat": 47.64521, "lon": -122.33498, "osmNode": 53077201, "placeID": "relation/1047789" },
    "rerouted": false
  },
  "chosen": "calmer",
  "route": {
    "dataVersion": "a1b2c3d4e5f6",
    "edgeIDs": [41822, 41823, 9120, 9121, 9122, 30018, 30019, 30020],
    "wayIDs": [6392710, 6392711, 428156930, 6410023],
    "hash": "3c5e…e9a1",
    "meters": 5230.4,
    "seconds": 744.2,
    "stress": 318.5,
    "alternativeHash": "9b02…17cd"
  },
  "position": { "stepIndex": 3, "shownStepIndex": 4, "distanceToManeuver": 86.5, "remainingMeters": 2890.1, "remainingSeconds": 402.0, "cell": "r4c4" },
  "location": null,
  "spoken": [
    { "text": "In a quarter mile, turn left onto Dexter Avenue North", "secondsBefore": 41 },
    { "text": "Turn left onto Dexter Avenue North", "secondsBefore": 6 }
  ],
  "nav": { "state": "guiding", "rerouteCount": 0, "muted": false, "voiceQuality": "enhanced", "units": "mi" },
  "app": { "version": "0.1.0", "build": "1" },
  "device": { "model": "iPhone16,2", "os": "iOS 27.1" }
}
```

Example values; the IDs and coordinates are illustrative. `schema` is bumped
when a field changes meaning; the Worker rejects unknown schemas with
`invalid_report`.

### 2.5 Replay

The Swift side is `Core/Reports.swift` (types above, `ReportStore`, the
canonical encoder) and a new executable target `ReportReplay` at
`Replay/main.swift`, product `peoplemaps-replay`, declared in `Package.swift`
beside `RouteAudit`. `Tools/` stays the audit tool. Both build on Linux.

```sh
swift run -c release peoplemaps-replay report.json        # prints a JSON result
```

1. **Data version.** The importer writes the full SHA-256 of
   `seattle-graph.bin` as `graphSHA256` in `Data/provenance.json` (it already
   computes it for the search index meta; adding the key regenerates
   provenance, which `Scripts/verify.sh` reproduces byte for byte). Compare
   `route.dataVersion` with the prefix of that value in the checkout. If it
   differs, print `dataVersion: mismatch` and the commit that introduced it:
   `git log --format=%H -S<dataVersion> -- Data/provenance.json`, newest
   first. No file is hashed. The pipeline checks that commit out and runs
   again; its checkout needs `fetch-depth: 0` (9).
2. **Plan replay**, always possible. Build the `Route` from `route.edgeIDs`
   with `NativeRouter.route(ids:mode:)` (made public), then
   `navigationPlan(mode:)`. Print the step at `position.shownStepIndex`, its
   instruction, calm note and distance, the point `distanceToManeuver` metres
   before the step's end, and the spoken texts the plan would produce for the
   last two steps next to `spoken`. Check that `route.hash`, `meters`,
   `seconds` and `stress` reproduce. Any mismatch here means the data version
   or the router changed and is reported as such.
3. **Route replay**, when both endpoints are present. Build
   `RouteRequest(origin:destination:mode:extraMinutes:)`. For each endpoint,
   when `placeID` names a place in `graph.places`, use that `Place`, whose
   `snap` is the importer's node, as the app used (2.2). Otherwise use
   `Place(id: "report/origin", name: "", lat:, lon:, category: "report")`
   with an empty `snap`, so the router snaps by coordinate, which for an
   intersection endpoint is the node itself at 0 m; a place that is only in
   the search index falls back to this too. A report parsed from an issue
   has each endpoint only as a cell (6); the parser then sets the origin to
   the start node of the first edge in `edgeIDs` and the destination to the
   end node of the last, which is where the app's route began and ended, and
   leaves an endpoint the issue shows as removed `null`. Run `compute`, pick
   `chosen`, compare hashes. Print `match`, or `differs` with the way-ID sequences side
   by side and both routes' metrics.

**What snapping loses.** A snapped endpoint moves the start or end to a
junction up to 400 m away. The replayed route can differ from the reported one
in its first and last edges, so the calmer-or-fastest decision can flip when
the two candidates were close, and the snap distance the app disclosed is
gone. For `wrong_instruction`, `map_data` and `voice_timing` the plan replay is
exact regardless, because `edgeIDs` is the route itself. `calmer_bad_choice`
is the category that needs the route replay; the triage comment says
"approximate: endpoints snapped" when the hashes differ only in the first or
last few edges, and asks for exact locations only if that is not enough. A
report flagged after a reroute (`request.rerouted`) starts from where the
engine rerouted; snapped, that origin may land on a junction the user never
passed, so route replay of rerouted trips is best-effort.

## 3. On-device storage

- **Where.** `Application Support/reports/snapshots.json`, a `Codable` array
  of `ReportSnapshot` written atomically after every change, like
  `App/SavedPlacesStore.swift`. Fifty snapshots of a few KB each is under
  1 MB; SQLite is not needed. Under `--ui-testing` the file is
  `snapshots-uitests.json`, removed at launch unless `--keep-saved`.
- **Lifecycle.** Flag writes a snapshot with `status: flagged`. Review and
  Send set `category`, `note`, `exactLocations` and `status: sending`; the
  receipt sets `status: sent` with `sentAt`, `serverID`, `issueURL`. A failed
  send goes back to `flagged` with the fields kept and `lastError` for the
  list to show. `status: withdrawn` after a server-side delete, until the user
  removes it locally.
- **Limit.** Keep the last 50. When a flag would make 51, drop the oldest
  `sent` or `withdrawn` snapshot; if there is none, drop the oldest `flagged`
  one and the list shows "An older unsent moment was removed to make room".
  Exact fields are kept on the phone as long as the snapshot is; they are not
  trimmed separately.
- **Keychain.** Install ID and bearer token in the Keychain,
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronised, so a
  restore onto another phone starts with no ID and no reports.
- **Export.** "Export" on a snapshot or on the list puts the JSON exactly as
  it would be sent (same encoder, same field choices, including the
  `exactLocations` setting) in the share sheet as `report-<id>.json`. This is
  how "review every field" is literal: the review screen shows the same
  bytes, pretty-printed.
- **Delete.** Swipe to delete one snapshot; "Delete all flagged moments"
  deletes the file. Neither contacts the server. "Delete my reports" (4.4)
  shows the count of local `sent` snapshots ("Delete 3 sent reports and your
  report ID from our server?"), and on confirmation calls `DELETE
  /v1/installs/me` and marks local copies `withdrawn`. The count is local;
  nothing is fetched first.
- **Network.** No request is made automatically, anywhere: not when the list
  opens, not at launch, not on a timer. The client contacts the server only
  on Send, on "Check status" (a button shown while a sent report's issue is
  pending, which calls `GET /v1/reports` and updates every local row the
  answer names) and on "Delete my reports". Each is one explicit tap.
- **Backups.** The `reports/` folder is marked `isExcludedFromBackup`,
  because it holds exact coordinates, so flagged moments neither back up nor
  restore (open question 6). No copies in UserDefaults, nothing in iCloud.

## 4. HTTP API

Base URL per build (7.5). JSON in and out, `Content-Type: application/json`.
Every response carries `Cache-Control: no-store`. The Worker reads no cookies
and sets none. TLS only; `http://` is only for `wrangler dev`.

### 4.1 Install token

```
POST /v1/installs
Body: { "schema": 1, "app": { "version": "0.1.0", "build": "1" } }
201 { "installID": "8C2F…", "token": "pm_…" }
```

- No authentication. `installID` is a UUID v4 the app shows the user as
  "Your report ID". `token` is 32 random bytes, base64url, prefixed `pm_`.
  The Worker stores SHA-256 of the token and never the token. `app` is
  stored as `installs.app_version` ("0.1.0 (1)") and updated from each
  accepted report's `app`, so a maintainer can tell which builds still send.
- The app calls this once, on the first Send, not at launch, so an install
  that never sends anything never contacts the server. Rotate (8.3) calls it
  again and replaces both Keychain items.
- Rate limit: per client IP at the edge, plus a global hourly ceiling on
  mints, 4.6. This is the route an abuser hits to reset every per-install
  cap, so it has the tightest limits.

Every other endpoint needs `Authorization: Bearer pm_…`. A token that does
not match an install is `401 unauthorized`: the old install was deleted
server-side (4.4, 5.3) or never existed. The app wipes its two Keychain items
and shows "Your report ID was reset". It mints a new token only inside a
Send (then retries the send once); a 401 on "Check status" or "Delete my
reports" ends there, with the message, and the next Send mints. No request
mints a token on its own.

### 4.2 Send a report

```
POST /v1/reports
Body: the report (2.4); its `id` is the idempotency key
202 { "id": "6F1D…", "receivedAt": "2026-10-31T21:00:00Z", "issue": null, "issueState": "held", "expiresAt": "2027-01-29T21:00:00Z" }   // stored; filed after approval (6.1)
201 { "id": "6F1D…", "receivedAt": "…", "issue": { "number": 123, "url": "https://github.com/electropicks/peoplemaps/issues/123" }, "issueState": "opened", "expiresAt": "…" }   // only with HOLD_FOR_APPROVAL off (dev)
200 { the row's current state, same shape }                                // a retry with the same id and body
409 { "error": "conflict", "message": "Report 6F1D… was already sent with different content." }
503 { "error": "storage_unavailable", "message": "…" } + Retry-After            // D1 refused the write (4.6); nothing kept
```

- The Worker validates the shape (`Backend/src/validate.ts` mirrors 2.4:
  types, enum values, `note` length, `edgeIDs` and `wayIDs` non-empty and at
  most 2,000 entries, coordinates inside the coverage bounds plus 1 km, a
  `location` and exact endpoints only when `exactLocations` is true; the
  length caps below). Failure is `400 invalid_report` with `field`, a dotted
  path into the body such as `request.origin.lat` or `spoken[1].text`.
- Stores the row (5.1) with `issue_state = held`, bumps the aggregate (5.2)
  and answers 202. Nothing goes to GitHub until a maintainer approves the
  report (6.1). The app shows "Sent, issue pending" with a "Check status"
  button (3); that line covers held, waiting for the daily cap and GitHub
  being down alike, since to the sender they are the same: accepted, not
  public yet. With `HOLD_FOR_APPROVAL` off (the dev environment only, 7.2)
  the Worker files at once and answers 201, or 202 with `pending` if GitHub
  fails or the cap is reached.
- Idempotent on the body's `id`; there is no separate header. The Worker
  canonicalises the body (sorted keys, no whitespace) and hashes that; it
  never compares the app's bytes, so key order and whitespace cannot cause a
  conflict. A retry with the same `id` and canonical hash returns 200 with
  the row's current state, including the issue once the cron has filed it. A
  different body under the same `id` is a 409; the app regenerates the
  report with a new `id` only if the user edits and sends again.
  The 409 is also returned when the same `id` arrives from a different
  install, whatever the body: a send that timed out after the Worker stored
  it, then retried after Rotate (8.3), is a new token for an old `id`. The
  app does not treat it as success. It keeps the snapshot `flagged` with
  `lastError: conflict` (`Core/ReportsClient.swift` has no 409 special case)
  and the `id` unchanged, so an unedited re-send gets the same 409. Editing
  the category, note or exact setting gives the snapshot a new `id` on the
  next Send, which goes through. The old row stays on the server under the
  old install and ages out at 90 days.
- **Length caps**, counted in Unicode code points (`[...s].length`) by
  `validate.ts`: `spoken[i].text` 1 to 500, `note` null or at most 280,
  `app.version` and `app.build` 1 to 32,
  `device.model` and `device.os` 1 to 64, `flaggedAt` 20, `id` a 36-character
  UUID. `spoken` has at most 3 entries and `location.accuracy` is 0 to
  10,000. `POST /v1/installs` checks the same `app.version` and `app.build`
  caps (4.1) but counts UTF-16 code units (`String.length`), so a string with
  characters outside the Basic Multilingual Plane is shorter there than the
  same string here. The two agree for ASCII, which real version and build
  strings are; see question 23.
- Rate limit: `REPORTS_PER_DAY` per install (a `vars` value, 7.2: 20 in
  production, 50 in dev, so one tester can exercise the client), counted from
  the install's own rows in `reports` (`received_at` in the last 24 hours),
  plus the edge limits of 4.6.

### 4.3 Read own reports

```
GET /v1/reports            200 { "reports": [ <the 4.2 response shape, plus "category"> ] }
GET /v1/reports/{id}       200 { one element of the same shape } | 404 not_found
```

Only the sender's install. Each element is the 4.2 body (`id`,
`receivedAt`, `issue`, `issueState`, `expiresAt`) with `category` added.
`issueState` is `held`, `pending`, `opened`, `failed` or `rejected` (5.1);
the app shows `rejected` as "Sent, not published" and the rest that are not
`opened` as "Sent, issue pending". Called only from
the "Check status" button (3); nothing calls it when the list opens, and
"Delete my reports" does not call it either, since the count it shows is
local. Never returns the body; the phone has it.

### 4.4 Delete

```
DELETE /v1/reports/{id}    204 | 404 | 503 github_unavailable
DELETE /v1/installs/me     204 | 503 github_unavailable
```

`DELETE /v1/reports/{id}` deletes one report's row and its issue.
`DELETE /v1/installs/me` deletes every report of the install and the install
row itself, in one D1 batch, and each report's issue the same way. An issue
is deleted outright with the GraphQL `deleteIssue` mutation (`issue_node_id`
from 5.1), not edited or closed: GitHub keeps every edit of an issue body
publicly viewable in its history, so editing would withdraw nothing. Deleting
takes the issue's comments with it. The REST API has no issue delete, and
`deleteIssue` succeeds only for an actor with admin rights on the repository,
which sets the token's scope (6). A report still held or rejected (6.1) has
no issue, so its delete is only the row.

Deleting an issue is not erasure. GH Archive and other mirrors of GitHub's
public event stream record the issue body when it is opened, GitHub emails
the body to everyone watching the repository, and search engines and other
caches may hold a copy. None of these can be recalled by us or by GitHub.
`Docs/PRIVACY.md` and the delete confirmation (8.2) say so; this is the main
reason issues are held for approval and the body is minimised (6). The
GitHub call comes first; if it
fails, the rows stay and the response is `503 github_unavailable`, so a
report is never gone from the phone while its issue is still public. The app
wipes its Keychain items only after a `204` from `DELETE /v1/installs/me`
("Delete my reports" is also "start over"). On a `503` it keeps the install
ID and token, so the user can tap Delete again; a wiped token could not
authorise the retry. A 401 wipes them too (4.1), since that install is gone.
Rate limit: the per-minute ceiling of 4.6.

### 4.5 Maintainer fetch of exact fields

```
GET /v1/maintainer/issues/{number}/report
Authorization: Bearer <the maintainer's own GitHub token>
200 { "id", "receivedAt", "report": <the stored public body>, "exact": { "origin": …, "destination": …, "location": … } | null }
```

- The Worker calls GitHub `GET /user` with the presented token to get the
  login, then `GET /repos/electropicks/peoplemaps/collaborators/{login}/permission`
  with its own `GITHUB_TOKEN`, and requires `write`, `maintain` or `admin`.
  No new secret, no list of people in the Worker. 403 otherwise.
- Presented tokens are used for the two calls and dropped. The Worker writes
  one row to `maintainer_reads` (5.1): issue number, login, hour; so the
  sender's data has an audit trail. Nothing else is logged.
- This is for people. The automatic pipeline (9) replays from the issue and
  never calls this endpoint; see open question 3 for giving Actions access
  without a secret.
- **Before App Store release, not for the first TestFlight builds:** App
  Attest on `POST /v1/installs`, so a token can only be minted by a genuine
  copy of the app. The install flow already has the one round trip it would
  need. Verifying an attestation will not fit the Free plan's 10 ms CPU per
  request, and the one edge library found lists Workers support as unknown,
  so this step budgets Workers Paid at $5 a month (open question 19) and
  measures the CPU cost before it ships.

### 4.6 Rate limits, errors, what is not kept

- Minting a token needs no identity, so every per-install cap can be reset
  by minting again. The limits that hold against that are keyed by client IP
  at Cloudflare's edge, where our code and database never see or store an
  IP. Three Workers rate-limiting bindings in `wrangler.jsonc`, each counting
  in memory at the edge over a 60-second window and persisting nothing:
  `RL_AUTH`, 10 per minute keyed on the token hash, for every authenticated
  route; `RL_INSTALLS`, 2 per minute, for `POST /v1/installs`; and
  `RL_REPORTS`, 10 per minute, for `POST /v1/reports`; the last two keyed on
  the client IP. The binding's period is 10 or 60 seconds, so the key is the
  bare `cf-connecting-ip` value, read in `src/ratelimit.ts` and passed
  straight to the binding; it is never hashed into a column, logged or kept
  past the call. The Worker is on our own domain from the first release
  (7.5), so if the zone's plan offers hourly windows at no cost, the same
  two limits move to a WAF rate-limiting rule on the zone (installs 5 per IP
  per hour, reports 30 per IP per hour), and the Worker stops reading the IP
  at all; otherwise the bindings stay. Exceeding a limit is `429 rate_limited`
  with `Retry-After`.
- **The mint route** is where a flood starts, since a fresh token resets
  every per-install cap. Besides `RL_INSTALLS` it has a global ceiling,
  `INSTALLS_PER_HOUR` (`vars`, 60), counted from `installs.created_at` in the
  current hour (one indexed count, strictly consistent); over it, `429
  rate_limited` until the hour turns. The binding counts per Cloudflare
  location and is approximate, so a flood spread across locations gets more
  than 2 a minute per IP. Before release a test sends mints from several
  regions; if the binding lets through clearly more than its limit, the
  per-IP limit moves to one Durable Object, `MintGate`, that every mint passes
  through: it counts mints per client IP per minute in memory, clears the
  map every minute, never writes an IP to its storage, and is exact rather
  than per location. SQLite-backed Durable Objects are on the Free plan;
  check that again when this is built.
- A global daily cap on issues filed, `ISSUE_DAILY_CAP` (`vars`, 200), counted
  from `reports.issue_filed_at` today (UTC). Approved reports over the cap
  stay `pending`; the retry cron (5.3) files them the next day, oldest first.
  This bounds what a flood can put on GitHub in a day without refusing
  anyone's report. The per-install daily cap (4.2) comes from the install's
  own rows.
- **Degrade mode: accepted, issue pending.** Whenever the row is stored but
  no issue exists yet (held, approved over the daily cap, GitHub down), the
  send answers 202 with `"issue": null` and the app shows "Sent, issue
  pending" (4.2). That is the normal state, not an error. D1's Free daily
  limits (5 million rows read, 100,000 rows written, enforced since
  2026-09-01) are different: once spent, every query fails until 00:00 UTC,
  and a report costs about ten row writes with its indexes and aggregate, so
  a flood that gets past the limits above can spend them. Then nothing can
  be stored, and the Worker does not pretend otherwise: `POST /v1/reports`
  and `POST /v1/installs` answer `503 storage_unavailable` with
  `Retry-After` set to 00:00 UTC, and the app keeps the report flagged with
  "The report server is full for today. Try again after <local time>." The
  report is not parked in KV, R2 or memory, since a second store would need
  its own retention and its own line in the policy. Both crons fail that day
  and catch up on their next run.
- Errors are `{ "error": code, "message": text, "field"?: path }`. `field`
  is a dotted path into the request body (`request.origin.lat`,
  `spoken[1].text`). Codes: `unauthorized` 401, `forbidden` 403, `not_found`
  404, `invalid_report` 400, `too_large` 413, `conflict` 409, `rate_limited`
  429, `github_unavailable` 503 (on 4.4, 4.5 and approval; sends get a 202
  instead), `storage_unavailable` 503 (D1 limits spent, above), `internal`
  500.
- The Worker never logs a request object, a header, an IP, a user agent or a
  body. `observability.enabled` is false and
  `observability.logs.invocation_logs` is false in `wrangler.jsonc` (7.2), so
  Workers Logs writes no per-request entry with headers, and `console.*`
  is allowed only with a constant string plus a count or a status code. A
  test greps `src/` for `console.` and fails on anything else. Cloudflare as
  the host still sees connection details to serve the request; that is said
  in `Docs/PRIVACY.md`.
- **Before the policy is published**, deploy a throwaway test Worker with the
  same `observability` block, send it requests, and read what Workers Logs
  and the dashboard's request views record for it. `Docs/PRIVACY.md` says
  only what that check showed. Cloudflare changes Workers Logs pricing on
  2026-12-01; recheck the defaults and the free allowance then, since a
  pricing change can come with changed defaults.
- Request bodies over 64 KB are refused before parsing (`content-length`
  first, then a streaming count). No CORS: the API is for the app, not
  browsers.

## 5. D1 schema, migrations, retention

### 5.1 Tables

`Backend/migrations/0001_init.sql`, applied by `wrangler d1 migrations apply`
in the deploy job (7.3) and by the test harness before each run.

```sql
CREATE TABLE installs (
  id            TEXT PRIMARY KEY,                 -- UUID shown in the app
  token_hash    TEXT NOT NULL UNIQUE,             -- SHA-256 hex of the bearer token
  app_version   TEXT NOT NULL,                    -- "0.1.0 (1)" from the install call, then from each accepted report
  created_at    TEXT NOT NULL,                    -- ISO 8601, hour precision
  last_seen_at  TEXT NOT NULL                     -- hour precision; set on every authenticated request; for pruning idle installs
);
CREATE INDEX installs_created ON installs(created_at);  -- the hourly mint ceiling (4.6)

CREATE TABLE reports (
  id             TEXT PRIMARY KEY,                -- report UUID from the app; the idempotency key
  install_id     TEXT NOT NULL REFERENCES installs(id) ON DELETE CASCADE,
  received_at    TEXT NOT NULL,                   -- hour precision
  expires_at     TEXT NOT NULL,                   -- received_at + 90 days
  body_hash      TEXT NOT NULL,                   -- SHA-256 of the canonical body, to spot a changed retry
  category       TEXT NOT NULL,
  mode           TEXT NOT NULL,
  data_version   TEXT NOT NULL,
  app_version    TEXT NOT NULL,
  cell           TEXT NOT NULL,                   -- aggregate cell of the flag point (5.2)
  public_json    TEXT NOT NULL,                   -- the body with exact fields removed; the issue is built from it, coarser still (6)
  exact_json     TEXT,                            -- {origin, destination, location} when exactLocations; else NULL
  issue_number   INTEGER,
  issue_node_id  TEXT,                            -- GraphQL node ID, for deleteIssue (4.4)
  issue_url      TEXT,
  issue_filed_at TEXT,                            -- hour precision; counts against the daily cap (4.6)
  issue_state    TEXT NOT NULL DEFAULT 'held',    -- held | pending | opened | failed | rejected (6.1); a deleted report has no row
  reviewed_by    TEXT,                            -- GitHub login that approved or rejected it (6.1)
  issue_attempts INTEGER NOT NULL DEFAULT 0,
  issue_error    TEXT                             -- last GitHub status code and message, no request data
);
CREATE INDEX reports_install ON reports(install_id);
CREATE INDEX reports_expires ON reports(expires_at);
CREATE INDEX reports_pending ON reports(issue_state) WHERE issue_state = 'pending';
CREATE INDEX reports_held ON reports(received_at) WHERE issue_state = 'held';
CREATE INDEX reports_filed ON reports(issue_filed_at) WHERE issue_filed_at IS NOT NULL;
CREATE UNIQUE INDEX reports_issue ON reports(issue_number) WHERE issue_number IS NOT NULL;

CREATE TABLE aggregates (
  week      TEXT NOT NULL,                        -- ISO week, "2026-W44"
  cell      TEXT NOT NULL,
  category  TEXT NOT NULL,
  mode      TEXT NOT NULL,
  count     INTEGER NOT NULL,
  PRIMARY KEY (week, cell, category, mode)
);

CREATE TABLE maintainer_reads (
  issue_number INTEGER NOT NULL,
  login        TEXT NOT NULL,
  read_at      TEXT NOT NULL                      -- hour precision; rows older than 90 days are pruned (5.3)
);
```

`PRAGMA foreign_keys` is on in D1, so deleting an install deletes its
reports. Migrations are numbered `000N_name.sql` and never edited after they
ship; a change is a new file.

### 5.2 Aggregates

`cell` is a grid square about 550 m on a side over the coverage bounds:
`r<row>c<col>` with row `floor((lat - 47.615) / 0.005)` and col
`floor((lon + 122.390) / 0.0075)` of the flag point, the route point
`distanceToManeuver` metres before the end of the shown step. The north edge
falls inside row 12 and the east edge is exactly column 12, so the app clamps
row to 0 to 12 and column to 0 to 11 (a point on the east edge lands in
column 11). The Worker has no graph, so the app computes the cell and sends
it as `position.cell`; the Worker checks it is a cell of that grid (rows 0 to
12, columns 0 to 11) and stores it unchanged.

On every accepted report, `INSERT … ON CONFLICT DO UPDATE SET count = count + 1`
for `(week of received_at, cell, category, mode)`. Deletes do not decrement:
a count per square per week says nothing about a person, and decrementing
would let a delete be observed. Aggregates are kept indefinitely and are the
only thing left after 90 days. Any published view of them (none planned)
hides cells with fewer than three reports in the week.

### 5.3 Cron triggers

Two schedules in `wrangler.jsonc`, one `scheduled` handler switching on
`event.cron`:

- `17 3 * * *` **retention.** `DELETE FROM reports WHERE expires_at < now()`;
  `DELETE FROM installs WHERE last_seen_at < now() - 365 days AND NOT EXISTS (reports)`;
  `DELETE FROM maintainer_reads WHERE read_at < now() - 90 days`.
  The expired rows' issues stay on GitHub as they are: they are already
  public and hold no exact fields. Logs one line: counts.
- `7 * * * *` **issue retry.** For up to 20 rows with `issue_state = pending`
  and `issue_attempts < 10`, oldest first and within the daily cap (4.6),
  try to file the issue (6). A cap hold does not count as an attempt. After
  10 failures the row goes `failed` and a maintainer sees it in
  `wrangler d1 execute`; the app shows "Sent, issue pending" until then.
  `held` rows are never filed by the cron; only an approval (6.1) moves a
  row to `pending`. A held report nobody approves expires at 90 days like
  any other.

**Time Travel.** D1 keeps a restorable copy of the database (Cloudflare's
Time Travel) for 7 days on the Workers Free plan and 30 days on Workers Paid.
The window cannot be shortened or turned off. Only the maintainers'
Cloudflare account can restore from it; it is not reachable from the Worker
or the API. So "deleted after 90 days" is honestly "deleted after 90 days and
restorable by Cloudflare for 7 more": a row deleted by the user or by
retention is fully gone 7 days after the delete on Free, 30 on Paid.
`Docs/PRIVACY.md` gives the Free figure. Moving to Paid (open question 19)
changes the policy text in the same PR, and so does moving to another host.

## 6. The GitHub issue

The Worker files one issue per approved report (6.1) with its
`GITHUB_TOKEN`. Deleting an issue (4.4) uses the GraphQL `deleteIssue`
mutation, which only an actor with admin rights on the repository can run,
so the token is a fine-grained token created by a repository admin, for this
repository only, with Issues read and write, Metadata read, and
Administration read and write. Administration write is far more than filing
issues needs (it can change repository settings), which is why the token
lives only as a Worker secret (7.2) and is never given to Actions. If the
delete test against a scratch repository shows `deleteIssue` works from an
admin's token with Issues write alone, Administration is dropped; the first
deploy settles it, and the scope is written into `Backend/README.md`. The
app never holds a GitHub token.

### 6.1 Held for approval

Nothing is filed automatically. A sent report is stored `held` (4.2), and
the Worker files it only after a maintainer taps Approve. At a few reports a
day this is one tap each, and it means a note with a name, an address or
abuse in it never reaches GitHub, where deletion does not erase (4.4).

```
GET  /maintainer                              a static page, no data in it
GET  /v1/maintainer/held                      200 { "reports": [ { "id", "receivedAt", "category", "issuePreview": { "title", "body" } } ] }
POST /v1/maintainer/reports/{id}/approve      200 { "issueState": "opened" | "pending", "issue"? } | 404 | 409 not held
POST /v1/maintainer/reports/{id}/reject       200 { "issueState": "rejected" } | 404 | 409 not held
```

- Same authentication as 4.5: the maintainer's own GitHub token, checked for
  `write`, `maintain` or `admin`, then dropped. `reviewed_by` (5.1) records
  the login.
- `/maintainer` is one HTML page served by the Worker (`src/maintainer.ts`),
  same origin, so there is still no CORS. It asks for the token, keeps it in
  `sessionStorage`, lists held reports oldest first with the exact title and
  body the issue would get, and has Approve and Reject on each. The preview
  is built by the same `src/issue.ts` functions as the real issue.
- Approve sets `pending` and files at once within the daily cap (4.6);
  over the cap or with GitHub down it stays `pending` for the retry cron
  (5.3). Reject sets `rejected`: the row is kept until it expires, so the
  sender can still see "Sent, not published" and delete it, but it is never
  filed. Exact fields are not on the page; 4.5 is still the only way to them.
- `HOLD_FOR_APPROVAL` (`vars`, 7.2) is `"true"` in production and `"false"`
  in the dev environment, so a tester exercises the whole send-to-issue path
  without a reviewer.

**Issue form** `.github/ISSUE_TEMPLATE/app-report.yml` (added by the
pipeline task). People can also file it by hand, so one parser serves both.

```yaml
name: App report
description: A problem flagged in the PeopleMaps app. Filed by the app's backend; people can file it too.
title: "[app-report] "
labels: ["app-report"]
body:
  - type: dropdown
    id: category
    attributes:
      label: Category
      options: [wrong_instruction, calmer_bad_choice, map_data, voice_timing, other]
    validations: { required: true }
  - type: textarea
    id: note
    attributes: { label: What happened, description: One or two sentences. No names or addresses, please. }
  - type: input
    id: data-version
    attributes: { label: Data version }
    validations: { required: true }
  - type: input
    id: app-version
    attributes: { label: App version }
  - type: input
    id: flagged-at
    attributes: { label: Flagged at, description: "Hour, UTC, for example 2026-10-31T19:00:00Z" }
  - type: textarea
    id: request
    attributes: { label: Route request, render: json }
  - type: textarea
    id: route
    attributes: { label: Route, render: json }
  - type: textarea
    id: position
    attributes: { label: Position, render: json }
  - type: textarea
    id: spoken
    attributes: { label: Spoken instructions, render: json }
  - type: textarea
    id: nav
    attributes: { label: Navigation state, render: json }
  - type: input
    id: device
    attributes: { label: Device }
```

The REST API cannot submit a form, so the Worker builds the body in the
shape GitHub renders a form into: `### <Label>` headings in the form's order,
each followed by the value, JSON fields in fenced `json` blocks. A parser that
splits on `### ` headings reads both a Worker-filed and a hand-filed issue.

**Title.** `[app-report] <Category words>: "<instruction of the shown step>" (<mode>, <dataVersion>)`
for instruction and voice categories, with the instruction taken from the
last `spoken` text or, when none or when `nav.state` is `arrived`,
"step <shownStepIndex>". The arrived rule is belt and braces for 2.1: the
title never carries an arrival utterance. For
`calmer_bad_choice`: `[app-report] Calmer route questioned: <origin cell> → <destination cell> (<mode>, <dataVersion>)`,
the 550 m cells of 5.2, never a street name.
For `map_data` and `other` the same with "Map data" or "Other". Category
words: Wrong instruction, Calmer route questioned, Map data, Voice or timing,
Other.

**Body.** Category; What happened (the note, or "No note"); Data version;
App version; Flagged at (the hour, UTC, as sent); Route request (mode, extra
minutes, preferences, each endpoint as its 550 m cell only, or `removed`, `rerouted`); Route
(`chosen`, `dataVersion`, `hash`, `alternativeHash`, `meters`, `seconds`,
`stress`, `wayIDs`, `edgeIDs`); Position; Spoken instructions; Navigation
state; Device. Everything the replay (2.5) needs is in the body; the parser
in 9 fills `exactLocations: false` and `location: null`, and takes the
endpoints from the route's first and last nodes (2.5 step 3). A trailing HTML
comment `<!-- report:<id> -->` carries the report ID so 4.5 can find the row
by issue number even if the DB index is lost; the ID is random and says
nothing about the sender. A line at the end: "Filed by the PeopleMaps
reports backend from a report the sender reviewed and sent. Times in the app
are estimates; a calmer route is a preference, not a rating."

**Omitted from the issue, even when stored:** exact endpoints, exact
`location`, the `exactLocations` flag, the install ID, the receipt time
beyond the hour, and the snapped endpoints' coordinates, `osmNode` and
`placeID`: each endpoint is shown as its cell (`r<row>c<col>`, computed by
the Worker from the snapped coordinates with the 5.2 formula). If the user
turned exact locations on, the issue says "Exact locations: available to
maintainers (section 4.5)" under Route request. `public_json` always has
the snapped intersection endpoints (the `snapped` forms the app sends inside
each exact endpoint, 2.2), and `exact_json` has the rest.

**What coarsening does not hide.** `edgeIDs` and `wayIDs` stay in the issue
because the plan replay needs the whole route, and a route starts and ends at
its snapped intersections. Anyone with the map data can read those two
corners off the first and last edges. Coarsening keeps coordinates, place
names and IDs out of the text and the title; it does not make the ends of the
route unknowable. Section 8.2 and `Docs/PRIVACY.md` say this, and removing an
endpoint in review removes it from the request, not from the route. Trimming
the published route is open question 22.

**Labels.** `app-report`, `report:<category>`, `mode:<mode>`. The pipeline
adds `triage:*` (9). A deleted report's issue is deleted, not relabelled
(4.4). The five `report:*`, three `mode:*` and the `triage:*` labels are
created once by the pipeline task.

## 7. Backend layout

### 7.1 Tree

```
Backend/
  README.md               run, test, deploy, secrets (points here)
  package.json            wrangler, typescript, vitest, @cloudflare/workers-types; @cloudflare/vitest-pool-workers optional
  wrangler.jsonc          see 7.2
  tsconfig.json
  vitest.config.ts        node environment, SQLite store with the migrations applied (7.3)
  vitest.workers.config.ts  the same tests in workerd through Miniflare, when it runs without login
  migrations/0001_init.sql
  src/index.ts            the only Cloudflare-specific entry: builds Deps from env, fetch router, scheduled handler
  src/deps.ts             Deps { store, github, limits, clock, vars }; the interfaces handlers take
  src/store.ts            Store interface: installs, reports, aggregates, maintainer_reads; plain SQL over a `run/all/batch` shim
  src/store-d1.ts         the shim over the D1 binding
  src/installs.ts         POST /v1/installs, DELETE /v1/installs/me, token hashing
  src/reports.ts          POST, GET, DELETE /v1/reports
  src/maintainer.ts       GET /v1/maintainer/issues/{n}/report, the approval routes and page (6.1)
  src/validate.ts         schema check of 2.4; also `canonical(body)` and `splitExact(body)`
  src/issue.ts            title and body builders (6), pure functions
  src/github.ts           create and delete issues; the only module that reads GITHUB_TOKEN
  src/ratelimit.ts        the three bindings and the mint ceiling of 4.6; the only module that reads cf-connecting-ip
  src/cells.ts            cell validation (5.2)
  src/retention.ts        the two cron jobs
  src/errors.ts           the error envelope
  test/*.test.ts          one file per src module, plus test/fixtures/report.json (2.4)
  test/store-sqlite.ts    the same shim over node's built-in `node:sqlite`, for the tests
```

Handlers are plain functions, `(request, deps) => Response`, and the cron
jobs `(deps) => counts`. None of them imports anything from Cloudflare or
reads `env`; only `src/index.ts` and `src/store-d1.ts` know the platform. The
SQL is plain SQLite, so moving to another SQLite host (Turso, a VM, a
container) is a new shim and a new entry file, not a rewrite.

### 7.2 `wrangler.jsonc`

```jsonc
{
  "name": "peoplemaps-reports",
  "main": "src/index.ts",
  "compatibility_date": "2026-10-01",
  "workers_dev": false,
  "preview_urls": false,
  "routes": [{ "pattern": "reports.<our domain>", "custom_domain": true }],
  "observability": { "enabled": false, "logs": { "invocation_logs": false } },
  "vars": { "GITHUB_REPO": "electropicks/peoplemaps", "RETENTION_DAYS": "90", "REPORTS_PER_DAY": "20", "ISSUE_DAILY_CAP": "200", "INSTALLS_PER_HOUR": "60", "HOLD_FOR_APPROVAL": "true" },
  "env": { "dev": { "vars": { "GITHUB_REPO": "electropicks/peoplemaps", "RETENTION_DAYS": "90", "REPORTS_PER_DAY": "50", "ISSUE_DAILY_CAP": "200", "INSTALLS_PER_HOUR": "60", "HOLD_FOR_APPROVAL": "false" } } },
  "d1_databases": [{ "binding": "DB", "database_name": "peoplemaps-reports", "database_id": "<filled in after wrangler d1 create>", "migrations_dir": "migrations" }],
  "unsafe": { "bindings": [
    { "name": "RL_AUTH", "type": "ratelimit", "namespace_id": "1001", "simple": { "limit": 10, "period": 60 } },
    { "name": "RL_INSTALLS", "type": "ratelimit", "namespace_id": "1002", "simple": { "limit": 2, "period": 60 } },
    { "name": "RL_REPORTS", "type": "ratelimit", "namespace_id": "1003", "simple": { "limit": 10, "period": 60 } }
  ] },
  "triggers": { "crons": ["17 3 * * *", "7 * * * *"] }
}
```

The database ID is not a secret and is committed. The database is created
once by hand with `wrangler d1 create peoplemaps-reports --location wnam`
(open question 10). `npm run dev` uses `--env dev`, so a tester gets the
higher per-install cap. `workers_dev` and `preview_urls` are off, so the
Worker answers only on our domain: the app's URL never names the vendor, and
a move to another host changes DNS, not the app (7.5). `invocation_logs`
stays false even if `observability` is later turned on for debugging (4.6).

**Secrets.** `CLOUDFLARE_API_TOKEN` (Workers Scripts: Edit, D1: Edit, on
this account) and `CLOUDFLARE_ACCOUNT_ID` are environment secrets of the
GitHub Environment `production` (7.3), not repository secrets: a repository
secret with D1 edit rights would let any workflow merged to `main` read
`exact_json`, and the environment's required reviewer stops that. One Worker
secret, `GITHUB_TOKEN`, the fine-grained admin-issued token of 6 (it must
be able to run `deleteIssue`, 4.4), set with
`wrangler secret put GITHUB_TOKEN` from the maintainer's machine, never
through Actions. Nothing else.

### 7.3 Tests, local run, CI, deploy

- `npm test` runs vitest under node (22.13 or later) against
  `test/store-sqlite.ts`: an in-memory SQLite database with the same
  migrations applied, no account, no login, no Miniflare. The handlers get
  the same `Deps` as in production with the store, GitHub and limits
  swapped (7.1). `npm run test:workers` runs the same files in workerd
  through `@cloudflare/vitest-pool-workers` and D1; CI runs it too while it
  works without a Cloudflare login, but it is not required, so the suite
  passes with or without Miniflare. GitHub is a `fetch` mock
  (`test/github.mock.ts`) asserting the exact request the Worker makes.
  Tests cover: mint and reuse a token;
  reject a bad token; send, retry with same body (200), retry with changed
  body (409); a retry after the cron filed the issue returns it; validation
  of each field with its `field` path; exact fields split out of
  `public_json`; issue title and body for each category, and the arrived
  title; a send is stored `held` and nothing reaches GitHub; approve files
  it and reject never does, both only with maintainer permission; the issue
  body and title show endpoints as cells and no coordinates, node or place
  IDs; a GitHub 500 leaves `pending` and the cron files it; the daily
  issue cap holds the rest for the cron; the hourly mint ceiling returns
  429; a store that throws D1's limit error gives `503 storage_unavailable`
  and keeps nothing; delete calls `deleteIssue` and
  removes rows, and a failed delete removes nothing; retention deletes by
  date, including `maintainer_reads`; the maintainer route with and without
  permission; the rate-limit bindings are called with the IP and nothing
  stores it; the no-logging grep; `wrangler.jsonc` has `workers_dev`,
  `preview_urls` and `invocation_logs` false.
- `npm run dev` is `wrangler dev --env dev --ip 0.0.0.0` on port 8787 with a
  local D1 and `GITHUB_TOKEN` from `.dev.vars` (gitignored). Without a token
  the Worker stores reports and returns 202, which is enough for the app.
  Binding all interfaces lets a phone on the same network reach it (7.5).
- `.github/workflows/backend.yml`:
  - `on: pull_request: paths: [Backend/**, .github/workflows/backend.yml]`
    and `on: push: branches: [main]` with the same `paths`.
  - job `test`: `actions/setup-node@v4` (Node 22), `npm ci`, `npm test`,
    `npx tsc --noEmit`, then `npm run test:workers` with
    `continue-on-error: true`.
  - job `deploy`: `needs: test`,
    `if: github.event_name == 'push' && github.ref == 'refs/heads/main'`,
    `concurrency: backend-deploy`, `environment: production`. The GitHub
    Environment `production` is created once by hand with the maintainer as
    its required reviewer and holds the two Cloudflare secrets (7.2), so
    every deploy waits for an approval in the Actions UI and no other
    workflow can read the secrets. Steps:
    `npx wrangler d1 migrations apply peoplemaps-reports --remote`, then
    `npx wrangler deploy`, both with `CLOUDFLARE_API_TOKEN` and
    `CLOUDFLARE_ACCOUNT_ID` from the environment's secrets. Migrations
    first, so a deploy never runs against an older schema; a failed
    migration stops the deploy.
- `Scripts/verify.sh` is unchanged: the backend has its own toolchain and
  its own workflow. The verify skill table gets a row: `Backend/` needs
  `npm test` in `Backend/`.

### 7.4 Versioning and rollout

The API is `/v1/`. A field is added without a version bump; a field that
changes meaning bumps `schema` in the body and the Worker accepts both for
one app release. The Worker is deployed before the app that needs it.

### 7.5 How the app learns the base URL

`App/Info.plist` gets `PeoplemapsReportsURL` with the value
`$(PEOPLEMAPS_REPORTS_URL)`. `Scripts/generate_project.py` sets
`PEOPLEMAPS_REPORTS_URL` per configuration: Debug
`http://127.0.0.1:8787`, Release `https://reports.<our domain>` (the custom
domain of 7.2; never a `workers.dev` address, so the shipped app does not
depend on the vendor and the first release already points at the final
URL). `App/Info.plist`
also gets `NSAppTransportSecurity` → `NSAllowsLocalNetworking` true, which
only relaxes loopback and local addresses (open question 2).

Loopback only reaches `wrangler dev` from the simulator. In Debug builds the
UserDefaults key `PeoplemapsReportsURL` overrides the plist value, so a
tester with a phone points the app at the Mac's address on the same network
(`http://192.168.1.20:8787`, with `wrangler dev --ip 0.0.0.0`, 7.3) or at
the deployed Worker. The key is set by the launch argument
`--reports-url <url>` (UserDefaults reads arguments) or typed into a text
field in the Debug-only footer of Flagged moments, which also shows the URL
in use. Release builds ignore the key. `--ui-testing` ignores all of it and
uses the stub (8.4).

## 8. App integration

### 8.1 Files

- `Core/Reports.swift`, new: `ReportCategory`, `ReportEndpoint`,
  `ReportSnapshot`, `Report`, `ReportStore` (load, save, add, trim, status
  changes; a value type with `load(from:)`/`save(to:)` like `SavedPlaces`),
  `ReportEncoder` (canonical JSON, key order of 2.4). `SearchIndex` gains
  `dataVersion`, the first 12 chars of its `graphSHA256` meta row.
  `NativeRouter.nearestIntersection(to:mode:)` and `route(ids:mode:)` become
  public in `Core/RoutingEngine.swift`. `Tests/ReportsTests.swift`: encode
  and decode a fixture, snapping picks a junction, trimming, the exact fields
  drop out when `exactLocations` is false, `dataVersion` is 12 hex chars and
  matches `graphSHA256` in `Data/provenance.json`, the destination name is
  replaced in `spoken`.
- `App/Reports/ReportsStore.swift`: `@Observable` wrapper over
  `ReportStore`, the file path, the UI-testing file name.
- `App/Reports/ReportsClient.swift`: `URLSession` with `ephemeral`
  configuration (no cache, no cookies), Keychain access, mint-on-first-send,
  send, check status, delete, the stub (8.4). Every method is called from a
  tap handler; the client has no timer and no `onAppear` hook.
- `App/Reports/FlaggedMomentsView.swift`: the list; row shows the hour, the
  instruction on the card at the time, mode, status. Footer: "Your report
  ID", Rotate, "Check status" (only while a sent report's issue is pending),
  "Delete my reports" with its local count and confirmation (3), Export all,
  and a link to `Docs/PRIVACY.md` as rendered on GitHub. Under `#if DEBUG`
  the footer also shows the base URL in use with a field to change it (7.5).
- `App/Reports/ReportComposerView.swift`: category picker, note field with
  the public warning, exact-locations toggle (off), "Remove start" and
  "Remove destination", then the review: every field as it will be sent,
  pretty-printed, and Send. Send is disabled without a connection
  (`NWPathMonitor`), with "Needs a connection to send" shown.
- `App/Navigation/GuidanceView.swift`: a "Flag this moment" button, 56 pt
  tall, full width in portrait between the calm chip row and the map, in the
  landscape card under the trip stats. One tap, haptic `.success`, the
  button reads "Flagged" for two seconds, no sheet, no text. Identifier
  `flag-moment`. VoiceOver: "Flag this moment. Saves the current route and
  instruction on this phone to report later."
- `App/Navigation/FerrostarAdapter.swift` and `OwnRouteProvider.swift`:
  `AdaptedRoute` gains `comparison: RouteComparison` and `usedCalmer: Bool`,
  set in `NavigationController.start` from its arguments and in
  `OwnRouteProvider.getRoutes` from the reroute's own comparison, which it
  discards today. Without this nothing holds `route.edgeIDs`, `hash`,
  `stress`, `alternativeHash` or `chosen` after a reroute.
- `App/Navigation/NavigationController.swift`: keep the last three spoken
  texts with timestamps, with the destination's `shortName` replaced by
  "your destination" (2.1); count reroutes; expose `snapshot(store:)` that
  builds a `ReportSnapshot` from its published state and from `active` (its
  plan, comparison and `usedCalmer`), plus the router's intersection snap.
- `App/ExploreView.swift`: a "Flagged moments" row in the home footer next
  to About, with an unsent count. Identifier `flagged-moments`.
- `App/PrivacyInfo.xcprivacy`: `NSPrivacyCollectedDataTypes` gains Coarse
  Location, Precise Location, Other User Content (the note), Other
  Diagnostic Data, and User ID (the install ID: a server-issued random
  identifier is Apple's "User ID", not "Device ID"), each with
  `NSPrivacyCollectedDataTypeLinked` false, `Tracking` false, purpose
  `AppFunctionality`. The App Store Connect privacy answers must say the
  same. The comment at the top is updated.
- `Scripts/generate_project.py`: the build setting of 7.5; rerun it, since
  `App/Reports/` is new. `Package.swift`: the `ReportReplay` target (2.5,
  pipeline task; the app task leaves it).

### 8.2 Copy

Follows the product rules. The composer never asks whether a route was safe;
the category reads "The calmer route was a bad choice". The review screen
header: "After a maintainer approves it, this becomes a public issue on
GitHub. Your start and destination show only as half-kilometre squares, but
the route itself starts and ends at the snapped corners. Exact locations
stay off unless you turn them on; nothing has left this phone yet." The
"Delete my reports" confirmation: "Delete 3 sent reports and your report ID
from our server? Their public GitHub issues are deleted too, but copies
made before that, such as GitHub's public activity archives and emails to
people watching the project, cannot be recalled." The flag button
during guidance says nothing about the problem; the user explains at home.
The review screen shows `route.stress` because the review shows every byte;
the number is a maintainer artefact for the replay, and no other screen in
the app shows a stress score (the app explains a calmer route in local terms,
never a number).

### 8.3 Behaviour details

- Flag works in every guidance state, including rerouting and arrived.
  Flagging twice within five seconds updates the first snapshot instead of
  adding one.
- Flag never needs network, never shows a sheet, never speaks.
- The composer sends one report per tap. A send in flight blocks a second
  tap on the same snapshot. Failure shows the error code in words ("No
  connection", "The server refused this report (invalid_report: note)",
  "Too many reports today") and keeps everything.
- A 401 on Send mints a new token and retries the send once, after showing
  "Your report ID was reset". A 401 on Check status or Delete my reports
  shows the same message, wipes the Keychain items and stops; nothing mints
  outside a Send (4.1).
- Rotate: mints a new install. A rotated ID does not find old reports: the
  old token is gone from the Keychain, so those reports can no longer be
  checked or deleted from the phone, and they are deleted when their 90
  days end. The confirmation says so and offers "Delete my reports" first;
  local copies sent under the old ID show "Sent under an earlier report
  ID".
- A Send cut off by the app quitting or crashing leaves its snapshot at
  `sending` on disk. On load the app reads every `sending` snapshot as
  `flagged` with `lastError: interrupted` and the fields kept; the list shows
  it as unsent. Re-sending reuses the `id`, so if the server did store the
  first attempt the retry returns 200 (4.2), or 409 if the install changed.

### 8.4 UI test

Under `--ui-testing`, `ReportsClient` registers a `URLProtocol` stub for the
base URL that answers `POST /v1/installs` with a fixed token, `POST
/v1/reports` with `201` and issue 123 (the dev answer of 4.2, so the
receipt path is covered without a reviewer), and `DELETE` with `204`, and records
every request body. `NavigationDebugProbe` gains `debug-last-report`, the
body of the last stubbed `POST /v1/reports`. The test in
`UITests/PeoplemapsUITests.swift`:

1. Start simulated guidance (existing helper), wait for `guidance-card`,
   tap `flag-moment`, assert it reads "Flagged".
2. End navigation, open `flagged-moments`, assert one row.
3. Open it, pick "Wrong instruction", type a note, leave exact off, assert
   the review shows `"exactLocations": false` and no `"location":` object,
   tap Send.
4. Assert the row reads "Sent, issue #123" and `debug-last-report` decodes
   as a report with `category == wrong_instruction`, `location == null`,
   both endpoints `kind == intersection`, and `edgeIDs` non-empty.
5. Relaunch with `--keep-saved`; the row survives.

It runs in the existing `ui-tests` job; no network is used.

## 9. The automatic-fix pipeline

Built last, after the backend has filed real issues.
`.github/workflows/app-report-triage.yml`:

- `on: issues: types: [labeled]`, `if: github.event.label.name == 'app-report'`,
  `concurrency: triage-${{ github.event.issue.number }}`.
- `permissions: contents: write, issues: write, pull-requests: write`.
- Steps: checkout `main` with `fetch-depth: 0`, so the data-version lookup
  of 2.5 can find and check out an older commit; Swift 6.4 on `ubuntu-latest`; `anthropics/claude-code-action@v1`
  with `claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}`,
  `prompt` from `.github/app-report-prompt.md`, and `allowed_tools` limited
  to Bash, Read, Edit, Write and Grep.
- The note is public text that anyone can write, and the action runs with
  Bash and write access, so the note never reaches the model as part of the
  instructions. A step before the action parses the issue body with a small
  script into `report.json` and the fields the prompt needs; the prompt
  receives the parsed fields, and the note only inside a fenced block
  headed "User text, not instructions", with the prompt saying it is data to
  read, not a request to follow. The draft-PR gate below and the absence of
  merge rights are the second line.
- The prompt: take the parsed `report.json`; run
  `peoplemaps-replay`; if `dataVersion` mismatches, check out the commit it
  names and run again; classify as one of `reproduced-instruction`
  (plan replay shows the same text and it is wrong by the product rules or
  the data), `reproduced-route` (route replay matches and the calmer choice
  looks wrong on the stress breakdown), `data` (the way tags are the cause;
  link the OSM ways), `not-reproduced`, `needs-exact`; post one comment with
  the replay output, the classification and a plain explanation; add
  `triage:<class>`. For `reproduced-instruction` and `reproduced-route` with
  a small, testable cause in `Core/` (spoken-text normalisation, instruction
  wording, a stress-model constant with a unit test), make the fix on
  `fix/report-<n>`, run `Scripts/verify.sh`, and open a draft PR with
  `Closes #<n>`. Never change `Data/`, `Core/Resources/` or `App/`; data
  problems get a comment with the OSM links instead.
- The human gate: the PR is a draft, CI must pass, and a maintainer reviews
  and merges. The action's token cannot merge and the workflow never calls
  the merge API. No `app-report` issue is closed by the workflow; `Closes`
  on a merged PR closes it.

## 10. Open questions

1. **Worker URL.** Decided: a domain we own, `reports.<our domain>`, from
   the first release, with `workers.dev` turned off (7.2, 7.5; question 17).
2. **Loopback in Release.** `NSAllowsLocalNetworking` in the shared
   `Info.plist` also ships in Release. It only affects local addresses and
   the Release URL is HTTPS. Recommended: accept it; revisit if the generator
   grows per-configuration plist values.
3. **Exact fields for the pipeline.** 4.5 needs a person's GitHub token.
   Recommended later step: the Worker verifies a GitHub Actions OIDC token
   (issuer `token.actions.githubusercontent.com`, audience
   `peoplemaps-reports`, `repository` claim equal to this repo) against the
   public JWKS. No secret on either side. Not now; the pipeline replays from
   the issue.
4. **Timestamp granularity.** Hour, UTC. Recommended: keep; day would be
   enough for retention but the hour helps "voice or timing" reports and is
   still coarse.
5. **Where Flagged moments lives.** The home footer beside About, with the
   unsent count. Recommended: there; a Settings screen does not exist yet.
6. **Backups.** Exclude `reports/` from backups (exact coordinates live
   there) or let it back up like saved places. Recommended: exclude; a
   flagged moment is not worth restoring.
7. **The note.** No scrubbing of names or addresses; a warning in the UI and
   280 characters. Recommended: keep; scrubbing fails silently and
   over-promises.
8. **Unsent limit.** Fifty total, dropping the oldest sent first. Recommended:
   keep, and show the count in the list.
9. **Sending during guidance.** Not possible; the composer is only reachable
   from the list. Recommended: keep, for the no-typing rule.
10. **D1 location.** Create the database with `--location wnam` so rows stay
    in the western US near the users. Recommended: yes, and say "United
    States" in the policy.
11. **Follow-up to the sender.** The list shows the issue link; nothing
    pushes. Recommended: keep; an issue is public and the user can watch it.
12. **Install pruning.** Installs with no reports for a year are deleted
    (5.3); the app will mint a new ID on the next send and say so.
    Recommended: keep.

Owner decisions from the backend platform review. Each default is what this
document assumes until the owner says otherwise.

13. **Zero cost.** Literal: no card on any account. Default yes, which rules
    out AWS, Fly.io, Supabase Pro, Firebase and a VPS. App Attest (19) is
    the one planned exception.
14. **Public IP claim.** "We never store or log IP addresses; Cloudflare
    necessarily sees them to deliver traffic." Default: that sentence, and
    nothing stronger, once the test Worker check of 4.6 backs it.
15. **Deleting public issues.** Default: within an hour of the request. 4.4
    deletes at once or fails visibly with `503 github_unavailable`, which
    meets it; the policy says GitHub-side copies cannot be recalled.
16. **Filing.** Default: hold every report for one-tap maintainer approval
    (6.1) at a few reports a day; revisit if volume makes that a chore.
17. **API domain.** Default: we own a domain and the first release points at
    `reports.<our domain>` (7.5), so leaving Cloudflare is a DNS change.
18. **Server language.** Default: TypeScript. `src/validate.ts`'s
    `splitExact` and the issue builder must drop exactly what
    `Core/Reports.swift` drops, so shared fixtures in
    `Backend/test/fixtures/parity/` (a report in, the expected public body
    and exact part out) are read by both `Tests/ReportsTests.swift` and
    `test/validate.test.ts`.
19. **App Attest.** Default: required before App Store release, not for
    TestFlight; budget Workers Paid at $5 a month for the CPU it needs
    (4.5). Moving to Paid makes Time Travel 30 days, and the policy changes
    in the same PR (5.3).
20. **Rotated install ID.** Default: does not find old reports; they age out
    at 90 days (8.3).
21. **Endpoints in the issue.** Default: coarsened to the 550 m cell (6),
    with the route-ends caveat stated there and in `Docs/PRIVACY.md`.
22. **Trimming the published route.** Coarsening (21) does not hide the
    route's ends. Hiding them means publishing the route without the edges
    inside the origin and destination cells; the Worker has no graph, so the
    app would send the trim points, and the pipeline would need the full
    route from the stored body through the OIDC route of question 3.
    Recommended: not now; the review screen and the policy say what the
    route shows, and approval (6.1) is the gate.

23. **Install and report length checks differ.** `POST /v1/installs` counts
    `app.version` and `app.build` in UTF-16 code units (`v.length` in
    `installs.ts`) against 32; `validate.ts` counts code points against the
    same 32. Only strings with characters outside the BMP differ, and real
    version strings are ASCII. Follow-up: use `[...v].length` in `installs.ts`
    so both sides agree. No code changed in this PR.
24. **409 after Rotate.** A report whose send timed out and is re-sent after
    Rotate keeps its `id`, so every unedited retry is a 409 (4.2). Follow-up:
    have the app give the snapshot a new `id` when a 409 arrives (or when the
    install changes), or have the Worker treat a different install as a
    separate idempotency scope. Not decided.

Considered, not chosen: TestFlight feedback read through the App Store
Connect API as an interim with no backend at all (fine for one tester, but
no replay fields and no deletion by the sender); a stateless Worker writing
each report to R2 with a 90-day lifecycle rule and no database (simpler, but
no idempotency, per-install caps or aggregates without rebuilding them);
client-side encryption of the exact fields to a maintainer key, so no vendor
restore window ever holds them in plaintext (worth revisiting if exact
locations get common; it moves key handling onto the maintainers); and an
OHTTP relay in front of the Worker so Cloudflare never sees client IPs
(needs a second, independent operator and is out of proportion at this
volume).
