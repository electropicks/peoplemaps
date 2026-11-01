import { describe, expect, it } from "vitest";
import { retention } from "../src/retention";
import { fixture, world } from "./helpers";

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
    expect(await retention(w.deps)).toEqual({ reports: 0, installs: 1 });
    w.clock.t = new Date("2027-01-29T21:00:01Z");
    expect(await retention(w.deps)).toEqual({ reports: 1, installs: 0 });
    expect(w.rows("reports").map((r) => r.id)).toEqual(["00000000-0000-4000-8000-000000000002"]);
    expect(w.rows("installs").map((r) => r.id)).toEqual([keep.installID]);
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
