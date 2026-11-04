import type { Deps, RateLimiter } from "./deps";
import { HttpError } from "./errors";
import { hour, secondsToNextHour } from "./time";

// The edge limits and the mint ceiling of Docs/REPORTS.md 4.6. The only module that reads cf-connecting-ip: the key
// goes straight to the binding and is never hashed, stored, logged or kept past the call.

const limited = (retryAfter: number) => new HttpError("rate_limited", "Too many requests. Try again later.", undefined, retryAfter);

async function check(limiter: RateLimiter, key: string): Promise<void> {
  if (!(await limiter.limit({ key })).success) throw limited(60);
}

/** An IPv4 address as is; an IPv6 address as its /64, since one home or phone usually holds a whole /64. */
export function ipKey(ip: string): string {
  if (!ip.includes(":")) return ip;
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(ip);
  if (mapped) return mapped[1];
  const [head, tail] = ip.toLowerCase().split("::");
  const left = head ? head.split(":") : [], right = tail ? tail.split(":") : [];
  const groups = tail === undefined ? left : [...left, ...Array(8 - left.length - right.length).fill("0"), ...right];
  return groups.slice(0, 4).map((g) => g.replace(/^0+(?=.)/, "")).join(":") + "::/64";
}

/** `RL_INSTALLS`, `RL_REPORTS` or `RL_ATTEST`, keyed on the client IP or its /64. */
export function limitByIP(request: Request, limiter: RateLimiter): Promise<void> {
  return check(limiter, ipKey(request.headers.get("cf-connecting-ip") ?? "local"));
}

/** `RL_AUTH`, keyed on the token hash, for every authenticated route. */
export function limitAuth(deps: Deps, tokenHash: string): Promise<void> {
  return check(deps.limits.auth, tokenHash);
}

/** `RL_DOWNLOADS`, keyed on the App Attest key ID the download token was issued for (4.7). */
export function limitDownloads(deps: Deps, keyId: string): Promise<void> {
  return check(deps.limits.downloads, keyId);
}

/** `INSTALLS_PER_HOUR`, counted from `installs.created_at` in the current hour. */
export async function mintCeiling(deps: Deps): Promise<void> {
  const now = deps.clock.now();
  if ((await deps.store.countInstallsSince(hour(now))) >= deps.vars.installsPerHour) throw limited(secondsToNextHour(now));
}
