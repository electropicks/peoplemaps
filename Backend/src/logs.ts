import { hex, sha256 } from "./bytes";
import type { Deps } from "./deps";
import { HttpError, json } from "./errors";
import { limitLogs } from "./ratelimit";
import { authorize } from "./regions";
import { addDays, hour, secondsToMidnightUTC } from "./time";

// PUT /v1/logs/{batch}/{name} and DELETE /v1/logs/{batch} (Docs/REPORTS.md 4.8): one trip-log file, sent by a tap in the app,
// from a holder of a download token. The app seals it to the owner's key first (`Core/SealedBox.swift`), so the Worker stores
// bytes it cannot read. They go to the private bucket as they came; D1 gets one row naming them, which the cleanup and the
// owner's `scripts/pull-logs.ts` read. Nothing about the sender is kept: not the token, its key ID, or the address.

export const BATCH = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
/** The app's file names, sealed: `peoplemaps-usage-log-<day>.jsonl.enc`, `trip-…`, `rec-…` and `use-…`. */
export const NAME = /^(peoplemaps-usage-log|trip|rec|use)-[A-Za-z0-9-]{1,40}\.jsonl\.enc$/;
/** How a sealed box starts. Only sealed files are taken, so a build that forgot to seal stores nothing readable. */
const MAGIC = new TextEncoder().encode("PMBOX1\n");
/** Well under a Worker's 128 MB of memory: the body is read whole to hash it. A one-hour drive is about 0.6 MB. */
export const MAX_LOG_BYTES = 25 * 1024 * 1024;
const SHA = /^[0-9a-f]{64}$/;

export async function uploadLog(request: Request, deps: Deps, batch: string, name: string): Promise<Response> {
  const keyId = await authorize(request, deps);
  await limitLogs(deps, keyId);
  if (!BATCH.test(batch) || !NAME.test(name)) throw new HttpError("not_found", "No such log name.");
  const claimed = (request.headers.get("x-content-sha256") ?? "").toLowerCase();
  if (!SHA.test(claimed)) throw new HttpError("invalid_report", "X-Content-SHA256 is required.", "sha256");
  const deleteHash = (request.headers.get("x-delete-sha256") ?? "").toLowerCase();
  if (!SHA.test(deleteHash)) throw new HttpError("invalid_report", "X-Delete-SHA256 is required.", "deleteSha256");
  const length = Number(request.headers.get("content-length") ?? NaN);
  if (Number.isFinite(length) && length > MAX_LOG_BYTES) throw new HttpError("too_large", "The file is too large to send.");

  const key = `${batch}/${name}`;
  const existing = await deps.store.logUpload(key);
  if (existing) {
    if (existing.sha256 !== claimed) throw new HttpError("conflict", "A different file was already sent under this name.");
    return json(200, { key, bytes: existing.bytes, expiresAt: existing.expires_at });
  }

  const now = deps.clock.now();
  const today = now.toISOString().slice(0, 10) + "T00:00:00Z";
  const body = new Uint8Array(await request.arrayBuffer());
  if (body.length <= MAGIC.length + 32 || !MAGIC.every((b, i) => body[i] === b)) throw new HttpError("invalid_report", "The file is not sealed.", "body");
  if (body.length > MAX_LOG_BYTES) throw new HttpError("too_large", "The file is too large to send.");
  if ((await deps.store.logBytesSince(today)) + body.length > deps.vars.logBytesPerDay) {
    throw new HttpError("rate_limited", "The server takes no more logs today.", undefined, secondsToMidnightUTC(now));
  }
  const digest = hex(await sha256(body));
  if (digest !== claimed) throw new HttpError("invalid_report", "The file does not match its SHA-256.", "sha256");

  // The object first: a row never names a file that is not there, and an object without a row is overwritten by a retry.
  await deps.logs.put(key, body, { httpMetadata: { contentType: "application/octet-stream" }, sha256: digest });
  const received = hour(now);
  const expires = hour(addDays(new Date(received), deps.vars.logRetentionDays));
  await deps.store.insertLogUpload({ key, batch, name, bytes: body.length, sha256: digest, delete_hash: deleteHash, received_at: received, expires_at: expires });
  return json(201, { key, bytes: body.length, expiresAt: expires });
}

/** Removes what is left of one Send, for the phone that holds its delete secret. 204 also when nothing is left: pulled, expired or never there. */
export async function deleteLogBatch(request: Request, deps: Deps, batch: string): Promise<Response> {
  const keyId = await authorize(request, deps);
  await limitLogs(deps, keyId);
  const secret = request.headers.get("x-delete-secret") ?? "";
  if (!BATCH.test(batch) || !SHA.test(secret)) throw new HttpError("not_found", "No such batch.");
  const keys = await deps.store.logKeysOfBatch(batch, hex(await sha256(new TextEncoder().encode(secret))));
  if (keys.length > 0) {
    await deps.logs.delete(keys);
    await deps.store.deleteLogUploads(keys);
  }
  return json(204, null);
}
