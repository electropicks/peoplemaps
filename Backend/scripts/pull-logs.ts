#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, unlinkSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// Copies the trip logs sent from the app (Docs/REPORTS.md 4.8) to this Mac, checks each against its SHA-256, opens it with the
// log key in this Mac's Keychain (`peoplemaps-logkey`), then deletes it from the server. Runs with the owner's wrangler login;
// never deployed. Real logs never go in the repository.
//   npm run pull-logs -- [--list] [--keep] [--to DIR] [--local]
//   --list  only lists what is on the server
//   --keep  copies without deleting from the server
//   --to    where to save (default ~/atrium/peoplemaps/logs), one folder per send: <received hour>-<batch>/<name>

const args = process.argv.slice(2);
const flag = (f: string) => args.includes(f);
const to = args.includes("--to") ? args[args.indexOf("--to") + 1] : join(homedir(), "atrium", "peoplemaps", "logs");
const where = flag("--local") ? "--local" : "--remote";
const BATCH = /^[0-9a-f-]{36}$/, NAME = /^[A-Za-z0-9.-]+\.jsonl\.enc$/;
const repo = join(import.meta.dirname, "..", "..");

const wrangler = (...a: string[]) => execFileSync("npx", ["wrangler", ...a], { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] });
const d1 = (command: string) =>
  (JSON.parse(wrangler("d1", "execute", "peoplemaps-reports", where, "--json", "--command", command)) as { results: Row[] }[])[0].results;

interface Row { key: string; batch: string; name: string; bytes: number; sha256: string; received_at: string; expires_at: string }
const rows = d1("SELECT key, batch, name, bytes, sha256, received_at, expires_at FROM log_uploads ORDER BY received_at, key");
if (rows.length === 0) {
  console.log("No logs on the server.");
  process.exit(0);
}
for (const r of rows) console.log(`${r.received_at}  ${String(r.bytes).padStart(10)}  ${r.key}`);
if (flag("--list")) process.exit(0);

execFileSync("swift", ["build", "-c", "release", "--package-path", repo, "--product", "peoplemaps-logkey"], { stdio: ["ignore", "ignore", "inherit"] });
const logkey = join(repo, ".build", "release", "peoplemaps-logkey");

let bad = 0;
for (const r of rows) {
  if (!BATCH.test(r.batch) || !NAME.test(r.name) || r.key !== `${r.batch}/${r.name}`) { console.error(`skipped odd key ${r.key}`); bad++; continue; }
  const folder = join(to, `${r.received_at.slice(0, 13).replace(/[-:T]/g, "")}-${r.batch}`);
  mkdirSync(folder, { recursive: true });
  const plainName = r.name.slice(0, -".enc".length), sealed = join(folder, r.name);
  wrangler("r2", "object", "get", `peoplemaps-logs/${r.key}`, where, "--file", sealed);
  if (createHash("sha256").update(readFileSync(sealed)).digest("hex") !== r.sha256) { console.error(`hash mismatch, kept on server: ${r.key}`); bad++; continue; }
  try {
    execFileSync(logkey, ["open", sealed, join(folder, plainName), plainName], { stdio: ["ignore", "inherit", "inherit"] });
  } catch {
    console.error(`could not open, kept on server: ${r.key}`); bad++; continue;
  }
  unlinkSync(sealed);
  if (!flag("--keep")) {
    wrangler("r2", "object", "delete", `peoplemaps-logs/${r.key}`, where);
    d1(`DELETE FROM log_uploads WHERE key = '${r.key}'`);
  }
}
console.log(`${rows.length - bad} saved to ${to}${flag("--keep") ? "" : " and deleted from the server"}.`);
process.exit(bad ? 1 : 0);
