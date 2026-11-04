import { describe, expect, it } from "vitest";
import { base64url } from "../src/bytes";
import { issueDownloadToken } from "../src/download-token";
import { parseRange } from "../src/regions";
import { TEST_TOKEN_SECRET, world } from "./helpers";

// GET /v1/regions/{release}/{object} against the in-memory R2 stub. Real R2 is not exercised.

const RELEASE = "data-seattle-all-2026-11d";
const OBJECT = "king-county--expected__seattle-graph.bin";
const PATH = `/v1/regions/${RELEASE}/${OBJECT}`;
const FILE = Uint8Array.from({ length: 1000 }, (_, i) => i % 251);
const keyId = new Uint8Array(32).fill(9);

async function setup() {
  const w = world();
  w.data.put(`${RELEASE}/${OBJECT}`, FILE);
  w.data.put(`${RELEASE}/king-county--source__seattle-osm.json.gz`, new Uint8Array(10));
  const { token } = await issueDownloadToken(TEST_TOKEN_SECRET, keyId, w.clock.now());
  return { w, token };
}
const bytesOf = async (res: Response) => new Uint8Array(await res.arrayBuffer());

describe("GET /v1/regions/{release}/{object}", () => {
  it("streams the whole file with its length, ETag and Accept-Ranges", async () => {
    const { w, token } = await setup();
    const res = await w.call("GET", PATH, { token });
    expect(res.status).toBe(200);
    expect(res.body).toBeInstanceOf(ReadableStream);
    expect(res.headers.get("content-length")).toBe("1000");
    expect(res.headers.get("accept-ranges")).toBe("bytes");
    expect(res.headers.get("etag")).toBe('"etag1"');
    expect(res.headers.get("content-type")).toBe("application/octet-stream");
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(res.headers.get("set-cookie")).toBeNull();
    expect(await bytesOf(res)).toEqual(FILE);
    expect(w.data.gets).toEqual([{ key: `${RELEASE}/${OBJECT}`, range: undefined }]);
  });

  it("serves a range as 206 with Content-Range, and passes only that range to R2", async () => {
    const { w, token } = await setup();
    const cases: [string, number, number][] = [["bytes=0-99", 0, 100], ["bytes=900-", 900, 100], ["bytes=-10", 990, 10], ["bytes=990-5000", 990, 10]];
    for (const [range, offset, length] of cases) {
      const res = await w.call("GET", PATH, { token, headers: { range } });
      expect(res.status, range).toBe(206);
      expect(res.headers.get("content-range")).toBe(`bytes ${offset}-${offset + length - 1}/1000`);
      expect(res.headers.get("content-length")).toBe(String(length));
      expect(await bytesOf(res)).toEqual(FILE.slice(offset, offset + length));
      expect(w.data.gets.at(-1)!.range).toEqual({ offset, length });
    }
  });

  it("answers 416 for a range past the end", async () => {
    const { w, token } = await setup();
    for (const range of ["bytes=1000-", "bytes=-0"]) {
      const res = await w.call("GET", PATH, { token, headers: { range } });
      expect(res.status).toBe(416);
      expect(res.headers.get("content-range")).toBe("bytes */1000");
      expect(await res.json()).toMatchObject({ error: "range_not_satisfiable" });
    }
  });

  it("ignores a multi-range or malformed Range and sends the whole file", async () => {
    const { w, token } = await setup();
    for (const range of ["bytes=0-1,5-6", "items=0-1", "bytes=9-3"]) {
      const res = await w.call("GET", PATH, { token, headers: { range } });
      expect(res.status, range).toBe(200);
      expect(res.headers.get("content-length")).toBe("1000");
    }
  });

  it("resumes with If-Range only while the ETag still matches", async () => {
    const { w, token } = await setup();
    const same = await w.call("GET", PATH, { token, headers: { range: "bytes=500-", "if-range": '"etag1"' } });
    expect(same.status).toBe(206);
    const changed = await w.call("GET", PATH, { token, headers: { range: "bytes=500-", "if-range": '"old"' } });
    expect(changed.status).toBe(200);
    expect((await bytesOf(changed)).length).toBe(1000);
  });

  it("answers 304 to a matching If-None-Match and 412 to a failed If-Match", async () => {
    const { w, token } = await setup();
    const notModified = await w.call("GET", PATH, { token, headers: { "if-none-match": '"etag1"' } });
    expect(notModified.status).toBe(304);
    expect(notModified.headers.get("etag")).toBe('"etag1"');
    const failed = await w.call("GET", PATH, { token, headers: { "if-match": '"old"' } });
    expect(failed.status).toBe(412);
    expect(await failed.json()).toMatchObject({ error: "precondition_failed" });
  });

  it("answers 404 for a missing file, with or without a range", async () => {
    const { w, token } = await setup();
    for (const headers of [{}, { range: "bytes=0-1" }] as Record<string, string>[]) {
      const res = await w.call("GET", `/v1/regions/${RELEASE}/king-county--expected__nothing.bin`, { token, headers });
      expect(res.status).toBe(404);
      expect(await res.json()).toMatchObject({ error: "not_found" });
    }
  });

  it("serves only expected outputs of a well-formed release", async () => {
    const { w, token } = await setup();
    const bad = [
      `/v1/regions/${RELEASE}/king-county--source__seattle-osm.json.gz`,
      `/v1/regions/${RELEASE}/seattle-graph.bin`,
      `/v1/regions/${RELEASE}/King-County--expected__seattle-graph.bin`,
      `/v1/regions/${RELEASE}/king-county--expected__a%2Fb`,
      `/v1/regions/${RELEASE}/king-county--expected__`,
      `/v1/regions/data-seattle-all-26-11d/${OBJECT}`,
      `/v1/regions/source/${OBJECT}`,
      `/v1/regions/${RELEASE}/king-county--expected__seattle-graph.bin/extra`,
      `/v1/regions/${OBJECT}`,
    ];
    for (const path of bad) expect((await w.call("GET", path, { token })).status, path).toBe(404);
    expect(w.data.gets).toHaveLength(0);
  });

  it("needs a valid, unexpired download token before anything else", async () => {
    const { w, token } = await setup();
    const reportToken = "pm_" + "A".repeat(43);
    for (const t of [undefined, "nonsense", reportToken, token.slice(0, -2) + "AA"]) {
      const res = await w.call("GET", PATH, { token: t });
      expect(res.status).toBe(401);
      expect(await res.json()).toMatchObject({ error: "unauthorized" });
    }
    expect((await w.call("GET", `/v1/regions/${RELEASE}/king-county--source__x`)).status).toBe(401);
    w.clock.t = new Date("2026-11-01T21:34:00Z");
    expect((await w.call("GET", PATH, { token })).status).toBe(401);
    expect(w.data.gets).toHaveLength(0);
  });

  it("refuses every token when the secret is not set", async () => {
    const { w, token } = await setup();
    w.deps.attest.tokenSecret = "";
    expect((await w.call("GET", PATH, { token })).status).toBe(401);
  });

  it("is limited on RL_DOWNLOADS per key ID", async () => {
    const { w, token } = await setup();
    await w.call("GET", PATH, { token });
    expect(w.limits.downloads.keys).toEqual([base64url(keyId)]);
    w.limits.downloads.allow = false;
    const res = await w.call("GET", PATH, { token });
    expect(res.status).toBe(429);
    expect(res.headers.get("retry-after")).toBe("60");
  });

  it("only answers GET", async () => {
    const { w, token } = await setup();
    for (const method of ["POST", "PUT", "DELETE"]) expect((await w.call(method, PATH, { token })).status).toBe(404);
  });
});

describe("parseRange", () => {
  it("handles the single-range forms", () => {
    expect(parseRange("bytes=0-0", 5)).toEqual({ offset: 0, length: 1 });
    expect(parseRange("bytes=-99", 5)).toEqual({ offset: 0, length: 5 });
    expect(parseRange("bytes=4-", 5)).toEqual({ offset: 4, length: 1 });
    expect(parseRange("bytes=5-", 5)).toBe("unsatisfiable");
    expect(parseRange("bytes=0-", 0)).toBe("unsatisfiable");
    expect(parseRange("bytes=-", 5)).toBeNull();
    expect(parseRange(null, 5)).toBeNull();
  });
});
