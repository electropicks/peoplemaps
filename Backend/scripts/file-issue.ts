#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { issueFor } from "../src/issue.ts";
import type { PublicReport } from "../src/validate";

// Prints the GitHub issue for a stored report, or files it with gh (Docs/REPORTS.md 6). Run by a maintainer, never deployed.
//   npm run file-issue -- <report-id> [--local] [--create]

const args = process.argv.slice(2);
const id = args.find((a) => !a.startsWith("--")) ?? "";
if (!/^[0-9A-Fa-f-]{36}$/.test(id)) {
  console.error("usage: npm run file-issue -- <report-id> [--local] [--create]");
  process.exit(2);
}

const output = execFileSync("npx", [
  "wrangler", "d1", "execute", "peoplemaps-reports", args.includes("--local") ? "--local" : "--remote", "--json",
  "--command", `SELECT public_json FROM reports WHERE id = '${id}'`,
], { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] });
const row = (JSON.parse(output) as { results: { public_json: string }[] }[])[0].results[0];
if (!row) {
  console.error(`No report ${id}.`);
  process.exit(1);
}

const issue = issueFor(JSON.parse(row.public_json) as PublicReport);
if (args.includes("--create")) {
  execFileSync("gh", ["issue", "create", "--title", issue.title, "--body-file", "-", ...issue.labels.flatMap((l) => ["--label", l])], { input: issue.body, stdio: ["pipe", "inherit", "inherit"] });
} else {
  console.log(`${issue.title}\n\nLabels: ${issue.labels.join(", ")}\n\n${issue.body}`);
}
