import { describe, expect, it } from "vitest";
import worker, { type Env } from "../src/index";
import { retention } from "../src/retention";
import { fixture, FakeLimiter, world, type World } from "./helpers";

describe("retention cron", () => {
  it("deletes reports by expiry, and idle installs without reports", async () => {
    const w = world();
    const keep = await w.mint();
    await w.send(keep.token);
    w.clock.t = new Date("2026-12-01T10:00:00Z");
    await w.send(keep.token, { ...fixture(), id: "00000000-0000-4000-8000-000000000002" });
    const idle = await w.mint();
    w.sql.db.exec(`UPDATE installs SET last_seen_at = '2025-11-01T00:00:00Z' WHERE id = '${idle.installID}'`);

    w.clock.t = new Date("2027-01-29T20:59:00Z");
    expect(await retention(w.deps)).toEqual({ reports: 0, installs: 1, keys: 0, logs: 0 });
    w.clock.t = new Date("2027-01-29T21:00:01Z");
    expect(await retention(w.deps)).toEqual({ reports: 1, installs: 0, keys: 0, logs: 0 });
    expect(w.rows("reports").map((r) => r.id)).toEqual(["00000000-0000-4000-8000-000000000002"]);
    expect(w.rows("installs").map((r) => r.id)).toEqual([keep.installID]);
  });

  it("keeps an install idle for a year while it still has reports", async () => {
    const w = world();
    const a = await w.mint();
    await w.send(a.token);
    w.sql.db.exec("UPDATE installs SET last_seen_at = '2025-01-01T00:00:00Z'");
    expect((await retention(w.deps)).installs).toBe(0);
  });
});

describe("the scheduled handler", () => {
  // The D1 binding's shape over the test database, so the real entry point runs.
  const env = (w: World): Env => {
    const statement = (sql: string, params: unknown[] = []) => ({
      bind: (...p: unknown[]) => statement(sql, p),
      all: async () => ({ results: await w.sql.all(sql, ...params) }),
      run: async () => ({ meta: await w.sql.run(sql, ...params) }),
    });
    return {
      DB: { prepare: (sql: string) => statement(sql) } as unknown as D1Database,
      DATA: {} as R2Bucket,
      LOGS: w.logs as unknown as R2Bucket,
      RL_AUTH: new FakeLimiter(), RL_INSTALLS: new FakeLimiter(), RL_REPORTS: new FakeLimiter(), RL_ATTEST: new FakeLimiter(), RL_DOWNLOADS: new FakeLimiter(), RL_LOGS: new FakeLimiter(),
    };
  };
  const event = {} as ScheduledController;

  it("deletes expired reports through the D1 binding", async () => {
    const w = world();
    await w.send((await w.mint()).token);
    w.sql.db.exec("UPDATE reports SET expires_at = '2020-01-01T00:00:00Z'");
    await worker.scheduled(event, env(w));
    expect(w.rows("reports")).toHaveLength(0);
  });

  it("fails the invocation when the job fails", async () => {
    const w = world();
    w.sql.db.exec("DROP TABLE reports");
    await expect(worker.scheduled(event, env(w))).rejects.toThrow();
  });
});
