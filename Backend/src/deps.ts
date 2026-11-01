import type { Store } from "./store";
import type { GitHub } from "./github";

/** A Workers rate-limiting binding, or a test fake with the same shape (4.6). */
export interface RateLimiter { limit(options: { key: string }): Promise<{ success: boolean }> }
export interface Limits { auth: RateLimiter; installs: RateLimiter; reports: RateLimiter }
export interface Clock { now(): Date }

export interface Vars {
  githubRepo: string;
  retentionDays: number;
  reportsPerDay: number;
  issueDailyCap: number;
  installsPerHour: number;
  holdForApproval: boolean;
}

/** Everything a handler needs. Handlers never see `env` or anything from Cloudflare (7.1). */
export interface Deps { store: Store; github: GitHub; limits: Limits; clock: Clock; vars: Vars }

export function parseVars(env: Record<string, unknown>): Vars {
  const n = (k: string, fallback: number) => {
    const v = Number(env[k]);
    return Number.isFinite(v) && v >= 0 ? v : fallback;
  };
  return {
    githubRepo: typeof env.GITHUB_REPO === "string" ? env.GITHUB_REPO : "electropicks/peoplemaps",
    retentionDays: n("RETENTION_DAYS", 90),
    reportsPerDay: n("REPORTS_PER_DAY", 20),
    issueDailyCap: n("ISSUE_DAILY_CAP", 200),
    installsPerHour: n("INSTALLS_PER_HOUR", 60),
    holdForApproval: env.HOLD_FOR_APPROVAL !== "false",
  };
}
