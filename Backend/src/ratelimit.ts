import type { Deps, RateLimiter } from "./deps";
import { HttpError } from "./errors";
import { hour, secondsToNextHour } from "./time";

// The edge limits and the mint ceiling of Docs/REPORTS.md 4.6. The only module that reads cf-connecting-ip: the value
// goes straight to the binding and is never hashed, stored, logged or kept past the call.

const limited = (retryAfter: number) => new HttpError("rate_limited", "Too many requests. Try again later.", undefined, retryAfter);

async function check(limiter: RateLimiter, key: string): Promise<void> {
  if (!(await limiter.limit({ key })).success) throw limited(60);
}

/** `RL_INSTALLS` or `RL_REPORTS`, keyed on the bare client IP. */
export function limitByIP(request: Request, limiter: RateLimiter): Promise<void> {
  return check(limiter, request.headers.get("cf-connecting-ip") ?? "local");
}

/** `RL_AUTH`, keyed on the token hash, for every authenticated route. */
export function limitAuth(deps: Deps, tokenHash: string): Promise<void> {
  return check(deps.limits.auth, tokenHash);
}

/** `INSTALLS_PER_HOUR`, counted from `installs.created_at` in the current hour. */
export async function mintCeiling(deps: Deps): Promise<void> {
  const now = deps.clock.now();
  if ((await deps.store.countInstallsSince(hour(now))) >= deps.vars.installsPerHour) throw limited(secondsToNextHour(now));
}
