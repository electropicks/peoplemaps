import type { Deps } from "./deps";
import { fileIssue, MAX_ISSUE_ATTEMPTS } from "./reports";
import type { RetentionCounts } from "./store";
import { addDays, iso } from "./time";

// The two cron jobs of Docs/REPORTS.md 5.3.

export const RETENTION_CRON = "17 3 * * *";
export const RETRY_CRON = "7 * * * *";
const RETRY_BATCH = 20;

/** Expired reports, installs idle for a year with no reports, maintainer reads older than 90 days. */
export async function retention(deps: Deps): Promise<RetentionCounts> {
  const now = deps.clock.now();
  const counts = await deps.store.retain(iso(now), iso(addDays(now, -365)), iso(addDays(now, -90)));
  console.log("retention rows deleted", counts.reports + counts.installs + counts.maintainerReads);
  return counts;
}

/** Files up to 20 `pending` issues, oldest first, stopping at the daily cap. Never touches `held` rows. */
export async function retryIssues(deps: Deps): Promise<{ opened: number; pending: number; failed: number }> {
  const out = { opened: 0, pending: 0, failed: 0 };
  for (const row of await deps.store.pendingReports(RETRY_BATCH, MAX_ISSUE_ATTEMPTS)) {
    const state = await fileIssue(row.id, deps);
    if (state === "capped") { out.pending++; break; }
    if (state === "opened") out.opened++;
    else if (state === "failed") out.failed++;
    else out.pending++;
  }
  console.log("issue retry opened", out.opened);
  return out;
}
