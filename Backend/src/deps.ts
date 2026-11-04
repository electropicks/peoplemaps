import type { Store } from "./store";

/** A Workers rate-limiting binding, or a test fake with the same shape (4.6). */
export interface RateLimiter { limit(options: { key: string }): Promise<{ success: boolean }> }
export interface Limits { auth: RateLimiter; installs: RateLimiter; reports: RateLimiter; attest: RateLimiter; downloads: RateLimiter }
export interface Clock { now(): Date }

export interface Vars {
  retentionDays: number;
  reportsPerDay: number;
  installsPerHour: number;
  attestsPerHour: number;
}

/** What the download route needs from an R2 bucket (4.7); the R2 binding and the test stub both fit. */
export interface BucketObject { size: number; httpEtag: string; uploaded: Date; writeHttpMetadata(headers: Headers): void }
export interface BucketObjectBody extends BucketObject { body: ReadableStream }
export interface Bucket {
  head(key: string): Promise<BucketObject | null>;
  /** Without `body` when an `onlyIf` condition failed. */
  get(key: string, options: { range?: { offset: number; length: number }; onlyIf?: Headers }): Promise<BucketObjectBody | BucketObject | null>;
}

/** App Attest and the download token (4.5, 4.7). Empty strings mean not set up, and those routes answer 500. */
export interface AttestConfig {
  /** `<team id>.<bundle id>`, from the `APP_ID` secret; the team ID is never committed. */
  appId: string;
  /** True only when the `ATTEST_ENV` var is `development`: then `appattestdevelop` keys are accepted too. */
  allowDevelopment: boolean;
  /** The PEM of the root the chain must reach: Apple's in production, a synthetic one in tests. */
  rootPEM: string;
  /** The `DOWNLOAD_TOKEN_SECRET` secret, the download token's HMAC key. */
  tokenSecret: string;
}

/** Everything a handler needs. Handlers never see `env` or anything from Cloudflare (7.1). */
export interface Deps { store: Store; limits: Limits; clock: Clock; vars: Vars; data: Bucket; attest: AttestConfig }

export function parseVars(env: Record<string, unknown>): Vars {
  const n = (k: string, fallback: number) => {
    const v = Number(env[k]);
    return Number.isFinite(v) && v >= 0 ? v : fallback;
  };
  return {
    retentionDays: n("RETENTION_DAYS", 90),
    reportsPerDay: n("REPORTS_PER_DAY", 5),
    installsPerHour: n("INSTALLS_PER_HOUR", 60),
    attestsPerHour: n("ATTESTS_PER_HOUR", 60),
  };
}
