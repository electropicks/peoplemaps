import { describe, expect, it } from "vitest";
import { StorageUnavailable } from "../src/errors";
import { fixture, IP, world } from "./helpers";
import exactCase from "./fixtures/parity/exact.json";

const ID = fixture().id;

describe("POST /v1/reports", () => {
  it("stores the report", async () => {
    const w = world();
    const { token, installID } = await w.mint();
    const res = await w.send(token);
    expect(res.status).toBe(201);
    expect(await res.json()).toEqual({ id: ID, receivedAt: "2026-10-31T21:00:00Z", expiresAt: "2027-01-29T21:00:00Z" });
    const [row] = w.rows("reports");
    expect(row).toMatchObject({ install_id: installID, category: "wrong_instruction", exact_json: null });
    expect(JSON.parse(row.public_json as string).position.cell).toBe("r29c11");
  });

  it("is idempotent on id: same body 200, reordered keys 200, changed body 409", async () => {
    const w = world();
    const { token } = await w.mint();
    await w.send(token);
    const again = await w.send(token);
    expect(again.status).toBe(200);
    expect(await again.json()).toEqual({ id: ID, receivedAt: "2026-10-31T21:00:00Z", expiresAt: "2027-01-29T21:00:00Z" });
    const reordered = Object.fromEntries(Object.entries(fixture()).reverse());
    expect((await w.send(token, reordered)).status).toBe(200);
    const changed = await w.send(token, { ...fixture(), note: "Different." });
    expect(changed.status).toBe(409);
    expect(await changed.json()).toEqual({ error: "conflict", message: `Report ${ID} was already sent with different content.` });
    expect(w.rows("reports")).toHaveLength(1);
  });

  it("answers 409 when another install reuses the id", async () => {
    const w = world();
    await w.send((await w.mint()).token);
    expect((await w.send((await w.mint()).token)).status).toBe(409);
  });

  it("validates with the field path", async () => {
    const w = world();
    const { token } = await w.mint();
    const res = await w.send(token, { ...fixture(), spoken: [{ text: "", secondsBefore: 1 }] });
    expect(res.status).toBe(400);
    expect(await res.json()).toMatchObject({ error: "invalid_report", field: "spoken[0].text" });
  });

  it("refuses bodies over 64 KB", async () => {
    const w = world();
    const { token } = await w.mint();
    const res = await w.call("POST", "/v1/reports", { token, raw: JSON.stringify({ ...fixture(), note: "x".repeat(70_000) }) });
    expect(res.status).toBe(413);
    expect(await res.json()).toMatchObject({ error: "too_large" });
  });

  it("splits exact fields out of public_json", async () => {
    const w = world();
    const { token } = await w.mint();
    expect((await w.send(token, exactCase.report)).status).toBe(201);
    const [row] = w.rows("reports");
    expect(JSON.parse(row.public_json as string)).toEqual(exactCase.public);
    expect(JSON.parse(row.exact_json as string)).toEqual(exactCase.exact);
  });

  it("holds the per-install daily cap from the install's own rows", async () => {
    const w = world({ reportsPerDay: 2 });
    const { token } = await w.mint();
    const id = (n: number) => `00000000-0000-4000-8000-00000000000${n}`;
    expect((await w.send(token, { ...fixture(), id: id(1) })).status).toBe(201);
    expect((await w.send(token, { ...fixture(), id: id(2) })).status).toBe(201);
    const res = await w.send(token, { ...fixture(), id: id(3) });
    expect(res.status).toBe(429);
    expect(await res.json()).toMatchObject({ error: "rate_limited" });
    expect((await w.send((await w.mint()).token, { ...fixture(), id: id(4) })).status).toBe(201);
    w.clock.t = new Date("2026-11-01T22:00:00Z");
    expect((await w.send(token, { ...fixture(), id: id(3) })).status).toBe(201);
  });

  it("keys RL_REPORTS on the IP and stores the IP nowhere", async () => {
    const w = world();
    const { token } = await w.mint();
    await w.send(token);
    expect(w.limits.reports.keys).toEqual([IP]);
    for (const t of ["installs", "reports"]) expect(JSON.stringify(w.rows(t))).not.toContain(IP);
    w.limits.reports.allow = false;
    expect((await w.send(token, { ...fixture(), id: "00000000-0000-4000-8000-000000000009" })).status).toBe(429);
  });

  it("answers 503 storage_unavailable and keeps nothing when D1 refuses the write", async () => {
    const w = world();
    const { token } = await w.mint();
    w.sql.batch = async () => { throw new StorageUnavailable("D1 limits spent"); };
    const res = await w.send(token);
    expect(res.status).toBe(503);
    expect(await res.json()).toMatchObject({ error: "storage_unavailable" });
    expect(Number(res.headers.get("retry-after"))).toBe(2 * 3600 + 26 * 60);
    expect(w.rows("reports")).toHaveLength(0);
  });

  it("rolls back the whole batch when one statement fails", async () => {
    const w = world();
    const { token } = await w.mint();
    w.sql.db.exec("CREATE TRIGGER refuse BEFORE UPDATE OF app_version ON installs BEGIN SELECT RAISE(ABORT, 'no'); END");
    expect((await w.send(token)).status).toBe(500);
    expect(w.rows("reports")).toHaveLength(0);
  });
});

describe("GET /v1/reports", () => {
  it("lists only the sender's reports, with category, never the body", async () => {
    const w = world();
    const a = await w.mint();
    const b = await w.mint();
    await w.send(a.token);
    await w.send(b.token, { ...fixture(), id: "00000000-0000-4000-8000-000000000002", category: "map_data" });
    const res = await w.call("GET", "/v1/reports", { token: a.token });
    expect(await res.json()).toEqual({ reports: [{ id: ID, receivedAt: "2026-10-31T21:00:00Z", expiresAt: "2027-01-29T21:00:00Z", category: "wrong_instruction" }] });
    expect((await w.call("GET", `/v1/reports/${ID}`, { token: a.token })).status).toBe(200);
    expect((await w.call("GET", `/v1/reports/${ID}`, { token: b.token })).status).toBe(404);
  });
});

describe("reportsByInstall", () => {
  it("loads only what the list shows, never the body or exact part", async () => {
    const w = world();
    const { token, installID } = await w.mint();
    await w.send(token, exactCase.report);
    expect(Object.keys((await w.deps.store.reportsByInstall(installID))[0]).sort()).toEqual(["category", "expires_at", "id", "received_at"]);
  });
});

describe("DELETE /v1/reports/{id}", () => {
  it("deletes the row", async () => {
    const w = world();
    const { token } = await w.mint();
    await w.send(token);
    expect((await w.call("DELETE", `/v1/reports/${ID}`, { token })).status).toBe(204);
    expect(w.rows("reports")).toHaveLength(0);
    expect((await w.call("DELETE", `/v1/reports/${ID}`, { token })).status).toBe(404);
  });

  it("does not delete another install's report", async () => {
    const w = world();
    await w.send((await w.mint()).token);
    expect((await w.call("DELETE", `/v1/reports/${ID}`, { token: (await w.mint()).token })).status).toBe(404);
    expect(w.rows("reports")).toHaveLength(1);
  });
});

describe("routing", () => {
  it("answers unknown routes with the error envelope", async () => {
    const w = world();
    const res = await w.call("GET", "/v2/reports");
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "not_found", message: "No such route." });
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(res.headers.get("access-control-allow-origin")).toBeNull();
  });
});
