import { describe, expect, it } from "vitest";
import { StorageUnavailable } from "../src/errors";
import { sha256Hex } from "../src/installs";
import { fixture, IP, world } from "./helpers";

describe("POST /v1/installs", () => {
  it("mints an ID and a token and stores only the token's hash", async () => {
    const w = world();
    const { installID, token } = await w.mint();
    expect(installID).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    expect(token).toMatch(/^pm_[A-Za-z0-9_-]{43}$/);
    const [row] = w.rows("installs");
    expect(row).toEqual({ id: installID, token_hash: await sha256Hex(token), app_version: "0.1.0 (1)", created_at: "2026-10-31T21:00:00Z", last_seen_at: "2026-10-31T21:00:00Z" });
    expect(JSON.stringify(w.rows("installs"))).not.toContain(token);
  });

  it("answers with no-store and no cookies", async () => {
    const w = world();
    const res = await w.call("POST", "/v1/installs", { body: { schema: 1, app: { version: "0.1.0", build: "1" } } });
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(res.headers.get("set-cookie")).toBeNull();
  });

  it("refuses a bad body", async () => {
    const w = world();
    const res = await w.call("POST", "/v1/installs", { body: { schema: 1, app: { version: "" } } });
    expect(res.status).toBe(400);
    expect(await res.json()).toMatchObject({ error: "invalid_report", field: "app.version" });
  });

  it("counts app strings in code points, as validate.ts does", async () => {
    const w = world();
    const post = (version: string) => w.call("POST", "/v1/installs", { body: { schema: 1, app: { version, build: "1" } } });
    // 32 emoji are 64 UTF-16 units but 32 code points: accepted. 33 are refused.
    expect((await post("\u{1F600}".repeat(32))).status).toBe(201);
    const res = await post("\u{1F600}".repeat(33));
    expect(res.status).toBe(400);
    expect(await res.json()).toMatchObject({ error: "invalid_report", field: "app.version" });
  });

  it("holds the hourly mint ceiling", async () => {
    const w = world({ installsPerHour: 2 });
    await w.mint();
    await w.mint();
    const res = await w.call("POST", "/v1/installs", { body: { schema: 1, app: { version: "0.1.0", build: "1" } } });
    expect(res.status).toBe(429);
    expect(await res.json()).toMatchObject({ error: "rate_limited" });
    expect(res.headers.get("retry-after")).toBe(String(26 * 60));
    w.clock.t = new Date("2026-10-31T22:00:01Z");
    await expect(w.mint()).resolves.toBeTruthy();
  });

  it("keys RL_INSTALLS on the client IP", async () => {
    const w = world();
    await w.mint();
    expect(w.limits.installs.keys).toEqual([IP]);
    w.limits.installs.allow = false;
    const res = await w.call("POST", "/v1/installs", { body: { schema: 1, app: { version: "0.1.0", build: "1" } } });
    expect(res.status).toBe(429);
    expect(res.headers.get("retry-after")).toBe("60");
  });

  it("answers 503 storage_unavailable until midnight when D1 refuses", async () => {
    const w = world();
    w.deps.store.insertInstall = async () => { throw new StorageUnavailable("limits"); };
    const res = await w.call("POST", "/v1/installs", { body: { schema: 1, app: { version: "0.1.0", build: "1" } } });
    expect(res.status).toBe(503);
    expect(await res.json()).toMatchObject({ error: "storage_unavailable" });
    expect(res.headers.get("retry-after")).toBe(String(2 * 3600 + 26 * 60));
  });
});

describe("bearer tokens", () => {
  it("reuses a token across requests and keeps last_seen_at to the hour", async () => {
    const w = world();
    const { token } = await w.mint();
    w.clock.t = new Date("2026-11-02T08:12:00Z");
    expect((await w.call("GET", "/v1/reports", { token })).status).toBe(200);
    expect((await w.call("GET", "/v1/reports", { token })).status).toBe(200);
    expect(w.rows("installs")[0].last_seen_at).toBe("2026-11-02T08:00:00Z");
  });

  it("refuses a missing, malformed or unknown token with 401", async () => {
    const w = world();
    await w.mint();
    for (const token of [undefined, "pm_short", "pm_" + "A".repeat(43)]) {
      const res = await w.call("GET", "/v1/reports", { token });
      expect(res.status).toBe(401);
      expect(await res.json()).toMatchObject({ error: "unauthorized" });
    }
  });

  it("answers 503 with no midnight retry when D1 is full", async () => {
    const w = world();
    w.deps.store.insertInstall = async () => { throw new StorageUnavailable("full", false); };
    const res = await w.call("POST", "/v1/installs", { body: { schema: 1, app: { version: "0.1.0", build: "1" } } });
    expect(res.status).toBe(503);
    expect(res.headers.get("retry-after")).toBeNull();
    expect(await res.json()).toEqual({ error: "storage_unavailable", message: "The report server is full." });
  });

  it("still reads and deletes when the last_seen_at update is refused", async () => {
    const w = world();
    const { token } = await w.mint();
    await w.send(token);
    w.clock.t = new Date(w.clock.t.getTime() + 2 * 3_600_000);
    w.deps.store.touchInstall = async () => { throw new StorageUnavailable("full", false); };
    expect((await w.call("GET", "/v1/reports", { token })).status).toBe(200);
    expect((await w.call("DELETE", "/v1/installs/me", { token })).status).toBe(204);
    expect(w.rows("reports")).toHaveLength(0);
    expect(w.rows("installs")).toHaveLength(0);
  });

  it("needs a token on every route except minting (4)", async () => {
    const w = world();
    const id = "0B7A4C2E-9D1F-4E3A-8B6C-5D4E3F2A1B0C";
    const routes = [["DELETE", "/v1/installs/me"], ["POST", "/v1/reports"], ["GET", "/v1/reports"], ["GET", `/v1/reports/${id}`], ["DELETE", `/v1/reports/${id}`]];
    for (const [method, path] of routes) expect((await w.call(method, path)).status, `${method} ${path}`).toBe(401);
    for (const [method, path] of [["GET", "/"], ["GET", "/health"], ["GET", "/v1/installs"]]) expect((await w.call(method, path)).status, `${method} ${path}`).toBe(404);
  });

  it("keys RL_AUTH on the token hash", async () => {
    const w = world();
    const { token } = await w.mint();
    await w.call("GET", "/v1/reports", { token });
    expect(w.limits.auth.keys).toEqual([await sha256Hex(token)]);
    w.limits.auth.allow = false;
    expect((await w.call("GET", "/v1/reports", { token })).status).toBe(429);
  });
});

describe("DELETE /v1/installs/me", () => {
  it("deletes every report of the install and the install, and nobody else's", async () => {
    const w = world();
    const { token } = await w.mint();
    const other = await w.mint();
    await w.send(token);
    await w.send(token, { ...fixture(), id: "11111111-2222-4333-8444-555555555555" });
    await w.send(other.token, { ...fixture(), id: "99999999-2222-4333-8444-555555555555" });
    expect((await w.call("DELETE", "/v1/installs/me", { token })).status).toBe(204);
    expect(w.rows("reports").map((r) => r.id)).toEqual(["99999999-2222-4333-8444-555555555555"]);
    expect(w.rows("installs")).toHaveLength(1);
    expect((await w.call("GET", "/v1/reports", { token })).status).toBe(401);
  });

  it("lets the same report be sent again under a new token", async () => {
    const w = world();
    const { token } = await w.mint();
    await w.send(token);
    await w.call("DELETE", "/v1/installs/me", { token });
    expect((await w.send((await w.mint()).token)).status).toBe(201);
  });
});
