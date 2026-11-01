import { describe, expect, it } from "vitest";
import { StorageUnavailable } from "../src/errors";
import { retryIssues } from "../src/retention";
import { fixture, IP, world } from "./helpers";
import exactCase from "./fixtures/parity/exact.json";

const ID = fixture().id;

describe("POST /v1/reports", () => {
  it("stores the report held, bumps the aggregate and sends nothing to GitHub", async () => {
    const w = world();
    const { token, installID } = await w.mint();
    const res = await w.send(token);
    expect(res.status).toBe(202);
    expect(await res.json()).toEqual({ id: ID, receivedAt: "2026-10-31T21:00:00Z", issue: null, issueState: "held", expiresAt: "2027-01-29T21:00:00Z" });
    const [row] = w.rows("reports");
    expect(row).toMatchObject({ install_id: installID, issue_state: "held", category: "wrong_instruction", mode: "drive", data_version: "a1b2c3d4e5f6", app_version: "0.1.0 (1)", cell: "r4c4", exact_json: null });
    expect(w.rows("aggregates")).toEqual([{ week: "2026-W44", cell: "r4c4", category: "wrong_instruction", mode: "drive", count: 1 }]);
    expect(w.gh.requests).toHaveLength(0);
  });

  it("is idempotent on id: same body 200, reordered keys 200, changed body 409", async () => {
    const w = world();
    const { token } = await w.mint();
    await w.send(token);
    const again = await w.send(token);
    expect(again.status).toBe(200);
    expect(await again.json()).toMatchObject({ id: ID, issueState: "held" });
    const reordered = Object.fromEntries(Object.entries(fixture()).reverse());
    expect((await w.send(token, reordered)).status).toBe(200);
    const changed = await w.send(token, { ...fixture(), note: "Different." });
    expect(changed.status).toBe(409);
    expect(await changed.json()).toEqual({ error: "conflict", message: `Report ${ID} was already sent with different content.` });
    expect(w.rows("reports")).toHaveLength(1);
    expect(w.rows("aggregates")[0].count).toBe(1);
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
    expect((await w.send(token, exactCase.report)).status).toBe(202);
    const [row] = w.rows("reports");
    expect(JSON.parse(row.public_json as string)).toEqual(exactCase.public);
    expect(JSON.parse(row.exact_json as string)).toEqual(exactCase.exact);
  });

  it("holds the per-install daily cap from the install's own rows", async () => {
    const w = world({ reportsPerDay: 2 });
    const { token } = await w.mint();
    const id = (n: number) => `00000000-0000-4000-8000-00000000000${n}`;
    expect((await w.send(token, { ...fixture(), id: id(1) })).status).toBe(202);
    expect((await w.send(token, { ...fixture(), id: id(2) })).status).toBe(202);
    const res = await w.send(token, { ...fixture(), id: id(3) });
    expect(res.status).toBe(429);
    expect(await res.json()).toMatchObject({ error: "rate_limited" });
    expect((await w.send((await w.mint()).token, { ...fixture(), id: id(4) })).status).toBe(202);
    w.clock.t = new Date("2026-11-01T22:00:00Z");
    expect((await w.send(token, { ...fixture(), id: id(3) })).status).toBe(202);
  });

  it("keys RL_REPORTS on the IP and stores the IP nowhere", async () => {
    const w = world();
    const { token } = await w.mint();
    await w.send(token);
    expect(w.limits.reports.keys).toEqual([IP]);
    for (const t of ["installs", "reports", "aggregates", "maintainer_reads"]) expect(JSON.stringify(w.rows(t))).not.toContain(IP);
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
    expect(w.rows("aggregates")).toHaveLength(0);
  });

  it("rolls back the whole batch when one statement fails", async () => {
    const w = world();
    const { token } = await w.mint();
    w.sql.db.exec("DROP TABLE aggregates");
    expect((await w.send(token)).status).toBe(500);
    expect(w.rows("reports")).toHaveLength(0);
  });
});

describe("without approval (dev)", () => {
  it("files at once and answers 201 with the issue", async () => {
    const w = world({ holdForApproval: false });
    const { token } = await w.mint();
    const res = await w.send(token);
    expect(res.status).toBe(201);
    expect(await res.json()).toMatchObject({ issueState: "opened", issue: { number: 100, url: "https://github.com/electropicks/peoplemaps/issues/100" } });
    expect(w.gh.issues.get(100)!.labels).toEqual(["app-report", "report:wrong_instruction", "mode:drive"]);
  });

  it("a GitHub 500 leaves it pending, the cron files it, and a retry returns the issue", async () => {
    const w = world({ holdForApproval: false });
    const { token } = await w.mint();
    w.gh.createStatus = 500;
    const res = await w.send(token);
    expect(res.status).toBe(202);
    expect(await res.json()).toMatchObject({ issue: null, issueState: "pending" });
    expect(w.rows("reports")[0]).toMatchObject({ issue_attempts: 1, issue_error: "create issue: HTTP 500" });
    w.gh.createStatus = 201;
    expect(await retryIssues(w.deps)).toEqual({ opened: 1, pending: 0, failed: 0 });
    const again = await w.send(token);
    expect(again.status).toBe(200);
    expect(await again.json()).toMatchObject({ issueState: "opened", issue: { number: 100 } });
  });

  it("without a GitHub token the report is stored and answered 202", async () => {
    const w = world({ holdForApproval: false });
    const { gitHubClient } = await import("../src/github");
    w.deps.github = gitHubClient({ token: "", repo: "electropicks/peoplemaps", fetch: w.gh.fetch });
    const res = await w.send((await w.mint()).token);
    expect(res.status).toBe(202);
    expect(w.gh.requests).toHaveLength(0);
  });

  it("holds approved reports over the daily issue cap for the cron", async () => {
    const w = world({ holdForApproval: false, issueDailyCap: 1 });
    const { token } = await w.mint();
    expect((await w.send(token)).status).toBe(201);
    const second = await w.send(token, { ...fixture(), id: "00000000-0000-4000-8000-000000000002" });
    expect(second.status).toBe(202);
    expect(await second.json()).toMatchObject({ issueState: "pending" });
    expect(w.rows("reports").find((r) => r.id !== ID)!.issue_attempts).toBe(0);
    expect(await retryIssues(w.deps)).toEqual({ opened: 0, pending: 1, failed: 0 });
    w.clock.t = new Date("2026-11-01T00:07:00Z");
    expect(await retryIssues(w.deps)).toEqual({ opened: 1, pending: 0, failed: 0 });
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
    expect(await res.json()).toEqual({ reports: [{ id: ID, receivedAt: "2026-10-31T21:00:00Z", issue: null, issueState: "held", expiresAt: "2027-01-29T21:00:00Z", category: "wrong_instruction" }] });
    expect((await w.call("GET", `/v1/reports/${ID}`, { token: a.token })).status).toBe(200);
    expect((await w.call("GET", `/v1/reports/${ID}`, { token: b.token })).status).toBe(404);
  });
});

describe("DELETE /v1/reports/{id}", () => {
  it("deletes the issue, then the row; aggregates are not decremented", async () => {
    const w = world({ holdForApproval: false });
    const { token } = await w.mint();
    await w.send(token);
    expect((await w.call("DELETE", `/v1/reports/${ID}`, { token })).status).toBe(204);
    expect(w.gh.issues.size).toBe(0);
    expect(w.rows("reports")).toHaveLength(0);
    expect(w.rows("aggregates")[0].count).toBe(1);
    expect((await w.call("DELETE", `/v1/reports/${ID}`, { token })).status).toBe(404);
  });

  it("keeps the row when GitHub fails", async () => {
    const w = world({ holdForApproval: false });
    const { token } = await w.mint();
    await w.send(token);
    w.gh.down = 500;
    const res = await w.call("DELETE", `/v1/reports/${ID}`, { token });
    expect(res.status).toBe(503);
    expect(await res.json()).toMatchObject({ error: "github_unavailable" });
    expect(w.rows("reports")).toHaveLength(1);
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
