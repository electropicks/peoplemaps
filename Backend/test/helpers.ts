import { readFileSync } from "node:fs";
import { join } from "node:path";
import { APPLE_APP_ATTEST_ROOT } from "../src/apple-root";
import type { AttestConfig, Bucket, BucketObject, BucketObjectBody, Deps, LogBucket, RateLimiter, Vars } from "../src/deps";
import { handle } from "../src/index";
import { Store } from "../src/store";
import type { Report } from "../src/validate";
import { sqliteSql } from "./store-sqlite";

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

/** Test values only: a made-up team and bundle ID, and an HMAC key used nowhere else. */
export const TEST_APP_ID = "ABCDE12345.org.example.peoplemaps";
export const TEST_TOKEN_SECRET = "test-only-download-token-secret-0123456789";

/** An in-memory R2 stand-in: ETags, conditional gets and ranges, and a streamed body, like the binding. */
export class MemoryBucket implements Bucket {
  objects = new Map<string, { bytes: Uint8Array; etag: string; uploaded: Date; contentType?: string }>();
  gets: { key: string; range?: { offset: number; length: number } }[] = [];
  private n = 0;
  put(key: string, bytes: Uint8Array, contentType?: string) {
    this.objects.set(key, { bytes, etag: `"etag${++this.n}"`, uploaded: new Date("2026-11-01T12:00:00Z"), contentType });
  }
  private meta(key: string): BucketObject | null {
    const o = this.objects.get(key);
    if (!o) return null;
    return {
      size: o.bytes.length, httpEtag: o.etag, uploaded: o.uploaded,
      writeHttpMetadata(h: Headers) { if (o.contentType) h.set("Content-Type", o.contentType); },
    };
  }
  async head(key: string) { return this.meta(key); }
  async get(key: string, options: { range?: { offset: number; length: number }; onlyIf?: Headers }): Promise<BucketObjectBody | BucketObject | null> {
    this.gets.push({ key, range: options.range });
    const meta = this.meta(key);
    if (!meta) return null;
    const ifMatch = options.onlyIf?.get("if-match"), ifNoneMatch = options.onlyIf?.get("if-none-match");
    if ((ifMatch && ifMatch !== meta.httpEtag) || (ifNoneMatch && ifNoneMatch === meta.httpEtag)) return meta;
    const bytes = this.objects.get(key)!.bytes;
    const part = options.range ? bytes.slice(options.range.offset, options.range.offset + options.range.length) : bytes.slice();
    const body = new ReadableStream<Uint8Array>({ start(c) { c.enqueue(part); c.close(); } });
    return { ...meta, body };
  }
}

/** The logs bucket: puts and deletes in memory. */
export class MemoryLogBucket implements LogBucket {
  objects = new Map<string, { bytes: Uint8Array; contentType: string; sha256: string }>();
  async put(key: string, value: ArrayBuffer | Uint8Array, options: { httpMetadata: { contentType: string }; sha256: string }) {
    this.objects.set(key, { bytes: new Uint8Array(value), contentType: options.httpMetadata.contentType, sha256: options.sha256 });
  }
  async delete(keys: string[]) { for (const k of keys) this.objects.delete(k); }
}

export interface World {
  deps: Deps;
  sql: ReturnType<typeof sqliteSql>;
  limits: { auth: FakeLimiter; installs: FakeLimiter; reports: FakeLimiter; attest: FakeLimiter; downloads: FakeLimiter; logs: FakeLimiter };
  data: MemoryBucket;
  logs: MemoryLogBucket;
  clock: { t: Date; now(): Date };
  call(method: string, path: string, opts?: { token?: string; body?: unknown; raw?: string | Uint8Array; ip?: string; headers?: Record<string, string> }): Promise<Response>;
  mint(): Promise<{ installID: string; token: string }>;
  send(token: string, report?: unknown): Promise<Response>;
  rows(table: string): Record<string, unknown>[];
}

export function world(vars: Partial<Vars> = {}, now = "2026-10-31T21:34:00Z", attest: Partial<AttestConfig> = {}): World {
  const sql = sqliteSql();
  const limits = { auth: new FakeLimiter(), installs: new FakeLimiter(), reports: new FakeLimiter(), attest: new FakeLimiter(), downloads: new FakeLimiter(), logs: new FakeLimiter() };
  const data = new MemoryBucket();
  const logs = new MemoryLogBucket();
  const clock = { t: new Date(now), now() { return new Date(this.t); } };
  const deps: Deps = {
    store: new Store(sql),
    limits,
    clock,
    vars: { retentionDays: 90, reportsPerDay: 5, installsPerHour: 60, attestsPerHour: 60, logRetentionDays: 30, logBytesPerDay: 300_000_000, ...vars },
    data,
    logs,
    attest: { appId: TEST_APP_ID, allowDevelopment: false, rootPEM: APPLE_APP_ATTEST_ROOT, tokenSecret: TEST_TOKEN_SECRET, ...attest },
  };
  const w: World = {
    deps, sql, limits, data, logs, clock,
    call(method, path, opts = {}) {
      const headers: Record<string, string> = { "cf-connecting-ip": opts.ip ?? IP, ...opts.headers };
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
    rows(table) {
      return sql.db.prepare(`SELECT * FROM ${table}`).all() as Record<string, unknown>[];
    },
  };
  return w;
}
