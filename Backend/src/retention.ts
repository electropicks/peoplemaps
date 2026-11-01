import type { Deps } from "./deps";
import type { RetentionCounts } from "./store";
import { addDays, iso } from "./time";

/** The cron job of Docs/REPORTS.md 5.3: expired reports, and installs idle for a year with no reports. */
export async function retention(deps: Deps): Promise<RetentionCounts> {
  const now = deps.clock.now();
  const counts = await deps.store.retain(iso(now), iso(addDays(now, -365)));
  console.log("retention rows deleted", counts.reports + counts.installs);
  return counts;
}
