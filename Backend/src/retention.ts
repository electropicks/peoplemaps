import type { Deps } from "./deps";
import type { RetentionCounts } from "./store";
import { addDays, iso } from "./time";

/** The cron job of Docs/REPORTS.md 5.3: expired reports, installs idle for a year with no reports, attested keys older than
 * `RETENTION_DAYS`, and sent logs past their `LOG_RETENTION_DAYS` (4.8), file first, then the row that lists it. */
export async function retention(deps: Deps): Promise<RetentionCounts> {
  const now = deps.clock.now();
  const counts = await deps.store.retain(iso(now), iso(addDays(now, -365)), iso(addDays(now, -deps.vars.retentionDays)));
  const keys = await deps.store.expiredLogKeys(iso(now));
  if (keys.length > 0) {
    await deps.logs.delete(keys);
    counts.logs = await deps.store.deleteLogUploads(keys);
  }
  console.log("retention rows deleted", counts.reports + counts.installs + counts.keys + counts.logs);
  return counts;
}
