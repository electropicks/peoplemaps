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
  it("deletes every issue, every report and the install", async () => {
    const w = world({ holdForApproval: false });
    const { token } = await w.mint();
    const other = await w.mint();
    await w.send(token);
    await w.send(token, { ...fixture(), id: "11111111-2222-4333-8444-555555555555" });
    await w.send(other.token, { ...fixture(), id: "99999999-2222-4333-8444-555555555555" });
    expect(w.gh.issues.size).toBe(3);
    const res = await w.call("DELETE", "/v1/installs/me", { token });
    expect(res.status).toBe(204);
    expect(w.gh.issues.size).toBe(1);
    expect(w.gh.requests.filter((r) => r.url.endsWith("/graphql"))).toHaveLength(2);
    expect(w.rows("reports")).toHaveLength(1);
    expect(w.rows("installs")).toHaveLength(1);
    expect((await w.call("GET", "/v1/reports", { token })).status).toBe(401);
  });

  it("removes nothing when GitHub fails, and a retry finishes the job", async () => {
    const w = world({ holdForApproval: false });
    const { token } = await w.mint();
    await w.send(token);
    w.gh.deleteStatus = 502;
    const res = await w.call("DELETE", "/v1/installs/me", { token });
    expect(res.status).toBe(503);
    expect(await res.json()).toMatchObject({ error: "github_unavailable" });
    expect(w.rows("reports")).toHaveLength(1);
    expect(w.rows("installs")).toHaveLength(1);
    w.gh.deleteStatus = 200;
    expect((await w.call("DELETE", "/v1/installs/me", { token })).status).toBe(204);
    expect(w.rows("reports")).toHaveLength(0);
  });

  it("deletes held reports without calling GitHub", async () => {
    const w = world();
    const { token } = await w.mint();
    await w.send(token);
    expect((await w.call("DELETE", "/v1/installs/me", { token })).status).toBe(204);
    expect(w.gh.requests).toHaveLength(0);
    expect(w.rows("reports")).toHaveLength(0);
  });
});
