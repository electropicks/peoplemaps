import type { Deps } from "./deps";
import { HttpError, json } from "./errors";
import { appVersion, authenticate, sha256Hex } from "./installs";
import { limitByIP } from "./ratelimit";
import type { ReportRow } from "./store";
import { addDays, hour, isoWeek } from "./time";
import { canonical, readJSON, splitExact, validate } from "./validate";

// POST, GET, DELETE /v1/reports (Docs/REPORTS.md 4.2 to 4.4).

/** The 4.2 response shape. */
export function receipt(r: ReportRow) {
  return { id: r.id, receivedAt: r.received_at, expiresAt: r.expires_at };
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
  const row: ReportRow = {
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
  };
  try {
    await deps.store.insertReport(row, isoWeek(now));
  } catch (e) {
    // A concurrent send of the same id got there first: answer as a retry.
    const raced = await deps.store.reportById(report.id).catch(() => null);
    if (raced) return retry(raced, install.id, bodyHash);
    throw e;
  }
  return json(201, receipt(row));
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

export async function deleteReport(request: Request, deps: Deps, id: string): Promise<Response> {
  const row = await ownReport(request, deps, id);
  await deps.store.deleteReport(row.id);
  return json(204, null);
}
