# Problem reports

Drafted 31 October 2026. Design only; nothing in `App/`, `Core/` or `.github/`
changes with this document. Three tasks build from it in parallel: the backend
(section 5 to 7), the app client (section 2, 3 and 8), and the issue pipeline
(section 6, 9 and the replay tool in section 2.5). Each section names its
interfaces so the tasks can be built and tested apart. The user-facing version
of the data rules is `Docs/PRIVACY.md`; keep the two in step.

Read with `.claude/skills/product-rules/SKILL.md` (no "safe", times are
estimates, unknown is said to be unknown), `Docs/NAVIGATION.md` and
`Docs/ARCHITECTURE.md`.

Decided, not open: Cloudflare Workers and D1 in `Backend/`; one GitHub issue
per sent report, filed by the Worker, labelled `app-report`; a silent
"Flag this moment" button during guidance and a "Flagged moments" list at home;
no accounts, a random per-install ID; endpoints snapped to the nearest street
intersection unless the user turns on exact locations for that report; raw
reports kept 90 days, aggregates after; no IP addresses stored; replay in
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
- App Attest or any device attestation. Noted as later hardening in 4.5.
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
| `route.dataVersion` | 12 hex chars | SHA-256 prefix of the bundled `seattle-graph.bin`, so the replay checks out the same data | no | yes |
| `route.edgeIDs` | [Int] | The directed edges travelled, `Route.edgeIDs`. Exact for this data version; the plan replays from these alone | low (a public route) | yes |
| `route.wayIDs` | [Int64] | OSM way IDs along the route, consecutive duplicates collapsed, so the route reads on any data version and in the issue | low | yes |
| `route.hash` | 64 hex chars | SHA-256 of `Route.id` (edge IDs joined by `-`); a replay compares hashes first | no | yes |
| `route.meters`, `route.seconds`, `route.stress` | Double | The metrics the user saw; a replay must reproduce them | no | yes |
| `route.alternativeHash` | string or null | Hash of the route not chosen (calmer when fastest was chosen and vice versa), null when no calmer route existed | no | yes |
| `position.stepIndex` | Int | The engine's step (`NavigationController.stepIndex`) | low | yes |
| `position.shownStepIndex` | Int | The step on the card; differs from `stepIndex` while the card still says "Head north on…" | low | yes |
| `position.distanceToManeuver` | metres | Where along the step the user was; the route point is derived from this and the plan, so no coordinate is needed | low | yes |
| `position.remainingMeters`, `position.remainingSeconds` | Double | What the trip bar showed | no | yes |
| `position.cell` | `r<row>c<col>` | The 550 m grid square of the route point at flag time, for the aggregate counts (5.2) | low | yes |
| `location` | exact position (2.2) or null | GPS fix at flag time: lat, lon, horizontal accuracy, course. Null unless exact locations are on for this report | **yes** | no |
| `spoken` | up to 3 of `{text, secondsBefore}` | The last instructions the voice said (after `SpokenText.normalize`), newest last, and how many seconds before the flag each was spoken | no | yes |
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

1. **Data version.** Compare `route.dataVersion` with the SHA-256 of
   `Core/Resources/seattle-graph.bin` in the checkout. If it differs, print
   `dataVersion: mismatch` and the commit that has it:
   `git log --format=%H -- Core/Resources/seattle-graph.bin`, hashing the file
   at each commit (`git show <commit>:Core/Resources/seattle-graph.bin | sha256sum`).
   The pipeline checks that commit out and runs again.
2. **Plan replay**, always possible. Build the `Route` from `route.edgeIDs`
   with `NativeRouter.route(ids:mode:)` (made public), then
   `navigationPlan(mode:)`. Print the step at `position.shownStepIndex`, its
   instruction, calm note and distance, the point `distanceToManeuver` metres
   before the step's end, and the spoken texts the plan would produce for the
   last two steps next to `spoken`. Check that `route.hash`, `meters`,
   `seconds` and `stress` reproduce. Any mismatch here means the data version
   or the router changed and is reported as such.
3. **Route replay**, when both endpoints are present. Build
   `RouteRequest(origin:destination:mode:extraMinutes:)` with
   `Place(id: placeID ?? "report/origin", name: "", lat:, lon:, category: placeID == nil ? "report" : "place")`
   (the category is only used for IDs and labels; `Place.snap` is empty, so
   the router snaps by coordinate, which for an intersection endpoint is the
   node itself at 0 m). Run `compute`, pick `chosen`, compare hashes. Print
   `match`, or `differs` with the way-ID sequences side by side and both
   routes' metrics.

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
  calls the server first and then marks local copies `withdrawn`.
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
  The Worker stores SHA-256 of the token and never the token.
- The app calls this once, on the first Send, not at launch, so an install
  that never sends anything never contacts the server. Rotate (4.4) calls it
  again and replaces both Keychain items.
- Rate limit: 2 per minute per client, keyed as in 4.6.

Every other endpoint needs `Authorization: Bearer pm_…`. A token that does
not match an install is `401 unauthorized`; the app then mints a new one and
tells the user "Your report ID was reset", since the old one was deleted
server-side (4.4) or never existed.

### 4.2 Send a report

```
POST /v1/reports
Idempotency-Key: <report id>
Body: the report (2.4)
201 { "id": "6F1D…", "receivedAt": "2026-10-31T21:00:00Z", "issue": { "number": 123, "url": "https://github.com/electropicks/peoplemaps/issues/123" } }
202 { "id": "6F1D…", "receivedAt": "…", "issue": null }     // stored; issue to be filed by the retry cron (5.3)
200 same body as before                                        // a retry with the same id and body
409 { "error": "conflict", "message": "Report 6F1D… was already sent with different content." }
```

- The Worker validates the shape (`Backend/src/validate.ts` mirrors 2.4:
  types, enum values, `note` length, `edgeIDs` and `wayIDs` non-empty and at
  most 2,000 entries, coordinates inside the coverage bounds plus 1 km, a
  `location` and exact endpoints only when `exactLocations` is true). Failure
  is `400 invalid_report` with `field`.
- Stores the row (5.1), bumps the aggregate (5.2), then files the issue (6).
  If GitHub fails, the row stays `issue_state = pending` and the response is
  202; the app shows "Sent, issue pending" and refreshes it from
  `GET /v1/reports/{id}` next time the list opens.
- Idempotent on `id`: the same body (canonical hash) returns the stored
  result; a different body is a 409 and the app regenerates the report with a
  new `id` only if the user edits and sends again.
- Rate limit: 20 per day per install, counted from the install's own rows
  in `reports` (`received_at` in the last 24 hours), plus the per-minute
  ceiling of 4.6.

### 4.3 Read own reports

```
GET /v1/reports            200 { "reports": [ { "id", "receivedAt", "category", "issue": {…} | null, "expiresAt" } ] }
GET /v1/reports/{id}       200 { same element } | 404 not_found
```

Only the sender's install. Used to refresh pending issues and to show the
count before "Delete my reports". Never returns the body; the phone has it.

### 4.4 Delete

```
DELETE /v1/reports/{id}    204 | 404
DELETE /v1/installs/me     204
```

`DELETE /v1/installs/me` deletes every report of the install and the install
row itself, in one D1 batch. For each report with an issue, the Worker edits
the issue: the body becomes "Report withdrawn by its sender. Category:
<category>. Data version: <dataVersion>.", the labels `app-report` and
`report:*` are removed, `withdrawn` is added and the issue is closed as
`not_planned`. Comments by maintainers stay;
copies people already made cannot be recalled, and `Docs/PRIVACY.md` says so.
The app then wipes its Keychain items ("Delete my reports" is also "start
over"). Rate limit: the per-minute ceiling of 4.6.

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
- **Later hardening, not now:** App Attest on `POST /v1/installs`, so a
  token can only be minted by a genuine copy of the app. The install flow
  already has the one round trip it would need.

### 4.6 Rate limits, errors, what is not kept

- Limits use the Workers rate-limiting binding, which counts in memory at
  the edge over a 60-second window and persists nothing. Two bindings in
  `wrangler.jsonc`: `RL_AUTH`, 10 per minute, keyed on the token hash, for
  every authenticated route; `RL_INSTALLS`, 2 per minute, keyed on
  `SHA-256(cf-connecting-ip + today's date)`, for `POST /v1/installs`. The IP
  is read for that hash only, inside the handler, and goes nowhere else. The
  daily report cap (4.2) comes from the install's own rows. Exceeding a limit
  is `429 rate_limited` with `Retry-After`.
- Errors are `{ "error": code, "message": text, "field"?: path }`. Codes:
  `unauthorized` 401, `forbidden` 403, `not_found` 404, `invalid_report` 400,
  `too_large` 413, `conflict` 409, `rate_limited` 429, `github_unavailable`
  503 (only on 4.5; sends get a 202 instead), `internal` 500.
- The Worker never logs a request object, a header, an IP, a user agent or a
  body. `observability.enabled` is false in `wrangler.jsonc`, and `console.*`
  is allowed only with a constant string plus a count or a status code. A
  test greps `src/` for `console.` and fails on anything else. Cloudflare as
  the host still sees connection details to serve the request; that is said
  in `Docs/PRIVACY.md`.
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
  created_at    TEXT NOT NULL,                    -- ISO 8601, hour precision
  last_seen_at  TEXT NOT NULL                     -- hour precision; for pruning idle installs
);

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
  public_json    TEXT NOT NULL,                   -- the body with exact fields removed; what the issue shows
  exact_json     TEXT,                            -- {origin, destination, location} when exactLocations; else NULL
  issue_number   INTEGER,
  issue_url      TEXT,
  issue_state    TEXT NOT NULL DEFAULT 'pending', -- pending | opened | failed | withdrawn
  issue_attempts INTEGER NOT NULL DEFAULT 0,
  issue_error    TEXT                             -- last GitHub status code and message, no request data
);
CREATE INDEX reports_install ON reports(install_id);
CREATE INDEX reports_expires ON reports(expires_at);
CREATE INDEX reports_pending ON reports(issue_state) WHERE issue_state = 'pending';
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
  read_at      TEXT NOT NULL                      -- hour precision
);
```

`PRAGMA foreign_keys` is on in D1, so deleting an install deletes its
reports. Migrations are numbered `000N_name.sql` and never edited after they
ship; a change is a new file.

### 5.2 Aggregates

`cell` is a grid square about 550 m on a side over the coverage bounds:
`r<row>c<col>` with row `floor((lat - 47.615) / 0.005)` and col
`floor((lon + 122.390) / 0.0075)` of the flag point, the route point
`distanceToManeuver` metres before the end of the shown step. The Worker has
no graph, so the app computes the cell and sends it as `position.cell`; the
Worker checks it is a cell of the grid (rows 0 to 12, columns 0 to 11) and
stores it unchanged.

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
  `DELETE FROM installs WHERE last_seen_at < now() - 365 days AND NOT EXISTS (reports)`.
  The deleted rows' issues stay on GitHub as they are: they are already
  public and hold no exact fields. Logs one line: counts.
- `7 * * * *` **issue retry.** For up to 20 rows with `issue_state = pending`
  and `issue_attempts < 10`, try to file the issue (6). After 10 failures the
  row goes `failed` and a maintainer sees it in `wrangler d1 execute`; the
  app shows "Sent, issue pending" until then.

## 6. The GitHub issue

The Worker files one issue per accepted report with its `GITHUB_TOKEN`
(a fine-grained token: this repository only, Issues read and write, nothing
else). The app never holds a GitHub token.

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
last `spoken` text or, when none, "step <shownStepIndex>". For
`calmer_bad_choice`: `[app-report] Calmer route questioned: <first way ID> → <last way ID> (<mode>, <dataVersion>)`.
For `map_data` and `other` the same with "Map data" or "Other". Category
words: Wrong instruction, Calmer route questioned, Map data, Voice or timing,
Other.

**Body.** Category; What happened (the note, or "No note"); Data version;
App version; Route request (mode, extra minutes, preferences, the snapped
endpoints as sent, `rerouted`); Route (`dataVersion`, `hash`,
`alternativeHash`, `meters`, `seconds`, `stress`, `wayIDs`, `edgeIDs`);
Position; Spoken instructions; Navigation state; Device. A trailing HTML
comment `<!-- report:<id> -->` carries the report ID so 4.5 can find the row
by issue number even if the DB index is lost; the ID is random and says
nothing about the sender. A line at the end: "Filed by the PeopleMaps
reports backend from a report the sender reviewed and sent. Times in the app
are estimates; a calmer route is a preference, not a rating."

**Omitted from the issue, even when stored:** exact endpoints, exact
`location`, the install ID, the receipt time beyond the hour. If the user
turned exact locations on, the issue says "Exact locations: available to
maintainers (section 4.5)" under Route request, and the endpoints shown are
the `snapped` forms the app sends inside each exact endpoint (2.2), so
`public_json` always has intersection endpoints and `exact_json` has the
rest.

**Labels.** `app-report`, `report:<category>`, `mode:<mode>`. The pipeline
adds `triage:*` (9). `withdrawn` replaces `app-report` on delete (4.4).
The five `report:*`, three `mode:*`, `withdrawn` and `triage:*` labels are
created once by the pipeline task.

## 7. Backend layout

### 7.1 Tree

```
Backend/
  README.md               run, test, deploy, secrets (points here)
  package.json            wrangler, typescript, vitest, @cloudflare/vitest-pool-workers, @cloudflare/workers-types
  wrangler.jsonc          see 7.2
  tsconfig.json
  vitest.config.ts        defineWorkersConfig, miniflare with the D1 binding and migrations applied
  migrations/0001_init.sql
  src/index.ts            fetch router and scheduled handler
  src/installs.ts         POST /v1/installs, DELETE /v1/installs/me, token hashing
  src/reports.ts          POST, GET, DELETE /v1/reports
  src/maintainer.ts       GET /v1/maintainer/issues/{n}/report
  src/validate.ts         schema check of 2.4; also `canonical(body)` and `splitExact(body)`
  src/issue.ts            title and body builders (6), pure functions
  src/github.ts           create, edit and relabel issues; the only module that reads GITHUB_TOKEN
  src/cells.ts            cell validation (5.2)
  src/retention.ts        the two cron jobs
  src/errors.ts           the error envelope
  test/*.test.ts          one file per src module, plus test/fixtures/report.json (2.4)
```

### 7.2 `wrangler.jsonc`

```jsonc
{
  "name": "peoplemaps-reports",
  "main": "src/index.ts",
  "compatibility_date": "2026-10-01",
  "observability": { "enabled": false },
  "vars": { "GITHUB_REPO": "electropicks/peoplemaps", "RETENTION_DAYS": "90" },
  "d1_databases": [{ "binding": "DB", "database_name": "peoplemaps-reports", "database_id": "<filled in after wrangler d1 create>", "migrations_dir": "migrations" }],
  "unsafe": { "bindings": [
    { "name": "RL_AUTH", "type": "ratelimit", "namespace_id": "1001", "simple": { "limit": 10, "period": 60 } },
    { "name": "RL_INSTALLS", "type": "ratelimit", "namespace_id": "1002", "simple": { "limit": 2, "period": 60 } }
  ] },
  "triggers": { "crons": ["17 3 * * *", "7 * * * *"] }
}
```

The database ID is not a secret and is committed. The database is created
once by hand with `wrangler d1 create peoplemaps-reports --location wnam`
(open question 10).

**Secrets.** Repository secrets `CLOUDFLARE_API_TOKEN` (Workers Scripts:
Edit, D1: Edit, on this account) and `CLOUDFLARE_ACCOUNT_ID`. One Worker
secret, `GITHUB_TOKEN`, set with `wrangler secret put GITHUB_TOKEN` from the
maintainer's machine, never through Actions. Nothing else.

### 7.3 Tests, local run, CI, deploy

- `npm test` runs vitest in `@cloudflare/vitest-pool-workers`: a real
  Workers runtime with an in-memory D1 and the migrations applied, no
  account. GitHub is a `fetch` mock (`test/github.mock.ts`) asserting the
  exact request the Worker makes. Tests cover: mint and reuse a token;
  reject a bad token; send, retry with same body (200), retry with changed
  body (409); validation of each field; exact fields split out of
  `public_json`; issue title and body for each category; a GitHub 500 leaves
  `pending` and the cron files it; delete edits the issue and removes rows;
  retention deletes by date; the maintainer route with and without
  permission; the no-logging grep.
- `npm run dev` is `wrangler dev` on `http://127.0.0.1:8787` with a local D1
  and `GITHUB_TOKEN` from `.dev.vars` (gitignored). Without a token the
  Worker stores reports and returns 202, which is enough for the app.
- `.github/workflows/backend.yml`:
  - `on: pull_request: paths: [Backend/**, .github/workflows/backend.yml]`
    and `on: push: branches: [main]` with the same `paths`.
  - job `test`: `actions/setup-node@v4` (Node 22), `npm ci`, `npm test`,
    `npx tsc --noEmit`.
  - job `deploy`: `needs: test`,
    `if: github.event_name == 'push' && github.ref == 'refs/heads/main'`,
    `concurrency: backend-deploy`, environment `production`. Steps:
    `npx wrangler d1 migrations apply peoplemaps-reports --remote`, then
    `npx wrangler deploy`, both with `CLOUDFLARE_API_TOKEN` and
    `CLOUDFLARE_ACCOUNT_ID` from secrets. Migrations first, so a deploy never
    runs against an older schema; a failed migration stops the deploy.
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
`http://127.0.0.1:8787`, Release `https://peoplemaps-reports.<account>.workers.dev`
(the real subdomain goes in when the Worker first deploys). `App/Info.plist`
also gets `NSAppTransportSecurity` → `NSAllowsLocalNetworking` true, which
only relaxes loopback and local addresses (open question 2). The launch
argument `--reports-url <url>` overrides it in Debug builds, and
`--ui-testing` ignores both and uses the stub (8.4).

## 8. App integration

### 8.1 Files

- `Core/Reports.swift`, new: `ReportCategory`, `ReportEndpoint`,
  `ReportSnapshot`, `Report`, `ReportStore` (load, save, add, trim, status
  changes; a value type with `load(from:)`/`save(to:)` like `SavedPlaces`),
  `ReportEncoder` (canonical JSON, key order of 2.4), `dataVersion(of:)`.
  `NativeRouter.nearestIntersection(to:mode:)` and `route(ids:mode:)` become
  public in `Core/RoutingEngine.swift`. `Tests/ReportsTests.swift`: encode
  and decode a fixture, snapping picks a junction, trimming, the exact fields
  drop out when `exactLocations` is false, `dataVersion` is 12 hex chars.
- `App/Reports/ReportsStore.swift`: `@Observable` wrapper over
  `ReportStore`, the file path, the UI-testing file name.
- `App/Reports/ReportsClient.swift`: `URLSession` with `ephemeral`
  configuration (no cache, no cookies), Keychain access, mint-on-first-send,
  send with `Idempotency-Key`, delete, the stub (8.4).
- `App/Reports/FlaggedMomentsView.swift`: the list; row shows the hour, the
  instruction on the card at the time, mode, status. Footer: "Your report
  ID", Rotate, "Delete my reports", Export all, and a link to
  `Docs/PRIVACY.md` as rendered on GitHub.
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
- `App/Navigation/NavigationController.swift`: keep the last three spoken
  texts with timestamps, count reroutes, expose `snapshot(store:)` that
  builds a `ReportSnapshot` from its published state, the active plan, the
  comparison and the router's intersection snap.
- `App/ExploreView.swift`: a "Flagged moments" row in the home footer next
  to About, with an unsent count. Identifier `flagged-moments`.
- `App/PrivacyInfo.xcprivacy`: `NSPrivacyCollectedDataTypes` gains Coarse
  Location, Precise Location, Other User Content (the note), Other
  Diagnostic Data, and Device ID (the install ID), each with
  `NSPrivacyCollectedDataTypeLinked` false, `Tracking` false, purpose
  `AppFunctionality`. The App Store Connect privacy answers must say the
  same. The comment at the top is updated.
- `Scripts/generate_project.py`: the build setting of 7.5; rerun it, since
  `App/Reports/` is new. `Package.swift`: the `ReportReplay` target (2.5,
  pipeline task; the app task leaves it).

### 8.2 Copy

Follows the product rules. The composer never asks whether a route was safe;
the category reads "The calmer route was a bad choice". The review screen
header: "This becomes a public issue on GitHub. Exact locations stay off
unless you turn them on; nothing has left this phone yet." The flag button
during guidance says nothing about the problem; the user explains at home.

### 8.3 Behaviour details

- Flag works in every guidance state, including rerouting and arrived.
  Flagging twice within five seconds updates the first snapshot instead of
  adding one.
- Flag never needs network, never shows a sheet, never speaks.
- The composer sends one report per tap. A send in flight blocks a second
  tap on the same snapshot. Failure shows the error code in words ("No
  connection", "The server refused this report (invalid_report: note)",
  "Too many reports today") and keeps everything.
- After a 401 the client mints a new token and retries once.
- Rotate: mints a new install; old reports keep their old ID server-side
  until "Delete my reports" is used; the UI says so.

### 8.4 UI test

Under `--ui-testing`, `ReportsClient` registers a `URLProtocol` stub for the
base URL that answers `POST /v1/installs` with a fixed token, `POST
/v1/reports` with `201` and issue 123, and `DELETE` with `204`, and records
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
- Steps: checkout `main`; Swift 6.4 on `ubuntu-latest`; `anthropics/claude-code-action@v1`
  with `claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}`,
  `prompt` from `.github/app-report-prompt.md`, and `allowed_tools` limited
  to Bash, Read, Edit, Write and Grep.
- The prompt: parse the issue body (6); write it to `report.json`; run
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

1. **Worker URL.** `workers.dev` subdomain now; a custom domain only if the
   app gets a website. Recommended: `workers.dev`.
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
12. **Withdrawn issues.** Edit the body to a stub, relabel and close (4.4),
    or only close with a comment. Recommended: edit, relabel and close, so
    the public copy holds as little as possible.
13. **Install pruning.** Installs with no reports for a year are deleted
    (5.3); the app will mint a new ID on the next send and say so.
    Recommended: keep.
