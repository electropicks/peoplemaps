# Reports backend

The Cloudflare Worker and D1 database behind in-app problem reports. The design, API and data rules are in
`Docs/REPORTS.md` (sections 4 to 7); what users are told is in `Docs/PRIVACY.md`. Change them together.

## Layout

- `src/index.ts` is the only Cloudflare-specific entry: it builds `Deps` from `env`, routes requests and runs the cron.
  `src/store-d1.ts` is the D1 shim. Every other module is a plain function over `Deps` (`src/deps.ts`).
- `migrations/000N_name.sql`: never edited once applied to the deployed database; a change is a new file.
- `scripts/file-issue.ts`: the hand-filing tool. `src/issue.ts` is pure and only this script imports it, so the Worker has
  no GitHub code and needs no secret.
- `test/`: vitest under node, against `test/store-sqlite.ts` (node's built-in SQLite, in memory, migrations applied).
- `test/fixtures/parity/`: a report in, the public body and exact part out. `Tests/ReportsTests.swift` reads the same
  files, so `splitExact` and `Core/Reports.swift` drop exactly the same fields.

## Test

```sh
cd Backend
npm ci
npm test            # vitest under node 22.13+; no account, no login, no network
npx tsc --noEmit
```

CI runs both in the `backend` job of `.github/workflows/ci.yml`.

## Run locally

```sh
npx wrangler d1 migrations apply peoplemaps-reports --local
npm run dev         # wrangler dev on 0.0.0.0:8787, local D1
```

Put `REPORTS_PER_DAY=50` in `.dev.vars` (gitignored) if a tester needs a higher cap.

## Deploy

`.github/workflows/backend.yml` runs on a push to `main` that touches `Backend/`: tests, then `wrangler d1 migrations
apply --remote` and `wrangler deploy` in the `deploy` job. Deploys run automatically from `main` once the tests pass, with
no approval step, and can also be started by hand with `gh workflow run backend.yml --ref main`. A pull request never
deploys. The job is skipped until the repository variable `BACKEND_DEPLOY` is `true`.

The database already exists, pinned to the US (`Docs/REPORTS.md` question 25), and the account's `workers.dev` subdomain is
`peoplemaps`, so the Worker's URL is `https://peoplemaps-reports.peoplemaps.workers.dev`, the Release base URL
(`Docs/REPORTS.md` 7.5). Once a build ships, neither the subdomain nor the Worker's name may be renamed: either changes the
URL it calls.

Once, by hand, in this order, for the first deploy:

1. On Cloudflare's Account API Tokens page, create an account-owned token with Workers: Editor and D1: Edit. Add it as
   `CLOUDFLARE_API_TOKEN`, with `CLOUDFLARE_ACCOUNT_ID`, to the GitHub Environment `production`, which has no reviewers and
   deploys only from `main`. Not repository secrets. "Workers Scripts: Edit" is the legacy name for Editor
   ([Workers roles](https://developers.cloudflare.com/workers/authorization/workers/)).
2. Editor can't create a Worker, so run the first remote migration and deploy from the owner's logged-in Mac, on `main` after
   the reports stack has merged:

   ```sh
   cd Backend
   npm ci              # so npx uses the pinned wrangler
   npx wrangler d1 migrations apply peoplemaps-reports --remote
   npx wrangler deploy
   ```

3. Now that the Worker exists, narrow the token's Workers scope to `peoplemaps-reports`.
4. Last, set the repository variable (not an environment variable, which a job's `if` cannot see): `gh variable set
   BACKEND_DEPLOY --body true`. From then on CI deploys.
5. Before the privacy policy is published, send the deployed Worker some requests and read what Workers Logs and the
   dashboard record (4.6).

## Region downloads: secret and vars

`GET /v1/regions/…` serves the private R2 bucket `peoplemaps-data` (binding `DATA`) to copies of the app that passed App
Attest (`Docs/REPORTS.md` 4.5 and 4.7). It needs two secrets and one var. Until both `APP_ID` and
`DOWNLOAD_TOKEN_SECRET` are set, the attest routes answer 500 and every download 401; the reports API is unaffected.

- `DOWNLOAD_TOKEN_SECRET` (secret): the HMAC key for download tokens, at least 32 characters. The owner sets it once,
  never in a file or a var: `openssl rand -base64 48 | npx wrangler secret put DOWNLOAD_TOKEN_SECRET`. Changing it
  revokes every token, and the app attests again.
- `APP_ID` (secret): `<team id>.<bundle id>` of the app, as App Attest hashes it into `rpIdHash`. It holds the team ID,
  which is never committed, so it is a secret and not a var: `npx wrangler secret put APP_ID`, which prompts for the value.
- `ATTEST_ENV` (var): `production`, and a test keeps it so. Only a local `.dev.vars` may say `development`, which also
  accepts keys from development-signed builds (`appattestdevelop`).

The bucket must exist before a deploy with the `DATA` binding. Migration `0002_attest.sql` is applied by the deploy job
like any other. Not yet exercised: a real attestation from Apple's chain, real R2, and a deployed Worker.

## Reading reports and filing an issue

Reports stay in D1. Nothing reaches GitHub unless a maintainer files it (`Docs/REPORTS.md` 6). Exact locations are in
`exact_json`; do not copy them anywhere.

```sh
npx wrangler d1 execute peoplemaps-reports --remote --command "SELECT id, received_at, category, json_extract(public_json, '$.note') AS note FROM reports ORDER BY received_at DESC LIMIT 20"
npm run file-issue -- <report-id>            # prints the title, labels and body; read it first
npm run file-issue -- <report-id> --create   # files it with gh
```

The first time, create the labels: `app-report`, `report:<category>` and `mode:<mode>`, with `gh label create`.
