# Problem reports

Design for in-app problem reports. `Backend/` and `Core/Reports*.swift` build from it; the app screens in section 8 are
not built yet. **For the alpha the backend is not deployed: the app uses section 11 instead (a share-sheet file and a local
usage log) and never calls `ReportsClient`.** The user-facing version of the data rules is `Docs/PRIVACY.md`; keep the two in step. Read with
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
| `request.preferences` | null | Always null for now; the Worker refuses anything else, because an open object could hold anything. The "Calmer means" sheet (`Docs/DESIGN.md` 4.6, #6) adds a strict shape when it lands | yes |
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
{ "kind": "intersection", "lat": 47.62980, "lon": -122.35931, "osmNode": 53070456 }
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
- **`placeID`** names the exact place, such as a clinic, so it is an exact field: it is sent only on an exact endpoint and
  stored only in `exact_json`. The Worker refuses it on a snapped endpoint (question 28). It is kept only for a public named
  place, when it matches `^(node|way|relation)/\d{1,19}$`; addresses, pins and the user's position never carry one. The
  key is omitted, not sent as `null`.
- **`location`**: `accuracy` is 0 to 10,000 m; `course` is -1 to 360, or `null` when the fix has no heading.
- Both forms are stored on the phone, so review can switch without recomputing. Only the chosen form is sent.

### 2.3 Report fields

The report is the snapshot plus `category` (`wrong_instruction`, `calmer_bad_choice`, `map_data`, `voice_timing`,
`other`), `note` (0 to 280 characters or null, in the user's words) and `exactLocations` (per report, default false).
`sentAt`, `serverID`, `expiresAt` and `sentInstallID` (the public install ID it was sent under, 3) stay on the phone as the
receipt.

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
    "origin": { "kind": "intersection", "lat": 47.62980, "lon": -122.35931, "osmNode": 53070456 },
    "destination": { "kind": "intersection", "lat": 47.64521, "lon": -122.33498, "osmNode": 53077201 },
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
  "position": { "stepIndex": 3, "shownStepIndex": 4, "distanceToManeuver": 86.5, "remainingMeters": 2890.1, "remainingSeconds": 402.0, "cell": "r29c11" },
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

1. **Data version.** Compare `route.dataVersion` with the graph's SHA-256. `graphSHA256` is only in the search index's meta
   row today (`Scripts/build_search.py`). Naming the commit behind a mismatch with `git log -S` first needs the importer to
   write it to `Data/provenance.json` too, which has not landed.
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
- **Delete.** Swipe to delete one snapshot; "Delete all flagged moments" empties the list (the earlier-ID flag of 4.4 stays). Neither contacts the server.
  "Delete my reports" (4.4) reaches only reports sent under the current report ID. It shows the count of local `sent`
  snapshots recorded under the current ID, calls `DELETE /v1/installs/me` on confirmation and, once the server has
  deleted them, marks those copies `withdrawn`. A snapshot sent under an earlier ID (after a reset, say because the key
  was damaged) stays `sent`: the app cannot delete it from the server, and it expires within 90 days of sending.
- **Which ID.** Each `sent` snapshot records the public install ID it was sent under (`sentInstallID`). The bearer
  token is never stored on a snapshot. Like the install ID elsewhere (2.4), it is not part of the export or the sent
  body. A snapshot stored before this field existed has none, and the app does not claim it is under the current ID.
- **Network.** No request is automatic: not when the list opens, not at launch, not on a timer. The client contacts the
  server only on Send, "Check status" (`GET /v1/reports`) and "Delete my reports". Each is one explicit tap.
- **Backups.** The `reports/` folder is marked `isExcludedFromBackup`, because it holds exact coordinates.

## 4. HTTP API

Base URL per build (7.5). JSON in and out. Every response carries `Cache-Control: no-store`. No cookies, no CORS. TLS
only; `http://` is only for `wrangler dev`.

**What needs no token.** `POST /v1/installs` (4.1), and the App Attest routes `POST /v1/attest/challenge` and `POST
/v1/attest` (4.5), which hand out the download token of 4.7. There is no health route. An unknown path or method is a 404 and
the other routes are a 401 without a token, and neither carries data. So the backend is not closed to strangers today:
anyone on the internet can mint a token, then send up to the caps of 4.2 and read or delete only what that token sent. They
never reach another install's reports. What holds against this is 4.6's limits, and App Attest (4.5) is what would close it.

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
install was deleted or never existed. On a Send, the app wipes its Keychain items, shows "Your report ID was reset", mints
a new token and retries that send once. "Check status" and "Delete my reports" never mint, and a 401 there follows 4.4. No
request mints a token on its own.

### 4.2 Send a report

```
POST /v1/reports
Body: the report (2.4); its `id` is the idempotency key
201 { "id": "6F1D…", "receivedAt": "2026-10-31T21:00:00Z", "expiresAt": "2027-01-29T21:00:00Z" }   // stored
200 { same shape }                                                                                 // a retry with the same id and body
409 { "error": "conflict", "message": "Report 6F1D… already exists and cannot be stored again." }
503 { "error": "storage_unavailable", "message": "…" }, Retry-After on the daily limits only      // D1 refused the write (4.6); nothing kept
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
  A 401 after a normal delete cannot lead here, since the install's rows went with it. A damaged key is different: the
  old rows stay for up to 90 days, so re-sending a report under a new ID while the old ID still holds the same `id` gets
  a 409. The message must not claim the content differs (4.2 wording); the app treats it like any 409.
- A Send cut off by the app quitting reads as `flagged` with `lastError: interrupted` on load; re-sending reuses the
  `id`, so if the server stored the first attempt the retry gets 200.
- Rate limit: `REPORTS_PER_DAY` (5) per install, counted from its own rows in the last 24 hours, plus the edge limits (4.6).

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
"Delete my reports" is also "start over".

**Delete reaches the current report ID only.** If the phone's key was damaged, the next Send resets the ID (4.1) while the
old ID's reports stay on the server until they expire, up to 90 days after sending. The app cannot delete those: it has
no key for the old ID. So "Delete my reports" counts, deletes and marks `withdrawn` only the local `sent` copies
recorded under the current ID. Copies under an earlier ID stay `sent`.

**Only a `204` means deleted.** A retry after a lost `204` gets a 401, but so does a damaged token whose reports are still
on the server, and nothing in a 401 tells them apart. So the app does not claim either.

| "Delete my reports" gets | Result | Keychain | Local copies | The user is told |
|---|---|---|---|---|
| `204` | `deleted` | wiped | `withdrawn` if sent under the current ID; copies under an earlier ID stay `sent` | "Your reports and report ID were deleted from our server." only when `ReportStore.earlierIDMayHoldReports` is false; otherwise the wording below |
| Worker's 401 | `notRecognized` | kept | stay `sent` | "Our server doesn't recognise this report ID, so we can't confirm whether your reports were deleted. Anything left expires within its 90 days." |
| Anything else, including a 401 without the envelope | throws | kept | stay `sent` | the error in words; the user can tap Delete again |

"Check status" keeps everything on a 401 too and shows the same words. Delete and Check status keep the credentials after a 401, since neither
needs a new ID and the 401 could be a passing fault, so the key stays for another try. Send resets on the same 401 because a
new report needs a working ID. The user is not stuck: the next Send gets the same 401, resets the ID and mints a new one
(4.1). Local copies stay `sent`, since nothing confirms they were deleted, and once the ID resets they are under an earlier
ID, so a later Delete does not reach them.

**Whether an earlier ID may hold reports comes from a saved flag, not from the rows on the phone.** Rows can go: a swipe,
the 50-snapshot limit dropping the oldest sent one, or a Send cut off before the app heard the answer. So the store keeps
two flags in its file: the current ID may hold reports once a Send has begun under it, and when the ID is reset while that
is set, `earlierIDMayHoldReports` is set for good. A 204 clears the first flag only; "Delete all flagged moments" empties the
list and keeps both.

**Wording after a `204` when an earlier ID may hold reports.** The confirmation must not claim all reports were deleted
when `earlierIDMayHoldReports` is set, whatever rows remain. With local `sent` copies under an earlier ID it says: "Deleted 1 report under your current report ID. 2 other
reports were sent under an earlier report ID. We can't delete those from the app, and they expire within 90 days of
sending." The numbers are the count marked `withdrawn` and the count left `sent`; "report" is singular for 1. If none were
marked (every `sent` copy is under an earlier ID), the first sentence reads "No reports were sent under your current
report ID." With no such rows left it says only "Deleted reports under your current report ID. Reports sent under an
earlier report ID can't be deleted from the app, and they expire within 90 days of sending." The pre-delete confirmation counts only current-ID copies, and when others exist it adds "N more were sent under
an earlier report ID and can't be deleted from the app." It never says "safe", and it says "can't confirm" where it doesn't
know.

A hand-filed issue (6) is not reached by these; see question 26.

### 4.5 App Attest

**Built, used by region downloads (4.7); `POST /v1/installs` can adopt it.** The Worker side is in `Backend/src/attest.ts`
(routes and verifier), `x509.ts` and `cbor.ts` (just enough DER, X.509 and CBOR, WebCrypto only, no dependency) and
`apple-root.ts` (Apple's App Attestation Root CA, pinned). Requiring it on `POST /v1/installs` as well, so a report token
can only be minted by a genuine copy of the app, is still planned before App Store release and not needed for TestFlight;
it budgets Workers Paid at $5 a month for the CPU it needs (question 19).

```
POST /v1/attest/challenge
201 { "challenge": "<base64, 32 bytes>", "expiresAt": "2026-10-31T21:39:00Z" }

POST /v1/attest
Body: { "keyId": "<base64>", "attestation": "<base64>", "challenge": "<the challenge as received>" }
200 { "token": "pmd_…", "expiresAt": "2026-11-01T21:34:00Z" }
401 unauthorized                  // challenge unknown, used or expired; or the attestation failed
400 invalid_report with field     // not base64, wrong length, unknown key
```

- **The challenge** is 32 random bytes, usable once, for 5 minutes. D1 holds only its SHA-256 (`attest_challenges`, 5.1),
  and `POST /v1/attest` deletes it before verifying, so a failed attempt spends it too. The app passes SHA-256 of the
  decoded 32 bytes as `clientDataHash` to `DCAppAttestService.attestKey`. Base64 in requests may be standard or URL-safe,
  padded or not; responses use standard base64.
- **The checks**, per Apple's "Validating apps that connect to your server": the object is CBOR with `fmt`
  `apple-appattest`; `x5c` is a leaf and an intermediate that chain to the pinned root, each certificate inside its
  validity and each issuer a CA; the leaf's `1.2.840.113635.100.8.2` extension holds SHA-256(authData ||
  SHA-256(challenge)); SHA-256 of the leaf's public key is `keyId`; authData's rpIdHash is SHA-256 of the `APP_ID` secret
  (`<team id>.<bundle id>`), its counter is 0, its aaguid is `appattest` (or `appattestdevelop`, accepted only when the
  `ATTEST_ENV` var is `development`), and its credential ID is `keyId`. The receipt is not stored or sent to Apple.
- **On success** the key's public key, counter 0, environment and hour go in `attest_keys` by key ID, and the answer is a
  download token (4.7). Retention drops keys `RETENTION_DAYS` after they were attested (5.3).
- **Not set up.** Until `APP_ID` and `DOWNLOAD_TOKEN_SECRET` are set (`Backend/README.md`), both routes answer `500
  internal` and store nothing.
- **Limits.** `RL_ATTEST`, 10 per minute per IP or /64, on both routes, checked before the body is read (4.6).
- **Assertions are not built.** Today the app attests a fresh key whenever it needs a token and holds none unexpired, at
  most once a day and only around a region download. To renew without attesting again, add `POST /v1/attest/assert` with
  `{ keyId, assertion, challenge }`: check the ECDSA signature over SHA-256(authenticatorData || SHA-256(challenge)) with
  the stored public key, the rpIdHash and a counter above the stored one, store the counter and issue a token. The table
  already holds what it needs.
- **Tested** against a synthetic chain built in the test (a self-signed P-256 root standing in for Apple's, an intermediate,
  a leaf with the nonce extension), with the root injected through `AttestConfig.rootPEM`. Apple's real root is the
  production default; the tests parse it and check its self-signature, but **no attestation from Apple's real chain has
  been verified**. That needs a recorded attestation from a real phone, checked with a fixed clock.

What remains from the original estimate (500 to 800 lines, two to three working days, most of the risk on a real phone)
is the app side and the step to `POST /v1/installs`:

- **Worker, for installs.** The challenge route, the verifier and the key table above are what the estimate's Worker part
  described. What is left is requiring a verified attestation (or an assertion) in `mintInstall`, its tests, and a test
  against a recorded attestation from a real phone, checked with a fixed clock because the certificates expire.
- **App,** 150 to 250 lines with tests, and the App Attest entitlement through `generate_project.py` and the App ID. An
  attestor protocol in Core, and `DCAppAttestService` in `App/`, since Core also builds on Linux.
- **Simulator and tests.** `DCAppAttestService` is not available in the Simulator, so no simulator can mint from the
  deployed Worker. The UI test (8.4) already stubs the network, so it only needs a fake attestor under `--ui-testing`.
  A simulator against `wrangler dev` needs a switch such as `ATTEST_REQUIRED=false` in `.dev.vars`, and a test that
  `wrangler.jsonc` never sets it. The real path runs only on a phone, by hand; CI cannot cover it.
- **Decisions it brings.** A device where App Attest is unsupported, or an Apple outage, cannot mint, so its report stays
  flagged. Development and production builds attest under different environments, and the Worker must accept the right ones.
- **What it does not do.** It shows a genuine app on a genuine device, not an honest sender. One phone can make many keys, so
  4.6's limits stay, and the token is still a bearer token after minting.
- **Not measured.** Whether the verifier fits Workers Free's 10 ms of CPU, which only a deployed Worker can show, and whether
  a free Apple team can enable the capability.

### 4.6 Rate limits, errors, what is not kept

- Minting a token needs no identity, so every per-install cap can be reset by minting again. The limits that hold against
  that are keyed by client IP at Cloudflare's edge, where our code and database never store it. Three Workers rate
  limiting bindings in `wrangler.jsonc`, 60-second windows: `RL_AUTH`, 10 per minute keyed on the token hash, for every
  authenticated route; `RL_INSTALLS`, 2 per minute, and `RL_REPORTS`, 10 per minute, keyed on `cf-connecting-ip`, or its /64
  for IPv6, since one home or phone usually holds a whole /64. `POST /v1/reports` checks `RL_REPORTS` before it looks up
  the token, so a flood of made-up tokens meets the IP limit first. It is read only in `src/ratelimit.ts`, passed straight to the
  binding and never stored. Over a limit is `429 rate_limited` with `Retry-After`. Two more serve 4.5 and 4.7:
  `RL_ATTEST`, 10 per minute per IP or /64, on both App Attest routes, and `RL_DOWNLOADS`, 60 per minute keyed on the
  download token's key ID.
- The bindings are approximate and count per Cloudflare location, so a flood spread across locations gets more. The
  strict backstop is `INSTALLS_PER_HOUR` (60), counted from `installs.created_at` in the current hour.
- **D1's Free daily limits** (5 million rows read, 100,000 rows written, enforced since 2026-09-01). Once spent, every
  query fails until 00:00 UTC with D1's documented "free tier daily row read limit" or "write limit" error. The Worker
  answers `503 storage_unavailable` with `Retry-After` set to 00:00 UTC, and the app keeps the report flagged with "The
  report server is full for today. Try again after <local time>." The report is not parked anywhere else, since a second
  store would need its own retention and its own line in the policy.
- **D1's size limits** ("Exceeded maximum DB size." and the account storage limit) also get `503 storage_unavailable`, with
  the message "The report server is full." and no `Retry-After`, since only retention or a maintainer frees them, not
  midnight. The app shows "The report server is full. Try again later."
- **Refused bookkeeping.** `authenticate` updates `last_seen_at` best effort, so a refused update never blocks a read or a
  delete. A stale value can only get an empty install pruned a little sooner (5.3), and the next accepted request updates
  it.
- **Accepted for now, at zero users.** Workers Free allows 100,000 requests a day, and D1 and that limit stop rather than
  bill on a no-card account, so these are outages, not costs: a flood filling the free D1 database; one IP spending the
  global mint ceiling; and unknown-token 401s counting against the daily requests. Fix them when there are users to lose.
- Errors are `{ "error": code, "message": text, "field"?: path }`. Codes: `unauthorized` 401, `not_found` 404,
  `invalid_report` 400, `too_large` 413, `conflict` 409, `rate_limited` 429, `storage_unavailable` 503, `internal` 500,
  and for downloads (4.7) `precondition_failed` 412 and `range_not_satisfiable` 416.
- The Worker never logs a request object, a header, an IP, a user agent or a body. `observability.enabled` and
  `observability.logs.invocation_logs` are false in `wrangler.jsonc`, and `console.*` is allowed only with a constant
  string plus a count or status. A test checks both.
- **Before the policy is published**, send the deployed Worker some requests and read what Workers Logs and the
  dashboard's request views record. `Docs/PRIVACY.md` says only what that check showed. Recheck after Workers Logs pricing
  changes on 2026-12-01, since changed defaults can come with it.
- Bodies over 64 KB are refused before parsing (`content-length` first, then a streaming count).

### 4.7 Region downloads

The generated data for a region lives in the private R2 bucket `peoplemaps-data`, bound as `DATA`. The Worker serves it
to a genuine copy of the app (4.5), so no key ships in the app. Code: `Backend/src/regions.ts` and `download-token.ts`.

```
GET /v1/regions/{release}/{region}--expected__{file}
Authorization: Bearer pmd_…                          // from POST /v1/attest (4.5)
Range, If-Range, If-None-Match, If-Match              // optional
200 the file | 206 a range | 304 | 401 | 404 | 412 | 416 | 429
```

- **What is served.** Objects are keyed `<release>/<region>--expected__<file>`, for example
  `data-seattle-all-2026-11d/king-county--expected__seattle-graph.bin`. The files per region are the `expected/*`
  outputs listed in `Data/regions.json`. The release must match `^data-[a-z-]+-\d{4}-\d{2}[a-z]?$` and the object
  `^[a-z-]+--expected__[A-Za-z0-9.-]+$`, so importer inputs and `source/` objects are never served. Anything else is a
  404 that never reaches R2.
- **The token** is `pmd_` and 92 base64url characters: a version byte, the expiry, the 32-byte App Attest key ID and an
  HMAC-SHA256 over them keyed with the `DOWNLOAD_TOKEN_SECRET` secret. It lasts 24 hours. It is stateless, so a download
  reads nothing from D1; changing the secret revokes every token. Without a valid, unexpired token every download is a
  401, checked before the name or the bucket.
- **Ranges.** A single `bytes=` range (`a-b`, `a-`, `-n`) gets 206 with `Content-Range`; a range past the end is 416 with
  `Content-Range: bytes */size`; a multi-range or malformed header is ignored and the whole file sent. `If-Range` with the
  current ETag resumes; with another ETag the whole file comes back. `If-None-Match` and `If-Match` go to R2's `onlyIf`,
  for 304 and 412. Answers carry `ETag`, `Accept-Ranges: bytes`, `Content-Length`, `Last-Modified` and `Cache-Control:
  no-store`. A ranged request costs an R2 `head` and a `get`, a whole file one `get`. The body is R2's stream, never
  buffered.
- **Limits.** `RL_DOWNLOADS`, 60 per minute keyed on the token's key ID: a region is 5 files, which leaves room for
  resumed ranges and retries.
- **What is kept and logged.** Nothing beyond the attest key (4.5): no download row and no log line. The request carries
  only the token and the file name.
- **Tested** against an in-memory R2 stand-in (`test/helpers.ts`). Real R2 is not exercised, and nothing is deployed.

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

`Backend/migrations/0002_attest.sql` adds App Attest (4.5): `attest_challenges (id, expires_at)`, the SHA-256 of each
challenge and its expiry to the second, and `attest_keys (key_id, public_key, counter, environment, created_at)`, each
attested key by its base64 key ID, `created_at` to the hour.

Anything else a maintainer wants is in `public_json`: `json_extract(public_json, '$.request.mode')`.

### 5.2 The cell grid

`position.cell` is a grid square about 550 m on a side over the all-Seattle box of `Docs/COVERAGE_SPIKE.md`, so growing the
data does not change the grid: row `floor((lat - 47.49) / 0.005)`, col `floor((lon + 122.44) / 0.0075)` of the route point at
flag time, clamped to rows 0 to 49 and columns 0 to 26. The Worker has no graph, so the app computes it; the Worker checks it is a cell of the grid and stores it in `public_json`.

Aggregate counts over this grid are deferred, since nothing reads them. Keeping `position.cell` in the body lets them be
rebuilt from any rows still held; rows deleted before then are not counted.

### 5.3 Retention

One cron, `17 3 * * *`: `DELETE FROM reports WHERE expires_at < now()`, delete installs not seen for 365 days that
have no reports, expired attest challenges, and attest keys attested more than `RETENTION_DAYS` ago. It logs one count, and the handler awaits the job so a failure fails the invocation rather than vanishing.

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
with tests. The maintainer reads it first and edits or drops the note if it has a name or address in it. The note is shown as an
indented code block, which has no closing line for the text to match, so sender text does not mention a user or link an
issue when the maintainer files it. `@` and `#` in a quoted instruction in the title are made inert.

**Before first deploy** (the backend is not deployed for v0.1.0): refuse control characters in sender text (Worker and
client together); a distinct code and a real `Retry-After` for the daily cap, and a test pinning it at 5; make the title
inert before cutting it, defuse `GH-1` and issue URLs, and cap the issue body near 60,000 characters; correct the
IP-limit wording here and in `Docs/PRIVACY.md` (only `POST /v1/reports` checks it before the token, and it limits rather
than prevents flooding); revisit the 2,000-ID limit when coverage grows past Seattle.

- **Title.** `[app-report] <Category words>: "<last spoken text>" (<mode>, <dataVersion>)` for instruction and voice
  categories, or `step <shownStepIndex>` when nothing was spoken or the trip had arrived. For the others,
  `<origin cell> → <destination cell>`, never a street name.
- **Body.** `### <Label>` sections: Category; What happened; Data version; App version; Flagged at; Route request; Route;
  Position; Spoken instructions; Navigation state; Device. Everything a replay needs is there.
- **Kept: the position.** `position` (step, distance to the manoeuvre, what remains and the cell) stays, because a replay
  lands on that step.
- **Omitted:** exact endpoints, `location`, the `exactLocations` flag, the install ID and report ID, and the snapped
  endpoints' coordinates and `osmNode`: each endpoint shows as its cell.
- **What coarsening does not hide.** `edgeIDs` and `wayIDs` stay, because the plan replay needs the whole route, and a
  route starts and ends at its snapped intersections. Anyone with the map data can read those corners off the first and
  last edges, and with `position` can work out to within metres where the sender was when they flagged. The maintainer can
  cut the route and position from a sensitive issue; `Docs/PRIVACY.md` says this.
- **Labels.** `app-report`, `report:<category>`, `mode:<mode>`, created once with `gh label create`.

## 7. Backend layout

### 7.1 Tree

```
Backend/
  README.md               run, test, deploy
  package.json            wrangler, typescript, vitest, @cloudflare/workers-types
  wrangler.jsonc          see 7.2
  migrations/0001_init.sql, 0002_attest.sql
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
  src/attest.ts           POST /v1/attest/challenge, POST /v1/attest and the attestation verifier (4.5)
  src/x509.ts, cbor.ts    just enough DER, X.509 and CBOR for App Attest
  src/apple-root.ts       Apple's App Attestation Root CA
  src/download-token.ts   the HMAC download token (4.7)
  src/regions.ts          GET /v1/regions/{release}/{object} (4.7)
  src/bytes.ts            base64, hashing and comparison helpers
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
  "vars": { "RETENTION_DAYS": "90", "REPORTS_PER_DAY": "5", "INSTALLS_PER_HOUR": "60", "ATTEST_ENV": "production" },
  "d1_databases": [{ "binding": "DB", "database_name": "peoplemaps-reports", "database_id": "22e78664-ede8-40dd-80bf-7e2b0e7ec41f", "migrations_dir": "migrations" }],
  "r2_buckets": [{ "binding": "DATA", "bucket_name": "peoplemaps-data" }],
  "ratelimits": [
    { "name": "RL_AUTH", "namespace_id": "1001", "simple": { "limit": 10, "period": 60 } },
    { "name": "RL_INSTALLS", "namespace_id": "1002", "simple": { "limit": 2, "period": 60 } },
    { "name": "RL_REPORTS", "namespace_id": "1003", "simple": { "limit": 10, "period": 60 } },
    { "name": "RL_ATTEST", "namespace_id": "1004", "simple": { "limit": 10, "period": 60 } },
    { "name": "RL_DOWNLOADS", "namespace_id": "1005", "simple": { "limit": 60, "period": 60 } }
  ],
  "triggers": { "crons": ["17 3 * * *"] }
}
```

The database ID is not a secret. `preview_urls` stays explicit, because since wrangler 4.44 it otherwise follows
`workers_dev`, and each version's URL would be public. `invocation_logs` stays false even if `observability` is later
turned on for debugging.

**Worker secrets and vars.** The Worker has two secrets, set by the owner with `wrangler secret put` and never written in
this file: `DOWNLOAD_TOKEN_SECRET` (4.7) and `APP_ID` (4.5), which holds the team ID and so is never committed. Until both
are set, the attest routes answer 500 and store nothing. `ATTEST_ENV` stays a `production` var here, and a test checks
it and that neither secret appears.

**Deploy secrets.** `CLOUDFLARE_API_TOKEN` is an account-owned token, from the Account API Tokens page, with
Workers: Editor and D1: Edit, and is narrowed to the `peoplemaps-reports` Worker once that exists. "Workers Scripts: Edit" is
the legacy name for Editor. Editor can deploy but cannot create or delete a Worker, and creating one needs product-level
Admin ([Workers roles](https://developers.cloudflare.com/workers/authorization/workers/)), so the first deploy runs by hand
(7.3). It and `CLOUDFLARE_ACCOUNT_ID` are environment secrets of the GitHub Environment `production`, not repository
secrets. That environment has no required reviewer and only `main` can deploy to it, so a workflow on any other branch
cannot read them. A workflow merged to `main` can, and that token has D1 edit rights, so it could read `exact_json`: merging to `main` is the only gate.

### 7.3 Tests, local run, CI, deploy

- `npm test` runs vitest under node 22.13 or later against `test/store-sqlite.ts`, an in-memory SQLite database with the
  migrations applied: no account, no login, no Miniflare. `npx tsc --noEmit` checks the types. The tests cover the API,
  validation, the exact split, retention, the rate limits, the D1 limit error, the issue builder and the parity fixtures,
  plus App Attest against a synthetic chain (4.5), the download token, and region downloads against an in-memory R2
  stand-in (4.7).
- `npm run dev` is `wrangler dev --ip 0.0.0.0 --port 8787` with a local D1, so a phone on the same network can reach it.
  A tester who needs a higher cap sets `REPORTS_PER_DAY=50` in `.dev.vars` (gitignored).
- `.github/workflows/ci.yml` has a `backend` job that runs both on every PR. `.github/workflows/backend.yml` runs on a
  push to `main` touching `Backend/`: the tests, then `wrangler d1 migrations apply --remote` and `wrangler deploy`. Deploys
  run automatically from `main` after the tests pass, with no approval step, on the GitHub Environment `production`.
- The deploy job runs only when the repository variable `BACKEND_DEPLOY` is `true`, so merging before the setup is done
  leaves `main` green with the job skipped. It must be a repository variable, since a job's `if` cannot see an
  environment's variables. Set it last.
- The first deploy and first remote migration run once by hand from the owner's logged-in Mac, from `main` after this stack
  merges, because the CI token cannot create a Worker (7.2). The order is in `Backend/README.md`: secrets, first deploy, narrow
  the token, then `BACKEND_DEPLOY`. After that, CI deploys, and `gh workflow run backend.yml --ref main` starts a deploy with
  no dummy push; the environment refuses any other branch.
- `Scripts/verify.sh` does not cover the backend; the verify skill has a row for it.

### 7.4 Versioning and rollout

The API is `/v1/`. The Worker refuses unknown keys (`validate.ts`), so a new field ships as optional on the Worker first,
then in the app, with no version bump. A field that changes meaning bumps `schema` and the Worker accepts both for one app
release.

### 7.5 How the app learns the base URL

`App/Info.plist` gets `PeoplemapsReportsURL` with the value `$(PEOPLEMAPS_REPORTS_URL)`. `Scripts/generate_project.py`
sets it per configuration: Debug `http://127.0.0.1:8787`, Release
`https://peoplemaps-reports.peoplemaps.workers.dev`. `Core` takes `baseURL`, so nothing else names the host. Once a build
ships, neither the account's `peoplemaps` subdomain nor the Worker's name may be renamed: either changes the URL it calls.
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
public GitHub issue from it by hand: your note, the route, which starts and ends at the snapped corners, and where along it
you flagged, but never your exact start and destination, GPS position or report ID. Exact locations stay off unless you
turn them on; nothing has left this phone yet." The note field asks not to put names or addresses in it. The "Delete my
reports" confirmation: "This phone remembers 3 sent reports. Delete every report under your report ID, and the ID, from our
server? This does not remove a public issue a maintainer has already filed." The count is of copies under the current ID
only; the after-delete wording is in 4.4. The flag button says
nothing about the problem. The review shows `route.stress` because it shows every byte; no other screen shows a score.

### 8.3 Behaviour details

- Flag works in every guidance state and never needs network, shows a sheet or speaks. Flagging twice within five seconds
  updates the first snapshot.
- The composer sends one report per tap, and a send in flight blocks a second tap. Failure shows the error in words ("No
  connection", "The server refused this report (invalid_report: note)", "Too many reports today") and keeps everything.
- A 401 is handled as in 4.1 and 4.4. An interrupted Send is handled as in 4.2.
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

1. **Worker URL.** Decided: `peoplemaps-reports.peoplemaps.workers.dev` for now, with no custom domain (7.5). The
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
25. **Data location.** Decided and done: the database (`22e78664-ede8-40dd-80bf-7e2b0e7ec41f`) was created with
    `wrangler d1 create peoplemaps-reports --jurisdiction=us`, and `wrangler d1 info` reports that jurisdiction. It can only
    be set at creation. A jurisdiction covers where the database runs and stores data; the Worker itself still runs at the
    Cloudflare location nearest the sender.
26. **Deleting after a hand-filed issue.** Decided: an issue carries no report ID, so "Delete my reports" cannot find it, and
    the policy says so. A maintainer removes a hand-filed issue on request. Filing is rare and a maintainer has read it first.
27. **Check status.** Decided for now: keep `GET /v1/reports`, since it is the sender's view of what the server holds, though
    with no issue state it can only show that a report is still held and until when. Dropping the button later removes one
    sentence from the policy.

28. **`placeID` with exact off.** Decided: sent and stored only with exact locations on (2.2),
    since an OSM ID names the exact place while the policy says location is collected only then. The cost is that route
    replay of a default report snaps by coordinate rather than using the importer's snap for that place; the plan replay is
    unaffected.

Considered, not chosen: TestFlight feedback through the App Store Connect API (no replay fields and no deletion by the
sender); a stateless Worker writing to R2 with a lifecycle rule (no idempotency or per-install caps); client-side
encryption of the exact fields to a maintainer key (worth revisiting if exact locations get common); an OHTTP relay so
Cloudflare never sees client IPs (out of proportion at this volume).

## 11. Alpha: reports by share sheet, and the usage log

The backend is not deployed, so the app calls nothing and mints no IDs. `Core/ProblemReport.swift` is a small report
built on the 2.4 pieces that fit (`Report.Spoken`, `App`, `Device`, `Chosen`, `ReportCell`, five-decimal points): one
free-form note, no category, and the screen, mode, extra-time limit, both routes' estimates and streets, the recent spoken
lines, app and data version and device. Exact locations are off by default; with them off the file has the snapped corner
of the start and destination and a 550 m cell for a marked moment, as in 2.2. "What's included" shows the file's text.

- **Open** by shaking the phone, or "Report a problem" in About and Route details. `App/Reports/` holds the screens.
- **Send** is a share sheet with one `peoplemaps-<date>-<words>.json` file; the owner saves it to iCloud Drive,
  `PeopleMaps Reports`. Reports (up to 50) stay on the phone until swiped away in About, where they can be shared again.
- **Guidance**: the flag button saves the moment (time, step in the plan, spoken lines, position) with a light
  confirmation and no sheet. After the trip, or from the About list, the user adds words and shares.
- **Usage log** (`Core/UsageLog.swift`): off by default, a toggle in About. When on, one JSON line per trip in
  `usage-log.jsonl`: date and time, mode, extra-time limit, which route was started, both estimates, whether a calmer
  route was offered, reroute count, each point the user left the route (rounded to about 100 m unless "Exact places in the
  log" is on) and whether the trip arrived or ended early. The last 500 trips are kept. It is shared or cleared from About
  and has no network code. A trip the app is killed during is not logged.
- **Detailed log** (`Core/DriveLog.swift`, `App/Reports/DriveLogger.swift`): for the owner's own use of a build on their own
  phone, to answer where a drive waits (for example at a left turn because the street it turns onto is backed up), how real
  speeds compare with the estimates, and how the app is used. Off by default; the "Keep a detailed log" switch in About is
  separate from the usage log. With it off nothing is recorded or held in memory and guidance runs as before. Nothing
  touches the network. Trips record the fixes guidance already receives; only a manual recording (below) asks for more, and
  only for the `location` background mode, with the same When-In-Use permission. It holds exact places, so it is meant for
  a private build and is not part of what a report contains.
  - **Folder** `drive-log.d` in Application Support (a separate `-uitests` copy under `--ui-testing`), excluded from
    backup. About shows the trip count and size, shares every file, and clears them after a confirmation.
  - **One file per guided trip**, `trip-<UTC time>-<mode>.jsonl` (walk, cycle or drive), JSON lines written as they happen,
    so a crash keeps what was captured. A killed trip has no `end` line, and is kept even if short.
    - `header`: start time, mode, app version and build, data version, the request (start and destination names and
      coordinates, snapped points, extra-time budget, the Calmer means options that are not Normal), which route guidance
      started with, whether a calmer route was offered, and both routes in full: edge IDs and OSM way IDs, street names,
      coordinates, metres and estimated seconds per edge (and the junction time the edges leave out), maneuvers with their
      places, the stress breakdown by factor (amount, cost), stress, and calm score and level.
    - `fix`: one per location fix guidance received: time, latitude, longitude, horizontal accuracy, speed and its
      accuracy, course and its accuracy. **Altitude is not recorded**: Ferrostar's fix has none and guidance asks for none.
    - `event`, with a name and values: `device` (thermal state and low power, at the start and when either changes),
      `maneuver` (step reached, with the instruction), `off_route` (metres, whether it started a reroute), `reroute` (the
      new route in full), `spoken` (the line the voice was given, and whether muted), `mute`, `overview`, `background`,
      `foreground`, `arrived`, `start_failed` and `end` (reason, length, fix count). Long stops are not detected live; the
      report script finds them from the fixes.
    - **Length rule**: a trip that ends in under `DriveLog.minimumTripSeconds` (3 minutes) is deleted when it ends. Route
      switching does not happen in guidance, so it is logged only in app use (`route_selected`).
  - **Manual recording** (`App/Reports/ManualRecorder.swift`), for the owner's phone: record GPS with no route running.
    Only offered while "Keep a detailed log" is on (turning the switch off stops a recording). Start is the record glyph
    (`record.circle`) in the map-button capsule on Home, or "Start recording" under the switch in About; both show the
    same state. While recording, a compact glass pill (red dot, elapsed time, Stop) sits top leading on Home, preview and
    guidance (left of the map buttons in landscape). It uses the existing When-In-Use permission flow, never Always.
    - **Background**: the recorder has its own `CLLocationManager` (best accuracy, no distance filter, `.otherNavigation`,
      no automatic pausing, `allowsBackgroundLocationUpdates`, `showsBackgroundLocationIndicator`) and `App/Info.plist`
      declares `UIBackgroundModes: location`. A recording started in the foreground keeps writing fixes after the app is
      in the background, with iOS's blue location indicator showing, until the user stops it. If guidance starts too, both
      write their own fixes; nothing is deduplicated. It cannot be started from the background and is not resumed.
    - **File** `rec-<UTC start>.jsonl` in `drive-log.d`: `header` (start, app version and build, data version,
      `"recording": "manual"`, no route), `event start`, `fix` lines as for trips (no altitude), and events `background`,
      `foreground`, `device`, `authorization` (status, at the start and when it changes), `location_error`, and `end`
      (`reason`: `user`, `log_off` when the switch is turned off, or `terminated`).
    - **Length rule**: under 3 minutes it is deleted when it stops. The 500 MB cap drops the oldest trips and recordings
      together. About counts recordings next to trips ("2 trips, 1 recording, 4 MB kept"), shares and clears them with the rest.
    - **Killed mid-recording**: the open file's name is kept in `UserDefaults` (`manualRecordingOpenFile`). On the next
      launch the file gets an `end` line with reason `terminated` at the time of its last line (and is deleted if that is
      under 3 minutes). Recording never restarts by itself.
    - **Tests**: `DriveLogTests` (format, 3-minute rule, terminated close, cap), `ReportsUITests` (control follows the switch,
      start and stop write a file; a DEBUG recorder emits one simulated fix a second at the `--location-granted` spot, and
      `--drive-log-keep-short` keeps short ones). Background behaviour and the blue indicator need a phone.
  - **One file per day for app use**, `use-<local date>.jsonl`, same switch: `search_opened`, `search_pick` (query text,
    chosen result and its rank), `search_abandoned` (query text), `place_card`, `preview` (destination, mode, extra-time
    budget), `route_ready` (milliseconds the comparison took), `route_selected`, `mode_changed`, `budget_changed`,
    `sheet_opened` (details, Calmer means and so on), `preview_abandoned` (left without Start), `navigation_started`
    and `report_opened`. The hooks are one view modifier (`DriveLogHooks.swift`) and a few single lines that call
    `DriveLogger`; removing the feature means deleting those calls and that type.
  - **Size**: a one-hour drive at one fix a second is about 0.6 MB (`DriveLogTests`). A cap of 500 MB for the whole folder
    (`DriveLog.capBytes`) drops the oldest trips and recordings first, never the one being written.
  - **Reading it**: `python3 Scripts/drive_log_report.py FOLDER` on a Mac, standard library only. For each trip it compares
    time on each edge with the estimate and lists each stop of 20 seconds or more (place, length, next maneuver, whether it
    is a left, road names); then it groups stops by junction across trips, longest first. Real logs never go in the
    repository, Evidence or tests; `Scripts/test_drive_log_report.py` uses a made-up track. `rec-*` files are read like
    trips for totals and stops. They have no route, so there is no edge-time comparison, no road name or next maneuver, and
    no "before a left" flag: the script does not look at the road graph. Their stops are grouped by place with the trips'.
- **Recent app events** (`Core/AppEvents.swift`, schema 3): a short list under `events` in the report file, so a report says
  what the app was doing and not only where the phone was. The buffer lives in memory, keeps the last 200 events or the
  last 10 minutes, whichever is fewer, and is never written to disk. A report copies it when it is created or a moment
  is marked; the copy is saved with the report and shown in "What's included". Reports saved before schema 3 have no
  `events` and still open. A crash, a quit or the system ending the app loses the buffer, and the app collects no crash
  data, so a report made after a crash cannot say what led to it.
  - Each event is a time (to the millisecond), a category (`route`, `navigation`, `map`, `search`, `data`, `error`), a short
    fixed message, an optional `detail` (an error's type name, a travel mode or a state name) and numbers under a fixed set
    of names: `ms`, `count`, `candidates`, `results`, `zoom`, `animated`, `reroutes`, `steps`, `level`, rounded to one decimal.
  - **Never in an event**: coordinates, street or place names, search text, notes, error messages. The message must be a
    string literal (the type is `StaticString`), so text a person typed cannot be passed in, and any other number name is
    dropped. `Tests/AppEventsTests.swift` checks this.
  - Logged: route comparison start, finish (milliseconds and candidate routes), cancel and failure; guidance start, reroute,
    arrival and stop; launch steps (graph header, search index and router load times); map style loaded, map idle, and each
    programmatic camera move with its duration and whether it animated; memory warnings; each search with its time and result
    count; and a report file that cannot be read. Events come only from the app's own code, never from the system log,
    MapLibre or Ferrostar, whose logs may contain coordinates. Repeats of the same event within two seconds (camera
    moves while following, redraws) share one line with a `count`, so a long drive does not push out the rest.
