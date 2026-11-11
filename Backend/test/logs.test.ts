import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import { issueDownloadToken } from "../src/download-token";
import { retention } from "../src/retention";
import { TEST_TOKEN_SECRET, world } from "./helpers";

// PUT /v1/logs/{batch}/{name} and DELETE /v1/logs/{batch} (4.8) against the in-memory bucket. Real R2 is not exercised.

const BATCH = "0b6f7a52-3c1d-4e8f-9a2b-1c3d5e7f9a0b";
const NAME = "trip-20261110T221320Z-drive.jsonl.enc";
const PATH = `/v1/logs/${BATCH}/${NAME}`;
const box = (text: string) => new TextEncoder().encode("PMBOX1\n" + "k".repeat(32) + text);
const FILE = box("sealed bytes the Worker cannot read");
const sha = (b: Uint8Array | string) => createHash("sha256").update(b).digest("hex");
const SECRET = "ab".repeat(32);

async function setup(vars = {}) {
  const w = world(vars);
  const { token } = await issueDownloadToken(TEST_TOKEN_SECRET, new Uint8Array(32).fill(7), w.clock.now());
  const put = (path = PATH, body: Uint8Array = FILE, digest = sha(body), t: string | null = token, secret = SECRET) =>
    w.call("PUT", path, { token: t ?? undefined, raw: body, headers: { "x-content-sha256": digest, "x-delete-sha256": sha(secret) } });
  const del = (batch = BATCH, secret = SECRET, t: string | null = token) =>
    w.call("DELETE", `/v1/logs/${batch}`, { token: t ?? undefined, headers: { "x-delete-secret": secret } });
  return { w, token, put, del };
}

describe("PUT /v1/logs/{batch}/{name}", () => {
  it("stores the sealed bytes as sent and lists them in D1, with nothing about the sender", async () => {
    const { w, put } = await setup();
    const res = await put();
    expect(res.status).toBe(201);
    expect(await res.json()).toEqual({ key: `${BATCH}/${NAME}`, bytes: FILE.length, expiresAt: "2026-11-30T21:00:00Z" });
    const stored = w.logs.objects.get(`${BATCH}/${NAME}`)!;
    expect(stored.bytes).toEqual(FILE);
    expect(stored.contentType).toBe("application/octet-stream");
    expect(w.rows("log_uploads")).toEqual([{
      key: `${BATCH}/${NAME}`, batch: BATCH, name: NAME, bytes: FILE.length, sha256: sha(FILE), delete_hash: sha(SECRET),
      received_at: "2026-10-31T21:00:00Z", expires_at: "2026-11-30T21:00:00Z",
    }]);
    expect(w.limits.logs.keys).toHaveLength(1);
  });

  it("answers a retry of the same file with 200, and a different file under the same name with 409", async () => {
    const { put } = await setup();
    expect((await put()).status).toBe(201);
    expect((await put()).status).toBe(200);
    expect((await put(PATH, box("other"))).status).toBe(409);
  });

  it("needs a valid download token", async () => {
    const { w, put } = await setup();
    expect((await put(PATH, FILE, sha(FILE), null)).status).toBe(401);
    expect((await put(PATH, FILE, sha(FILE), "pmd_" + "A".repeat(92))).status).toBe(401);
    expect(w.logs.objects.size).toBe(0);
  });

  it("takes only the app's sealed file names under a batch UUID", async () => {
    const { put } = await setup();
    for (const path of [
      `/v1/logs/${BATCH}/notes.txt`, `/v1/logs/${BATCH}/trip-..%2Fx.jsonl.enc`, `/v1/logs/not-a-uuid/${NAME}`,
      `/v1/logs/${BATCH.toUpperCase()}/${NAME}`, `/v1/logs/${BATCH}/use-2026-11-10.jsonl`,
    ]) expect((await put(path)).status, path).toBe(404);
    for (const name of ["peoplemaps-usage-log-2026-11-10.jsonl.enc", "rec-20261110T221320Z.jsonl.enc", "use-2026-11-10.jsonl.enc"]) {
      expect((await put(`/v1/logs/${BATCH}/${name}`)).status, name).toBe(201);
    }
  });

  it("refuses a missing or wrong SHA-256, a missing delete hash, and anything not sealed", async () => {
    const { w, put, token } = await setup();
    expect((await put(PATH, FILE, "")).status).toBe(400);
    expect((await put(PATH, FILE, "0".repeat(64))).status).toBe(400);
    const plain = new TextEncoder().encode('{"kind":"fix","lat":47.6,"lon":-122.3}\n'.repeat(4));
    expect((await put(PATH, plain)).status).toBe(400);
    expect((await put(PATH, new Uint8Array(0))).status).toBe(400);
    expect((await w.call("PUT", PATH, { token, raw: FILE, headers: { "x-content-sha256": sha(FILE) } })).status).toBe(400);
    expect(w.logs.objects.size).toBe(0);
    expect(w.rows("log_uploads")).toHaveLength(0);
  });

  it("stops at the day's byte ceiling until midnight UTC", async () => {
    const { w, put } = await setup({ logBytesPerDay: FILE.length * 2 });
    expect((await put(`/v1/logs/${BATCH}/use-2026-10-30.jsonl.enc`)).status).toBe(201);
    expect((await put(`/v1/logs/${BATCH}/use-2026-10-31.jsonl.enc`)).status).toBe(201);
    const res = await put();
    expect(res.status).toBe(429);
    expect(res.headers.get("retry-after")).toBe(String(26 * 60 + 2 * 3600));
    w.clock.t = new Date("2026-11-01T00:00:01Z");
    expect((await put()).status).toBe(201);
  });

  it("is rate limited per key ID", async () => {
    const { w, put } = await setup();
    w.limits.logs.allow = false;
    expect((await put()).status).toBe(429);
  });

  it("is deleted, file and row, by the cleanup after its 30 days", async () => {
    const { w, put } = await setup();
    await put();
    w.clock.t = new Date("2026-11-30T20:59:00Z");
    expect((await retention(w.deps)).logs).toBe(0);
    w.clock.t = new Date("2026-11-30T21:00:01Z");
    expect((await retention(w.deps)).logs).toBe(1);
    expect(w.logs.objects.size).toBe(0);
    expect(w.rows("log_uploads")).toHaveLength(0);
  });
});

describe("DELETE /v1/logs/{batch}", () => {
  const OTHER = "11111111-2222-4333-8444-555555555555";

  it("removes every file of the batch, and only that batch, for the holder of its secret", async () => {
    const { w, put, del } = await setup();
    await put();
    await put(`/v1/logs/${BATCH}/use-2026-10-31.jsonl.enc`);
    await put(`/v1/logs/${OTHER}/use-2026-10-31.jsonl.enc`, FILE, sha(FILE), undefined, "cd".repeat(32));
    expect((await del()).status).toBe(204);
    expect([...w.logs.objects.keys()]).toEqual([`${OTHER}/use-2026-10-31.jsonl.enc`]);
    expect(w.rows("log_uploads").map((r) => r.batch)).toEqual([OTHER]);
  });

  it("deletes nothing with another secret, and still answers 204", async () => {
    const { w, put, del } = await setup();
    await put();
    expect((await del(BATCH, "ef".repeat(32))).status).toBe(204);
    expect((await del(OTHER)).status).toBe(204);
    expect(w.logs.objects.size).toBe(1);
  });

  it("needs a download token and a well-formed secret", async () => {
    const { w, put, del } = await setup();
    await put();
    expect((await del(BATCH, SECRET, null)).status).toBe(401);
    expect((await del(BATCH, "short")).status).toBe(404);
    expect(w.logs.objects.size).toBe(1);
  });
});
