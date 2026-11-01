import { readFileSync } from "node:fs";
import { join } from "node:path";
import type { Deps, RateLimiter, Vars } from "../src/deps";
import { gitHubClient } from "../src/github";
import { handle } from "../src/index";
import { Store } from "../src/store";
import type { Report } from "../src/validate";
import { GitHubMock } from "./github.mock";
import { sqliteSql } from "./store-sqlite";

export const WORKER_TOKEN = "gh_worker_token";
export const BASE = "https://reports.example.test";
export const IP = "203.0.113.7";

export function fixture(): Report {
  return JSON.parse(readFileSync(join(import.meta.dirname, "fixtures", "report.json"), "utf8"));
}

export class FakeLimiter implements RateLimiter {
  keys: string[] = [];
  allow = true;
  async limit({ key }: { key: string }) {
    this.keys.push(key);
    return { success: this.allow };
  }
}

export interface World {
  deps: Deps;
  sql: ReturnType<typeof sqliteSql>;
  gh: GitHubMock;
  limits: { auth: FakeLimiter; installs: FakeLimiter; reports: FakeLimiter };
  clock: { t: Date; now(): Date };
  call(method: string, path: string, opts?: { token?: string; body?: unknown; raw?: string; ip?: string }): Promise<Response>;
  mint(): Promise<{ installID: string; token: string }>;
  send(token: string, report?: unknown): Promise<Response>;
  maintainer(login?: string, permission?: string): string;
  rows(table: string): Record<string, unknown>[];
}

export function world(vars: Partial<Vars> = {}, now = "2026-10-31T21:34:00Z"): World {
  const sql = sqliteSql();
  const gh = new GitHubMock();
  const limits = { auth: new FakeLimiter(), installs: new FakeLimiter(), reports: new FakeLimiter() };
  const clock = { t: new Date(now), now() { return new Date(this.t); } };
  const deps: Deps = {
    store: new Store(sql),
    github: gitHubClient({ token: WORKER_TOKEN, repo: "electropicks/peoplemaps", fetch: gh.fetch }),
    limits,
    clock,
    vars: { githubRepo: "electropicks/peoplemaps", retentionDays: 90, reportsPerDay: 20, issueDailyCap: 200, installsPerHour: 60, holdForApproval: true, ...vars },
  };
  const w: World = {
    deps, sql, gh, limits, clock,
    call(method, path, opts = {}) {
      const headers: Record<string, string> = { "cf-connecting-ip": opts.ip ?? IP };
      if (opts.token) headers.authorization = `Bearer ${opts.token}`;
      const body = opts.raw ?? (opts.body !== undefined ? JSON.stringify(opts.body) : undefined);
      if (body !== undefined) headers["content-type"] = "application/json";
      return handle(new Request(BASE + path, { method, headers, body }), deps);
    },
    async mint() {
      const res = await w.call("POST", "/v1/installs", { body: { schema: 1, app: { version: "0.1.0", build: "1" } } });
      if (res.status !== 201) throw new Error(`mint ${res.status}`);
      return res.json() as Promise<{ installID: string; token: string }>;
    },
    send(token, report = fixture()) {
      return w.call("POST", "/v1/reports", { token, body: report });
    },
    maintainer(login = "maint", permission = "admin") {
      const token = `ghp_${login}`;
      gh.users.set(token, login);
      gh.permissions.set(login, { permission: permission === "maintain" ? "write" : permission, role_name: permission });
      return token;
    },
    rows(table) {
      return sql.db.prepare(`SELECT * FROM ${table}`).all() as Record<string, unknown>[];
    },
  };
  return w;
}
