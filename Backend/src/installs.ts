import type { Deps } from "./deps";
import { HttpError, invalid, json } from "./errors";
import type { InstallRow } from "./store";
import { limitAuth, limitByIP, mintCeiling } from "./ratelimit";
import { hour } from "./time";
import { readJSON } from "./validate";

// POST /v1/installs, DELETE /v1/installs/me and bearer-token checks (Docs/REPORTS.md 4.1, 4.4).

export async function sha256Hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function base64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export const appVersion = (app: { version: string; build: string }) => `${app.version} (${app.build})`;

export async function mintInstall(request: Request, deps: Deps): Promise<Response> {
  await limitByIP(request, deps.limits.installs);
  await mintCeiling(deps);
  const body = await readJSON(request);
  const b = body as { schema?: unknown; app?: { version?: unknown; build?: unknown } };
  if (typeof body !== "object" || body === null || Array.isArray(body)) throw invalid("body", "Expected an object.");
  if (b.schema !== 1) throw invalid("schema", "Unknown schema.");
  for (const k of ["version", "build"] as const) {
    const v = b.app?.[k];
    if (typeof v !== "string" || [...v].length === 0 || [...v].length > 32) throw invalid(`app.${k}`);
  }
  const token = "pm_" + base64url(crypto.getRandomValues(new Uint8Array(32)));
  const now = hour(deps.clock.now());
  const row: InstallRow = {
    id: crypto.randomUUID(),
    token_hash: await sha256Hex(token),
    app_version: appVersion(b.app as { version: string; build: string }),
    created_at: now,
    last_seen_at: now,
  };
  await deps.store.insertInstall(row);
  return json(201, { installID: row.id, token });
}

/** The install behind `Authorization: Bearer pm_…`, after `RL_AUTH`; 401 when none matches. */
export async function authenticate(request: Request, deps: Deps): Promise<InstallRow> {
  const m = /^Bearer (pm_[A-Za-z0-9_-]{43})$/.exec(request.headers.get("authorization") ?? "");
  if (!m) throw new HttpError("unauthorized", "Missing or malformed report token.");
  const hash = await sha256Hex(m[1]);
  await limitAuth(deps, hash);
  const install = await deps.store.installByTokenHash(hash);
  if (!install) throw new HttpError("unauthorized", "This report ID does not exist on the server.");
  const now = hour(deps.clock.now());
  // Best effort: a refused update must not block reading or deleting (4.6).
  if (install.last_seen_at !== now) await deps.store.touchInstall(install.id, now).catch(() => {});
  return install;
}

/** Every report of the install and the install itself, in one batch (4.4). */
export async function deleteInstall(request: Request, deps: Deps): Promise<Response> {
  const install = await authenticate(request, deps);
  await deps.store.deleteInstall(install.id);
  return json(204, null);
}
