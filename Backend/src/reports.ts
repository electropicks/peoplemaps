import type { Deps } from "./deps";
import { HttpError, json } from "./errors";
import { GitHubError } from "./github";
import { appVersion, authenticate, deleteIssueOrFail, sha256Hex } from "./installs";
import { issueFor } from "./issue";
import { limitByIP } from "./ratelimit";
import type { IssueState, NewReport, ReportRow } from "./store";
import { addDays, dayStart, hour, isoWeek } from "./time";
import { canonical, readJSON, splitExact, validate, type PublicReport } from "./validate";

// POST, GET, DELETE /v1/reports (Docs/REPORTS.md 4.2 to 4.4) and filing an approved report's issue (6).

export const MAX_ISSUE_ATTEMPTS = 10;

/** The 4.2 response shape. */
export function receipt(r: ReportRow) {
  return {
    id: r.id,
    receivedAt: r.received_at,
    issue: r.issue_number !== null && r.issue_url !== null ? { number: r.issue_number, url: r.issue_url } : null,
    issueState: r.issue_state,
    expiresAt: r.expires_at,
  };
}

export async function sendReport(request: Request, deps: Deps): Promise<Response> {
  const install = await authenticate(request, deps);
  await limitByIP(request, deps.limits.reports);
  const report = validate(await readJSON(request));
  const bodyHash = await sha256Hex(canonical(report));

  const existing = await deps.store.reportById(report.id);
  if (existing) return retry(existing, install.id, bodyHash);

  const now = deps.clock.now();
  if ((await deps.store.countReportsSince(install.id, hour(addDays(now, -1)))) >= deps.vars.reportsPerDay) {
    throw new HttpError("rate_limited", "Too many reports today.", undefined, 3600);
  }

  const { public: pub, exact } = splitExact(report);
  const received = hour(now);
  const row: NewReport = {
    id: report.id,
    install_id: install.id,
    received_at: received,
    expires_at: hour(addDays(new Date(received), deps.vars.retentionDays)),
    body_hash: bodyHash,
    category: report.category,
    mode: report.request.mode,
    data_version: report.route.dataVersion,
    app_version: appVersion(report.app),
    cell: report.position.cell,
    public_json: JSON.stringify(pub),
    exact_json: exact ? JSON.stringify(exact) : null,
    issue_state: deps.vars.holdForApproval ? "held" : "pending",
  };
  try {
    await deps.store.insertReport(row, isoWeek(now));
  } catch (e) {
    // A concurrent send of the same id got there first: answer as a retry.
    const raced = await deps.store.reportById(report.id).catch(() => null);
    if (raced) return retry(raced, install.id, bodyHash);
    throw e;
  }
  if (deps.vars.holdForApproval) return json(202, receipt((await deps.store.reportById(row.id))!));

  const state = await fileIssue(row.id, deps);
  const stored = (await deps.store.reportById(row.id))!;
  return json(state === "opened" ? 201 : 202, receipt(stored));
}

function retry(existing: ReportRow, installID: string, bodyHash: string): Response {
  if (existing.install_id !== installID || existing.body_hash !== bodyHash) {
    throw new HttpError("conflict", `Report ${existing.id} was already sent with different content.`);
  }
  return json(200, receipt(existing));
}

export async function listReports(request: Request, deps: Deps): Promise<Response> {
  const install = await authenticate(request, deps);
  const rows = await deps.store.reportsByInstall(install.id);
  return json(200, { reports: rows.map((r) => ({ ...receipt(r), category: r.category })) });
}

async function ownReport(request: Request, deps: Deps, id: string): Promise<ReportRow> {
  const install = await authenticate(request, deps);
  const row = await deps.store.reportById(id);
  if (!row || row.install_id !== install.id) throw new HttpError("not_found", "No such report.");
  return row;
}

export async function getReport(request: Request, deps: Deps, id: string): Promise<Response> {
  const row = await ownReport(request, deps, id);
  return json(200, { ...receipt(row), category: row.category });
}

/** The issue first; if GitHub fails the row stays and the answer is 503 (4.4). */
export async function deleteReport(request: Request, deps: Deps, id: string): Promise<Response> {
  const row = await ownReport(request, deps, id);
  if (row.issue_node_id) await deleteIssueOrFail(deps, row.issue_node_id);
  await deps.store.deleteReport(row.id);
  return json(204, null);
}

/**
 * Files the issue of a `pending` row within the daily cap (4.6). Over the cap it stays `pending` without counting an
 * attempt; a GitHub failure counts one, and the tenth makes it `failed` (5.3). Returns the row's state afterwards.
 */
export async function fileIssue(id: string, deps: Deps): Promise<IssueState | "capped"> {
  const row = await deps.store.reportById(id);
  if (!row || row.issue_state !== "pending") return row?.issue_state ?? "failed";
  const now = deps.clock.now();
  if ((await deps.store.countFiledSince(dayStart(now))) >= deps.vars.issueDailyCap) return "capped";
  try {
    const issue = await deps.github.createIssue(issueFor(JSON.parse(row.public_json) as PublicReport));
    await deps.store.markFiled(row.id, issue, hour(now));
    return "opened";
  } catch (e) {
    if (!(e instanceof GitHubError)) throw e;
    await deps.store.markIssueFailure(row.id, e.message.slice(0, 200), MAX_ISSUE_ATTEMPTS);
    return row.issue_attempts + 1 >= MAX_ISSUE_ATTEMPTS ? "failed" : "pending";
  }
}
