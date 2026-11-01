# Problem reports

Design for in-app problem reports. `Backend/` and `Core/Reports*.swift` build from it; the app screens in section 8 are
not built yet. The user-facing version of the data rules is `Docs/PRIVACY.md`; keep the two in step. Read with
`.claude/skills/product-rules/SKILL.md`.

Decided, not open: a Cloudflare Worker and D1 database in `Backend/`, written so the handlers depend on neither (7.1),
served from the Worker's `workers.dev` address for now (7.5, question 1). Reports are stored in D1 only. Nothing is
filed on GitHub automatically; a maintainer reads reports with `wrangler d1 execute` and files a useful one by hand (6).
A silent "Flag this moment" button during guidance and a "Flagged moments" list at home. No accounts; a random
per-install ID. Endpoints snapped to the nearest street intersection unless the user turns on exact locations for that
report. Raw reports kept 90 days (plus Cloudflare's restore window, 5.3). No IP addresses stored or logged.

Deferred, because nothing needs them yet: automatic issue filing and approval, the triage pipeline (9), and aggregate
counts (5.2).

## 1. Goals and non-goals

Goals:

- A user who hears a wrong turn, gets a strange calmer route or sees bad map data can mark the moment with one tap and
  send it later, with nothing typed on the road.
- A sent report can be replayed on a Linux box on the same data version and land on the same step (2.5).
- Nothing leaves the phone without a tap. The user sees every field before sending and can delete what they sent.

Non-goals: crash reporting, analytics or usage metrics; accounts, sign-in, email or push; screenshots or audio; sending
while offline (flagging is offline; sending needs a connection and says so).

## 2. Data model

A **snapshot** is what the phone records when the user taps Flag. A **report** is a snapshot plus what the user adds at
home, and is what the app sends. Both are `Codable` in `Core/Reports.swift`.

### 2.1 Snapshot fields

| Field | Type | Purpose | Sent by default |
|---|---|---|---|
| `id` | UUID string | Identifies the report; the idempotency key for retries | yes |
| `flaggedAt` | ISO 8601 | Ordering on the phone; sent rounded down to the hour, UTC | hour only |
| `request.mode` | `walk`, `bike`, `drive` | Rebuild the `RouteRequest` | yes |
| `request.extraMinutes` | 0 to 20 | Rebuild the `RouteRequest` | yes |
| `request.preferences` | object or null | The "Calmer means" sheet (`Docs/DESIGN.md` 4.6); null until it lands | yes |
| `request.origin`, `request.destination` | endpoint (2.2) | Rebuild the `RouteRequest`. Exact on the phone | snapped |
| `request.rerouted` | bool | `origin` is where the engine rerouted, not where the trip began | yes |
| `chosen` | `calmer` or `fastest` | Which route to compare a replay against | yes |
| `route.dataVersion` | 12 hex chars | Prefix of the bundled graph's SHA-256, from the search index's `graphSHA256` meta row | yes |
| `route.edgeIDs` | [Int] | The directed edges travelled, `Route.edgeIDs` | yes |
| `route.wayIDs` | [Int64] | OSM way IDs along the route, consecutive duplicates collapsed | yes |
| `route.hash` | 64 hex chars | SHA-256 of `Route.id` | yes |
| `route.meters`, `route.seconds`, `route.stress` | Double | The metrics a replay must reproduce | yes |
| `route.alternativeHash` | string or null | Hash of the route not chosen; null when no calmer route existed | yes |
| `position.stepIndex` | Int | The engine's step (`NavigationController.stepIndex`) | yes |
| `position.shownStepIndex` | Int | The step on the card: `stepIndex + 1`, capped at the last step, except on the set-off card (0) | yes |
| `position.distanceToManeuver` | metres | Where along the step the user was; no coordinate is needed | yes |
| `position.remainingMeters`, `position.remainingSeconds` | Double | What the trip bar showed | yes |
| `position.cell` | `r<row>c<col>` | The 550 m grid square of the route point at flag time (5.2) | yes |
| `location` | exact position (2.2) or null | GPS fix at flag time. Null unless exact locations are on for this report | no |
| `spoken` | up to 3 of `{text, secondsBefore}` | The last instructions said, newest last. The destination's name becomes "your destination" in every text | yes |
| `nav.state` | `guiding`, `rerouting`, `paused`, `arrived` | What the engine was doing | yes |
| `nav.rerouteCount` | Int | Reroutes so far in this trip | yes |
| `nav.muted` | bool | Voice reports with the voice off read differently | yes |
| `nav.voiceQuality` | `default`, `enhanced`, `premium` | Which tier spoke, never the voice identifier | yes |
| `nav.units` | `mi` or `km` | What the banner and voice used | yes |
| `app.version`, `app.build` | strings | `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` | yes |
| `device.model`, `device.os` | strings | `iPhone16,2`, `iOS 27.1` | yes |

Not recorded, on purpose: the device name, locale, time zone, language, battery, carrier, other apps, screen size,
Contacts, Calendar or Photos, saved places, recents and favourites, and the trip's history before the flag.

### 2.2 Endpoints and positions

```jsonc
// endpoint, snapped (the default)
{ "kind": "intersection", "lat": 47.62980, "lon": -122.35931, "osmNode": 53070456, "placeID": "way/37056567" }
// endpoint, exact (only with the per-report toggle on); the snapped form rides along for public_json
{ "kind": "exact", "lat": 47.62950, "lon": -122.35990, "placeID": "way/37056567",
  "snapped": { "lat": 47.62980, "lon": -122.35931, "osmNode": 53070456 } }
// endpoint removed by the user in review; route replay is not possible, plan replay is
null
// exact position at flag time (only with the toggle on); otherwise the key is null
{ "lat": 47.63712, "lon": -122.35588, "accuracy": 8, "course": 71 }
```

- **Snapping.** `NativeRouter.nearestIntersection(to:mode:)`: the nearest graph node within 400 m that the mode can use,
  in its main connected component, with three or more road legs, or two if none has three. If none is within 400 m the
  endpoint becomes `null` and the review screen says "No intersection near the start; start removed". Coordinates are
  the node's, to five decimals.
- **`placeID`** is kept only for a public named place, and only when it matches `^(node|way|relation)/\d{1,19}$`.
  Addresses, pins and the user's position never carry an ID or a name. The key is omitted, not sent as `null`.
- **`location`**: `accuracy` is 0 to 10,000 m; `course` is -1 to 360, or `null` when the fix has no heading.
- Both forms are stored on the phone, so review can switch without recomputing. Only the chosen form is sent.

### 2.3 Report fields

The report is the snapshot plus `category` (`wrong_instruction`, `calmer_bad_choice`, `map_data`, `voice_timing`,
`other`), `note` (0 to 280 characters or null, in the user's words) and `exactLocations` (per report, default false).
`sentAt`, `serverID` and `expiresAt` stay on the phone as the receipt.

The install ID and token are not report fields. The ID travels in the bearer token, never in the body.

### 2.4 The JSON the app sends

`POST /v1/reports`, `application/json`, at most 64 KB. Keys in this order; the Worker canonicalises (sorted keys, no
whitespace) before hashing, so order does not matter for idempotency. Example values:

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

`schema` is bumped when a field changes meaning; the Worker rejects unknown schemas with `invalid_report`.

### 2.5 Replay

Not built yet. A small `peoplemaps-replay` target beside `RouteAudit` takes a report body (`public_json`, or the export):

1. **Data version.** Compare `route.dataVersion` with `graphSHA256` in `Data/provenance.json`; on a mismatch, name the
   commit that introduced it, from `git log -S`.
2. **Plan replay**, always possible. Build the `Route` from `route.edgeIDs`, then `navigationPlan(mode:)`. Print the step
   at `position.shownStepIndex` and the spoken texts it would produce next to `spoken`, and check that the hash and
   metrics reproduce.
3. **Route replay**, when both endpoints are present. Rebuild the `RouteRequest`, run `compute`, pick `chosen` and compare
   hashes.

**What snapping loses.** A snapped endpoint can move up to 400 m, so a replayed route can differ in its first and last
edges and the calmer-or-fastest decision can flip when the two were close. The plan replay is exact regardless, since
`edgeIDs` is the route itself; `calmer_bad_choice` is the category that needs route replay. Route replay of a rerouted
trip is best-effort.

## 3. On-device storage

- **Where.** `Application Support/reports/snapshots.json`, a `Codable` array written atomically after every change, like
  `App/SavedPlacesStore.swift`. Under `--ui-testing` the file is `snapshots-uitests.json`.
- **Lifecycle.** Flag writes `status: flagged`. Review and Send set `category`, `note`, `exactLocations` and
  `status: sending`; the receipt sets `status: sent` with `sentAt`, `serverID`, `expiresAt`. A failed send goes back to
  `flagged` with the fields kept and `lastError`. `status: withdrawn` after a server-side delete, until the user removes
  it locally. These four are the statuses the app needs; the server keeps none (4.3).
- **Limit.** The last 50. A flag that would make 51 drops the oldest `sent` or `withdrawn` snapshot, or else the oldest
  `flagged` one, and the list says "An older unsent moment was removed to make room".
- **Keychain.** Install ID and bearer token, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronised, so a
  restore onto another phone starts with no ID and no reports.
- **Export.** The JSON exactly as it would be sent, in the share sheet as `report-<id>.json`. The review screen shows the
  same bytes, pretty-printed.
- **Delete.** Swipe to delete one snapshot; "Delete all flagged moments" deletes the file. Neither contacts the server.
  "Delete my reports" (4.4) shows the count of local `sent` snapshots, calls `DELETE /v1/installs/me` on confirmation and
  marks local copies `withdrawn`.
- **Network.** No request is automatic: not when the list opens, not at launch, not on a timer. The client contacts the
  server only on Send, "Check status" (`GET /v1/reports`) and "Delete my reports". Each is one explicit tap.
- **Backups.** The `reports/` folder is marked `isExcludedFromBackup`, because it holds exact coordinates.

## 4. HTTP API

Base URL per build (7.5). JSON in and out. Every response carries `Cache-Control: no-store`. No cookies, no CORS. TLS
only; `http://` is only for `wrangler dev`.

### 4.1 Install token

```
POST /v1/installs
Body: { "schema": 1, "app": { "version": "0.1.0", "build": "1" } }
201 { "installID": "8C2F…", "token": "pm_…" }
```

No authentication. `installID` is a UUID v4 the app shows as "Your report ID". `token` is 32 random bytes, base64url,
prefixed `pm_`; the Worker stores only its SHA-256. `app` is stored as `installs.app_version` and updated from each
accepted report, so a maintainer can tell which builds still send (question 1). The app calls this once, on the first
Send.

Every other endpoint needs `Authorization: Bearer pm_…`. A token that matches no install is `401 unauthorized`: the
install was deleted or never existed. The app wipes its two Keychain items and shows "Your report ID was reset". It
mints a new token only inside a Send, then retries that send once; a 401 on "Check status" or "Delete my reports" ends
there. No request mints a token on its own.

### 4.2 Send a report

```
POST /v1/reports
Body: the report (2.4); its `id` is the idempotency key
201 { "id": "6F1D…", "receivedAt": "2026-10-31T21:00:00Z", "expiresAt": "2027-01-29T21:00:00Z" }   // stored
200 { same shape }                                                                                 // a retry with the same id and body
409 { "error": "conflict", "message": "Report 6F1D… was already sent with different content." }
503 { "error": "storage_unavailable", "message": "…" } + Retry-After                               // D1 refused the write (4.6); nothing kept
```

- The Worker validates the shape (`Backend/src/validate.ts`: types, enums, `edgeIDs` and `wayIDs` non-empty and at most
  2,000 entries, coordinates inside the coverage bounds plus 1 km, a `location` and exact endpoints only when
  `exactLocations` is true, unknown keys refused). Failure is `400 invalid_report` with `field`, a dotted path such as
  `spoken[1].text`.
- **Length caps**, in Unicode code points: `spoken[i].text` 1 to 500, `note` null or at most 280, `app.version` and
  `app.build` 1 to 32, `device.model` and `device.os` 1 to 64. `spoken` has at most 3 entries.
- **Idempotent** on the body's `id`, over the canonical hash, so key order and whitespace cannot cause a conflict. A
  different body under the same `id`, or the same `id` from another install, is a 409. The app keeps the snapshot
  `flagged` with `lastError: conflict`; editing the category, note or exact setting gives it a new `id` on the next Send.
  A 401 cannot lead here: the old install's rows went with it, so a re-send under a new token is simply new.
- A Send cut off by the app quitting reads as `flagged` with `lastError: interrupted` on load; re-sending reuses the
  `id`, so if the server stored the first attempt the retry gets 200.
- Rate limit: `REPORTS_PER_DAY` per install, counted from its own rows in the last 24 hours, plus the edge limits (4.6).

### 4.3 Read own reports

```
GET /v1/reports            200 { "reports": [ { "id", "receivedAt", "expiresAt", "category" } ] }
GET /v1/reports/{id}       200 { one element of the same shape } | 404 not_found
```

Only the sender's install, and never the body; the phone has it. A row means the server holds the report until
`expiresAt`; no row means it is gone. Nothing else is tracked per report, so there is no server status to keep in step.
Called only from "Check status" (question 27).

### 4.4 Delete

```
DELETE /v1/reports/{id}    204 | 404
DELETE /v1/installs/me     204
```

`DELETE /v1/installs/me` deletes every report of the install and the install row, in one D1 batch, and is the reset:
"Delete my reports" is also "start over". The app wipes its Keychain items only after a `204`, or on a 401. On any other
failure it keeps them, so the user can tap Delete again. A hand-filed issue (6) is not reached by these; see question 26.

### 4.5 Before App Store release

App Attest on `POST /v1/installs`, so a token can only be minted by a genuine copy of the app. It is not needed for
TestFlight, and it budgets Workers Paid at $5 a month for the CPU it needs (question 19).

### 4.6 Rate limits, errors, what is not kept

- Minting a token needs no identity, so every per-install cap can be reset by minting again. The limits that hold against
  that are keyed by client IP at Cloudflare's edge, where our code and database never store it. Three Workers rate
  limiting bindings in `wrangler.jsonc`, 60-second windows: `RL_AUTH`, 10 per minute keyed on the token hash, for every
  authenticated route; `RL_INSTALLS`, 2 per minute, and `RL_REPORTS`, 10 per minute, keyed on the bare `cf-connecting-ip`,
  read only in `src/ratelimit.ts`, passed straight to the binding and never stored. Over a limit is `429 rate_limited`
  with `Retry-After`.
- The bindings are approximate and count per Cloudflare location, so a flood spread across locations gets more. The
  strict backstop is `INSTALLS_PER_HOUR` (60), counted from `installs.created_at` in the current hour.
- **D1's Free daily limits** (5 million rows read, 100,000 rows written, enforced since 2026-09-01). Once spent, every
  query fails until 00:00 UTC with D1's documented "free tier daily row read limit" or "write limit" error. The Worker
  answers `503 storage_unavailable` with `Retry-After` set to 00:00 UTC, and the app keeps the report flagged with "The
  report server is full for today. Try again after <local time>." The report is not parked anywhere else, since a second
  store would need its own retention and its own line in the policy.
- Errors are `{ "error": code, "message": text, "field"?: path }`. Codes: `unauthorized` 401, `not_found` 404,
  `invalid_report` 400, `too_large` 413, `conflict` 409, `rate_limited` 429, `storage_unavailable` 503, `internal` 500.
- The Worker never logs a request object, a header, an IP, a user agent or a body. `observability.enabled` and
  `observability.logs.invocation_logs` are false in `wrangler.jsonc`, and `console.*` is allowed only with a constant
  string plus a count or status. A test checks both.
- **Before the policy is published**, send the deployed Worker some requests and read what Workers Logs and the
  dashboard's request views record. `Docs/PRIVACY.md` says only what that check showed. Recheck after Workers Logs pricing
  changes on 2026-12-01, since changed defaults can come with it.
- Bodies over 64 KB are refused before parsing (`content-length` first, then a streaming count).

## 5. D1 schema, retention

### 5.1 Tables

`Backend/migrations/0001_init.sql`, applied by `wrangler d1 migrations apply` in the deploy job (7.3) and by the tests.
Migrations are numbered and never edited once they have been applied to the deployed database; a change is a new file.

```sql
CREATE TABLE installs (
  id            TEXT PRIMARY KEY,                 -- UUID shown in the app
  token_hash    TEXT NOT NULL UNIQUE,             -- SHA-256 hex of the bearer token
  app_version   TEXT NOT NULL,                    -- "0.1.0 (1)", from the install call, then from each accepted report
  created_at    TEXT NOT NULL,                    -- hour precision
  last_seen_at  TEXT NOT NULL                     -- hour precision; for pruning idle installs
);
CREATE INDEX installs_created ON installs(created_at);  -- the hourly mint ceiling (4.6)

CREATE TABLE reports (
  id           TEXT PRIMARY KEY,                  -- report UUID from the app; the idempotency key
  install_id   TEXT NOT NULL REFERENCES installs(id) ON DELETE CASCADE,
  received_at  TEXT NOT NULL,                     -- hour precision
  expires_at   TEXT NOT NULL,                     -- received_at + 90 days
  body_hash    TEXT NOT NULL,                     -- SHA-256 of the canonical body, to spot a changed retry
  category     TEXT NOT NULL,
  public_json  TEXT NOT NULL,                     -- the body with exact fields removed
  exact_json   TEXT                               -- {origin, destination, location} when exactLocations; else NULL
);
CREATE INDEX reports_install ON reports(install_id);
CREATE INDEX reports_expires ON reports(expires_at);
```

Anything else a maintainer wants is in `public_json`: `json_extract(public_json, '$.request.mode')`.

### 5.2 The cell grid

`position.cell` is a grid square about 550 m on a side over the coverage bounds: row `floor((lat - 47.615) / 0.005)`,
col `floor((lon + 122.390) / 0.0075)` of the route point at flag time, clamped to rows 0 to 12 and columns 0 to 11. The
Worker has no graph, so the app computes it; the Worker checks it is a cell of the grid and stores it in `public_json`.

Aggregate counts over this grid are deferred, since nothing reads them. Keeping `position.cell` in the body lets them be
rebuilt from any rows still held; rows deleted before then are not counted.

### 5.3 Retention

One cron, `17 3 * * *`: `DELETE FROM reports WHERE expires_at < now()`, and delete installs not seen for 365 days that
have no reports. It logs one count.

**Time Travel.** D1 keeps a restorable copy of the database for 7 days on the Workers Free plan and 30 on Paid. It cannot
be shortened or turned off, and only the maintainers' Cloudflare account can restore from it. So a row deleted by the
user or by retention is fully gone 7 days after the delete on Free. `Docs/PRIVACY.md` gives the Free figure; moving to
Paid or to another host changes the policy in the same PR.

## 6. Filing an issue by hand

The Worker has no GitHub code and no GitHub token. A public issue cannot truly be erased (GH Archive and other mirrors
record it when it is opened, and GitHub emails it to watchers), so nothing reaches GitHub without a person reading it
first.

```sh
cd Backend
npx wrangler d1 execute peoplemaps-reports --remote --command "SELECT id, received_at, category, json_extract(public_json, '$.note') AS note FROM reports ORDER BY received_at DESC LIMIT 20"
npm run file-issue -- <report-id>            # prints the title, labels and body
npm run file-issue -- <report-id> --create   # files it with gh
```

`Backend/scripts/file-issue.ts` reads `public_json` with wrangler and builds the issue with `src/issue.ts`, pure functions
with tests. The maintainer reads it first and edits or drops the note if it has a name or address in it.

- **Title.** `[app-report] <Category words>: "<last spoken text>" (<mode>, <dataVersion>)` for instruction and voice
  categories, or `step <shownStepIndex>` when nothing was spoken or the trip had arrived. For the others,
  `<origin cell> → <destination cell>`, never a street name.
- **Body.** `### <Label>` sections: Category; What happened; Data version; App version; Flagged at; Route request; Route;
  Position; Spoken instructions; Navigation state; Device. Everything a replay needs is there.
- **Omitted:** exact endpoints, `location`, the `exactLocations` flag, the install ID and report ID, and the snapped
  endpoints' coordinates, `osmNode` and `placeID`: each endpoint shows as its cell.
- **What coarsening does not hide.** `edgeIDs` and `wayIDs` stay, because the plan replay needs the whole route, and a
  route starts and ends at its snapped intersections. Anyone with the map data can read those corners off the first and
  last edges. The maintainer can cut the route from a sensitive issue; `Docs/PRIVACY.md` says this.
- **Labels.** `app-report`, `report:<category>`, `mode:<mode>`, created once with `gh label create`.

## 7. Backend layout

### 7.1 Tree

```
Backend/
  README.md               run, test, deploy
  package.json            wrangler, typescript, vitest, @cloudflare/workers-types
  wrangler.jsonc          see 7.2
  migrations/0001_init.sql
  scripts/file-issue.ts   the hand-filing tool (6); never deployed
  src/index.ts            the only Cloudflare-specific entry: builds Deps from env, routes, runs the cron
  src/deps.ts             Deps { store, limits, clock, vars }; the interfaces handlers take
  src/store.ts            installs and reports, plain SQL over a run/all/batch shim
  src/store-d1.ts         the shim over the D1 binding
  src/installs.ts         POST /v1/installs, DELETE /v1/installs/me, token hashing
  src/reports.ts          POST, GET, DELETE /v1/reports
  src/validate.ts         schema check of 2.4; `canonical(body)` and `splitExact(body)`
  src/issue.ts            title, body and labels (6), pure functions; only the script imports it
  src/ratelimit.ts        the bindings and the mint ceiling (4.6); the only module that reads cf-connecting-ip
  src/cells.ts            the grid (5.2)
  src/retention.ts        the cron job
  src/errors.ts, time.ts  the error envelope; hour-precision timestamps
  test/*.test.ts          one file per module, plus fixtures
  test/store-sqlite.ts    the same shim over node's built-in `node:sqlite`
```

Handlers are plain functions, `(request, deps) => Response`. None imports anything from Cloudflare or reads `env`; only
`src/index.ts` and `src/store-d1.ts` know the platform. Moving to another SQLite host is a new shim and a new entry file.

### 7.2 `wrangler.jsonc`

```jsonc
{
  "name": "peoplemaps-reports",
  "main": "src/index.ts",
  "compatibility_date": "2026-10-01",
  "workers_dev": true,
  "preview_urls": false,
  "observability": { "enabled": false, "logs": { "invocation_logs": false } },
  "vars": { "RETENTION_DAYS": "90", "REPORTS_PER_DAY": "20", "INSTALLS_PER_HOUR": "60" },
  "d1_databases": [{ "binding": "DB", "database_name": "peoplemaps-reports", "database_id": "979b9c50-a12a-40d2-a31a-315a4b276204", "migrations_dir": "migrations" }],
  "ratelimits": [
    { "name": "RL_AUTH", "namespace_id": "1001", "simple": { "limit": 10, "period": 60 } },
    { "name": "RL_INSTALLS", "namespace_id": "1002", "simple": { "limit": 2, "period": 60 } },
    { "name": "RL_REPORTS", "namespace_id": "1003", "simple": { "limit": 10, "period": 60 } }
  ],
  "triggers": { "crons": ["17 3 * * *"] }
}
```

The database ID is not a secret. `preview_urls` stays explicit, because since wrangler 4.44 it otherwise follows
`workers_dev`, and each version's URL would be public. `invocation_logs` stays false even if `observability` is later
turned on for debugging.

**Secrets.** The Worker has none. `CLOUDFLARE_API_TOKEN` (Workers Scripts: Edit, D1: Edit) and `CLOUDFLARE_ACCOUNT_ID` are
environment secrets of the GitHub Environment `production`, not repository secrets: a repository secret with D1 edit
rights would let any workflow merged to `main` read `exact_json`, and the environment's required reviewer stops that.

### 7.3 Tests, local run, CI, deploy

- `npm test` runs vitest under node 22.13 or later against `test/store-sqlite.ts`, an in-memory SQLite database with the
  migrations applied: no account, no login, no Miniflare. `npx tsc --noEmit` checks the types. The tests cover the API,
  validation, the exact split, retention, the rate limits, the D1 limit error, the issue builder and the parity fixtures.
- `npm run dev` is `wrangler dev --ip 0.0.0.0 --port 8787` with a local D1, so a phone on the same network can reach it.
  A tester who needs a higher cap sets `REPORTS_PER_DAY=50` in `.dev.vars` (gitignored).
- `.github/workflows/ci.yml` has a `backend` job that runs both on every PR. `.github/workflows/backend.yml` runs on a
  push to `main` touching `Backend/`: the tests, then `wrangler d1 migrations apply --remote` and `wrangler deploy` in a
  job that waits for approval on the GitHub Environment `production`.
- `Scripts/verify.sh` does not cover the backend; the verify skill has a row for it.

### 7.4 Versioning and rollout

The API is `/v1/`. A field is added without a version bump; a field that changes meaning bumps `schema` and the Worker
accepts both for one app release. The Worker is deployed before the app that needs it.

### 7.5 How the app learns the base URL

`App/Info.plist` gets `PeoplemapsReportsURL` with the value `$(PEOPLEMAPS_REPORTS_URL)`. `Scripts/generate_project.py`
sets it per configuration: Debug `http://127.0.0.1:8787`, Release
`https://peoplemaps-reports.<account-subdomain>.workers.dev`. `Core` takes `baseURL`, so nothing else names the host.
`App/Info.plist` also gets `NSAllowsLocalNetworking`, which only relaxes local addresses (question 2).

In Debug builds the UserDefaults key `PeoplemapsReportsURL` overrides the plist value, set by the launch argument
`--reports-url <url>` or a field in the Debug-only footer of Flagged moments, so a tester's phone can reach the Mac or the
deployed Worker. Release builds ignore the key. `--ui-testing` uses the stub (8.4).

## 8. App integration

Not built yet, apart from the `Core` files.

### 8.1 Files

- `Core/Reports.swift`: the model, `ReportStore`, `ReportEncoder` (key order of 2.4, the bytes `JSON.stringify` writes).
  `Core/ReportsClient.swift`: the API and the tap-level calls. `Tests/ReportsTests.swift` covers both, with the parity
  fixtures.
- `SearchIndex` gains `dataVersion`. `NativeRouter.nearestIntersection(to:mode:)` and `route(ids:mode:)` become public.
- `App/Reports/ReportsStore.swift`: `@Observable` wrapper over `ReportStore`.
- `App/Reports/ReportsClient.swift`: `URLSession` with `ephemeral` configuration, Keychain access, the stub (8.4). Every
  call comes from a tap handler.
- `App/Reports/FlaggedMomentsView.swift`: the list. Footer: "Your report ID", "Check status" (when anything has been sent),
  "Delete my reports" with its local count and confirmation, Export all, and a link to `Docs/PRIVACY.md` on GitHub.
- `App/Reports/ReportComposerView.swift`: category picker, note field, exact-locations toggle (off), "Remove start",
  "Remove destination", then the review of every field and Send. Send is disabled without a connection.
- `App/Navigation/GuidanceView.swift`: a "Flag this moment" button, 56 pt tall. One tap, haptic `.success`, reads "Flagged"
  for two seconds, no sheet, no text. Identifier `flag-moment`. VoiceOver: "Flag this moment. Saves the current route and
  instruction on this phone to report later."
- `App/Navigation/FerrostarAdapter.swift` and `OwnRouteProvider.swift`: `AdaptedRoute` gains `comparison` and `usedCalmer`,
  since nothing else holds the route's edges and hashes after a reroute.
- `App/Navigation/NavigationController.swift`: the last three spoken texts with the destination's name replaced, the
  reroute count, and `snapshot(store:)`.
- `App/ExploreView.swift`: a "Flagged moments" row in the home footer next to About, with an unsent count.
- `App/PrivacyInfo.xcprivacy`: `NSPrivacyCollectedDataTypes` gains Coarse Location, Precise Location, Other User Content,
  Other Diagnostic Data and User ID, each not linked, not tracking, purpose `AppFunctionality`. App Store Connect's answers
  must say the same.
- `Scripts/generate_project.py`: the build setting of 7.5; rerun it, since `App/Reports/` is new.

### 8.2 Copy

Follows the product rules. The composer never asks whether a route was safe; the category reads "The calmer route was a
bad choice". The review screen header: "This goes to the people who make PeopleMaps. If it helps, a maintainer may file a
public GitHub issue from it by hand: your note and the route, which starts and ends at the snapped corners, but never your
exact locations or report ID. Exact locations stay off unless you turn them on; nothing has left this phone yet." The note
field asks not to put names or addresses in it. The "Delete my reports" confirmation: "Delete 3 sent reports and your
report ID from our server? This does not remove a public issue a maintainer has already filed." The flag button says
nothing about the problem. The review shows `route.stress` because it shows every byte; no other screen shows a score.

### 8.3 Behaviour details

- Flag works in every guidance state and never needs network, shows a sheet or speaks. Flagging twice within five seconds
  updates the first snapshot.
- The composer sends one report per tap, and a send in flight blocks a second tap. Failure shows the error in words ("No
  connection", "The server refused this report (invalid_report: note)", "Too many reports today") and keeps everything.
- A 401 is handled as in 4.1. An interrupted Send is handled as in 4.2.
- There is no way to change the report ID on its own. "Delete my reports" is the reset.

### 8.4 UI test

Under `--ui-testing`, `ReportsClient` registers a `URLProtocol` stub that answers `POST /v1/installs` with a fixed token,
`POST /v1/reports` with 201 and `DELETE` with 204, and records every body. `NavigationDebugProbe` gains
`debug-last-report`. The test starts simulated guidance, taps `flag-moment`, ends navigation, opens `flagged-moments`,
picks "Wrong instruction", types a note, leaves exact off, checks the review shows `"exactLocations": false`, taps Send,
checks the row reads "Sent" and the body has `location == null`, both endpoints `intersection` and non-empty `edgeIDs`, and
relaunches with `--keep-saved` to see the row survive.

## 9. Later: automatic triage

Deferred until hand-filed issues show it is worth it. The idea: an `app-report` label starts a workflow that replays the
report, comments with the result and opens a draft PR for a small, testable cause in `Core/`. A person reviews and merges.
Any note in an issue is public text, so it must only ever reach a model as fenced data, never as instructions.

## 10. Open questions

Numbers are stable, so code comments can cite them; gaps were resolved or removed.

1. **Worker URL.** Decided: `peoplemaps-reports.<account-subdomain>.workers.dev` for now, with no custom domain (7.5). The
   account subdomain is set once and the Worker is never renamed, since either changes the URL shipped apps call. To move
   later: add the new host in `routes` and keep `workers_dev: true` (wrangler turns it off when `routes` is set otherwise),
   so the Worker serves both; point the Release URL at the new host; and turn `workers_dev` off only once
   `installs.app_version` shows the old builds are gone. See 17.
2. **Loopback in Release.** `NSAllowsLocalNetworking` in the shared `Info.plist` also ships in Release. It only affects
   local addresses. Recommended: accept it.
4. **Timestamp granularity.** Hour, UTC. Recommended: keep.
5. **Where Flagged moments lives.** The home footer beside About. Recommended: there; no Settings screen exists yet.
6. **Backups.** Recommended: exclude `reports/`; a flagged moment is not worth restoring.
7. **The note.** No scrubbing of names or addresses, a warning in the UI and 280 characters. Recommended: keep; scrubbing
   fails silently and over-promises. The maintainer reads it before any filing.
8. **Unsent limit.** Fifty total, dropping the oldest sent first. Recommended: keep.
9. **Sending during guidance.** Not possible. Recommended: keep, for the no-typing rule.
12. **Install pruning.** Installs with no reports for a year are deleted (5.3). Recommended: keep.
13. **Zero cost.** Default: no card on any account. App Attest (19) is the one planned exception.
14. **Public IP claim.** "We never store or log IP addresses; Cloudflare necessarily sees them to deliver traffic." Default:
    that sentence and nothing stronger, once the check of 4.6 backs it.
16. **Filing.** Decided: by hand, and automatic filing is deferred. If volume makes that a chore, automatic filing needs a
    new policy version first, and an approval step, since public issues cannot be recalled.
17. **API domain.** Decided: `workers.dev` for now, so there is no domain to buy. This trades away "leaving Cloudflare is
    only a DNS change": moving needs the both-hosts period of question 1. That is cheap with no shipped builds, and the
    base URL stays a build setting.
18. **Server language.** Default: TypeScript. `splitExact` must drop exactly what `Core/Reports.swift` drops, so shared
    fixtures in `Backend/test/fixtures/parity/` are read by both test suites.
19. **App Attest.** Default: required before App Store release, not for TestFlight; budget Workers Paid at $5 a month. Moving
    to Paid makes Time Travel 30 days, and the policy changes in the same PR (5.3).
21. **Endpoints in a filed issue.** Default: coarsened to the 550 m cell (6), with the route-ends caveat stated there and in
    `Docs/PRIVACY.md`.
25. **Data location.** Owner to decide. `Docs/PRIVACY.md` says "in the United States", but the database
    (`979b9c50-a12a-40d2-a31a-315a4b276204`, empty) was created with a `wnam` location hint, and Cloudflare says a hint is not
    a guarantee. A `--jurisdiction=us` database is the guaranteed form, and a jurisdiction can only be set at creation. To
    make the claim hold, recreate it while it is empty: `npx wrangler d1 create peoplemaps-reports --jurisdiction=us`
    (wrangler, since the Cloudflare connector cannot set a jurisdiction), commit the new ID and delete the old database.
    Otherwise soften the policy's sentence. A jurisdiction covers where the database runs and stores data; the Worker itself
    still runs at the Cloudflare location nearest the sender.
26. **Deleting after a hand-filed issue.** Owner to decide. An issue carries no report ID, so "Delete my reports" cannot find
    it, and the policy says so. Default: accept that, because filing is rare and a maintainer has read it first. If that is
    not enough, the options are to file only in the maintainer's own words, or to record the issue number on the row and
    tell the maintainer on delete.
27. **Check status.** Owner to decide. With no issue state it can only show that a report is still held and until when.
    Default: keep `GET /v1/reports`, since it is the sender's view of what the server holds, and decide when the screen is
    built. Dropping the button later removes one sentence from the policy.

Considered, not chosen: TestFlight feedback through the App Store Connect API (no replay fields and no deletion by the
sender); a stateless Worker writing to R2 with a lifecycle rule (no idempotency or per-install caps); client-side
encryption of the exact fields to a maintainer key (worth revisiting if exact locations get common); an OHTTP relay so
Cloudflare never sees client IPs (out of proportion at this volume).
