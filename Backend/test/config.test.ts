import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const root = join(import.meta.dirname, "..");

describe("wrangler.jsonc", () => {
  const text = readFileSync(join(root, "wrangler.jsonc"), "utf8");
  const config = JSON.parse(text.replace(/^\s*\/\/.*$/gm, ""));
  it("answers on workers.dev only, with no preview URLs and no per-request logs", () => {
    expect(config.workers_dev).toBe(true);
    expect(config.routes).toBeUndefined();
    expect(config.preview_urls).toBe(false);
    expect(config.observability).toEqual({ enabled: false, logs: { invocation_logs: false } });
  });
  it("has the three rate limits under the ratelimits key, and no unsafe bindings", () => {
    expect(config.ratelimits.map((b: any) => [b.name, b.simple.limit, b.simple.period])).toEqual([["RL_AUTH", 10, 60], ["RL_INSTALLS", 2, 60], ["RL_REPORTS", 10, 60]]);
    expect(config.unsafe).toBeUndefined();
  });
  it("has only the retention cron and needs no secret", () => {
    expect(config.triggers.crons).toEqual(["17 3 * * *"]);
    expect(config.secrets).toBeUndefined();
  });
});

describe("logging (4.6)", () => {
  it("uses console only with a constant string plus a count or status", () => {
    // The second argument may only be a number literal or a field of the cron's counts.
    const allowed = /^console\.(log|warn|error)\("[^"`$\\]*"(, (\d+|(counts|out)\.\w+( \+ (counts|out)\.\w+)*))?\);?$/;
    expect(allowed.test('console.log("x", request);')).toBe(false);
    expect(allowed.test("console.log(`ip ${ip}`);")).toBe(false);
    const bad: string[] = [];
    for (const f of readdirSync(join(root, "src"))) {
      readFileSync(join(root, "src", f), "utf8").split("\n").forEach((line, i) => {
        if (!line.includes("console.")) return;
        if (!allowed.test(line.trim())) bad.push(`${f}:${i + 1}: ${line.trim()}`);
      });
    }
    expect(bad).toEqual([]);
  });

  it("reads cf-connecting-ip only in ratelimit.ts and never talks to GitHub", () => {
    for (const f of readdirSync(join(root, "src"))) {
      const src = readFileSync(join(root, "src", f), "utf8");
      if (src.includes("cf-connecting-ip")) expect(f).toBe("ratelimit.ts");
      expect(src).not.toMatch(/GITHUB_TOKEN|api\.github\.com/);
    }
  });
});
