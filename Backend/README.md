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
apply --remote` and `wrangler deploy` in the `deploy` job, which waits for approval on the GitHub Environment
`production`. Never from a pull request.

Once, by hand, before the first deploy:

1. Set the account's `workers.dev` subdomain once, and never rename the Worker: either changes the URL shipped apps call
   (`https://peoplemaps-reports.<account-subdomain>.workers.dev`). Put that URL in the Release build setting
   (`Docs/REPORTS.md` 7.5).
2. Create the GitHub Environment `production` with the maintainer as required reviewer, holding `CLOUDFLARE_API_TOKEN`
   (Workers Scripts: Edit, D1: Edit) and `CLOUDFLARE_ACCOUNT_ID`. Not repository secrets.
3. Decide where the database lives (`Docs/REPORTS.md` question 25) while it is still empty.
4. Before the privacy policy is published, send the deployed Worker some requests and read what Workers Logs and the
   dashboard record (4.6).

## Reading reports and filing an issue

Reports stay in D1. Nothing reaches GitHub unless a maintainer files it (`Docs/REPORTS.md` 6). Exact locations are in
`exact_json`; do not copy them anywhere.

```sh
npx wrangler d1 execute peoplemaps-reports --remote --command "SELECT id, received_at, category, json_extract(public_json, '$.note') AS note FROM reports ORDER BY received_at DESC LIMIT 20"
npm run file-issue -- <report-id>            # prints the title, labels and body; read it first
npm run file-issue -- <report-id> --create   # files it with gh
```

The first time, create the labels: `app-report`, `report:<category>` and `mode:<mode>`, with `gh label create`.
