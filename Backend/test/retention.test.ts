import { describe, expect, it } from "vitest";
import { runCron } from "../src/index";
import { retention, retryIssues } from "../src/retention";
import { fixture, world } from "./helpers";

describe("retention cron", () => {
  it("deletes reports by expiry, idle installs without reports, and old maintainer reads", async () => {
    const w = world();
    const keep = await w.mint();
    await w.send(keep.token);
    w.clock.t = new Date("2026-12-01T10:00:00Z");
    await w.send(keep.token, { ...fixture(), id: "00000000-0000-4000-8000-000000000002" });
    const idle = await w.mint();
    w.sql.db.exec(`UPDATE installs SET last_seen_at = '2025-11-01T00:00:00Z' WHERE id = '${idle.installID}'`);
    w.sql.db.exec("INSERT INTO maintainer_reads VALUES (1, 'old', '2026-08-01T00:00:00Z'), (2, 'new', '2026-11-30T00:00:00Z')");

    w.clock.t = new Date("2027-01-29T20:59:00Z");
    expect(await retention(w.deps)).toEqual({ reports: 0, installs: 1, maintainerReads: 1 });
    w.clock.t = new Date("2027-01-29T21:00:01Z");
    expect(await retention(w.deps)).toEqual({ reports: 1, installs: 0, maintainerReads: 0 });
    expect(w.rows("reports").map((r) => r.id)).toEqual(["00000000-0000-4000-8000-000000000002"]);
    expect(w.rows("installs").map((r) => r.id)).toEqual([keep.installID]);
    expect(w.rows("maintainer_reads").map((r) => r.login)).toEqual(["new"]);
    expect(w.rows("aggregates").reduce((n, r) => n + Number(r.count), 0)).toBe(2);
  });

  it("keeps an install idle for a year while it still has reports", async () => {
    const w = world();
    const a = await w.mint();
    await w.send(a.token);
    w.sql.db.exec("UPDATE installs SET last_seen_at = '2025-01-01T00:00:00Z'");
    expect((await retention(w.deps)).installs).toBe(0);
  });
});

describe("issue retry cron", () => {
  it("never files held reports", async () => {
    const w = world();
    await w.send((await w.mint()).token);
    expect(await retryIssues(w.deps)).toEqual({ opened: 0, pending: 0, failed: 0 });
    expect(w.gh.requests).toHaveLength(0);
  });

  it("marks a row failed after ten attempts and stops trying it", async () => {
    const w = world({ holdForApproval: false });
    w.gh.createStatus = 500;
    await w.send((await w.mint()).token);
    for (let i = 0; i < 8; i++) expect((await retryIssues(w.deps)).pending).toBe(1);
    expect(await retryIssues(w.deps)).toEqual({ opened: 0, pending: 0, failed: 1 });
    expect(w.rows("reports")[0]).toMatchObject({ issue_state: "failed", issue_attempts: 10 });
    expect(await retryIssues(w.deps)).toEqual({ opened: 0, pending: 0, failed: 0 });
  });

  it("files at most 20 per run, oldest first", async () => {
    const w = world({ holdForApproval: false, reportsPerDay: 100 });
    const { token } = await w.mint();
    w.gh.createStatus = 500;
    for (let i = 0; i < 25; i++) await w.send(token, { ...fixture(), id: `00000000-0000-4000-8000-0000000000${String(i).padStart(2, "0")}` });
    w.gh.createStatus = 201;
    expect((await retryIssues(w.deps)).opened).toBe(20);
    expect((await retryIssues(w.deps)).opened).toBe(5);
  });

  it("is dispatched by schedule", async () => {
    const w = world({ holdForApproval: false });
    w.gh.createStatus = 500;
    await w.send((await w.mint()).token);
    w.gh.createStatus = 201;
    await runCron("17 3 * * *", w.deps);
    expect(w.gh.issues.size).toBe(0);
    await runCron("7 * * * *", w.deps);
    expect(w.gh.issues.size).toBe(1);
  });
});
