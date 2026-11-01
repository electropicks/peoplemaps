# Reports backend

The Cloudflare Worker and D1 database behind in-app problem reports. The design, API and data rules are in
`Docs/REPORTS.md` (sections 4 to 7); what users are told is in `Docs/PRIVACY.md`. Change them together.

## Layout

- `src/index.ts` is the only Cloudflare-specific entry: it builds `Deps` from `env`, routes requests and runs the crons.
  `src/store-d1.ts` is the D1 shim. Every other module is a plain function over `Deps` (`src/deps.ts`).
- `migrations/000N_name.sql`: never edited after they ship; a change is a new file.
- `test/`: vitest under node, against `test/store-sqlite.ts` (node's built-in SQLite, in memory, migrations applied)
  and `test/github.mock.ts` (a `fetch` mock that records each GitHub request).
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
npm run dev         # wrangler dev --env dev on 0.0.0.0:8787, local D1
npx wrangler d1 migrations apply peoplemaps-reports --local
```

The dev environment has `HOLD_FOR_APPROVAL` off and 50 reports per install per day. Put `GITHUB_TOKEN=…` in
`.dev.vars` (gitignored) to file issues; without it reports are stored and answered `202` with the issue pending.
The approval page is `/maintainer`.

## Deploy

`.github/workflows/backend.yml` runs on a push to `main` that touches `Backend/`: tests, then `wrangler d1 migrations
apply --remote` and `wrangler deploy` in the `deploy` job, which waits for approval on the GitHub Environment
`production`. Never from a pull request.

Once, by hand, before the first deploy:

1. `npx wrangler d1 create peoplemaps-reports --location wnam`, and commit the database ID in `wrangler.jsonc`.
2. Put the real domain in `routes` (`reports.<our domain>`) and add the zone to the account.
3. Create the GitHub Environment `production` with the maintainer as required reviewer, holding
   `CLOUDFLARE_API_TOKEN` (Workers Scripts: Edit, D1: Edit) and `CLOUDFLARE_ACCOUNT_ID`. Not repository secrets.
4. `npx wrangler secret put GITHUB_TOKEN` from the maintainer's machine, never through Actions: a fine-grained token
   made by a repository admin, this repository only, Issues read and write, Metadata read, Administration read and
   write (for `deleteIssue`). If a scratch-repository test shows `deleteIssue` works without Administration, drop it
   and record the final scope here.
5. The checks `Docs/REPORTS.md` asks for before release: deploy a throwaway Worker with the same `observability`
   block and read what Workers Logs records (4.6); send mints from several regions to see how approximate
   `RL_INSTALLS` is (4.6, `MintGate` if it lets clearly more through); confirm the wording of D1's daily-limit error
   matches `LIMIT_ERROR` in `src/store-d1.ts`; check whether the zone's plan offers hourly WAF rate limits.

## Looking at the data

Rows that failed ten times are `issue_state = 'failed'`:

```sh
npx wrangler d1 execute peoplemaps-reports --remote --command "SELECT id, received_at, issue_error FROM reports WHERE issue_state = 'failed'"
```
