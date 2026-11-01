import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { HttpError } from "../src/errors";
import { canonical, MAX_BODY, readJSON, splitExact, validate } from "../src/validate";
import { fixture } from "./helpers";

function fieldOf(body: unknown): string | undefined {
  try {
    validate(body);
  } catch (e) {
    if (e instanceof HttpError && e.code === "invalid_report") return e.field;
    throw e;
  }
  return undefined;
}
function mutate(f: (r: any) => void) {
  const r: any = fixture();
  f(r);
  return r;
}
const exactEndpoint = { kind: "exact", lat: 47.6295, lon: -122.3599, snapped: { lat: 47.6298, lon: -122.35931, osmNode: 53070456 } };

describe("validate", () => {
  it("accepts the 2.4 example", () => {
    expect(validate(fixture()).id).toBe("6F1D2C8E-3B0A-4F0B-9C1C-2D4E5A6B7C8D");
  });

  const cases: [string, (r: any) => void][] = [
    ["schema", (r) => { r.schema = 2; }],
    ["id", (r) => { r.id = "not-a-uuid"; }],
    ["flaggedAt", (r) => { r.flaggedAt = "2026-10-31T19:12:00Z"; }],
    ["category", (r) => { r.category = "safety"; }],
    ["note", (r) => { r.note = "x".repeat(281); }],
    ["exactLocations", (r) => { r.exactLocations = "no"; }],
    ["request.mode", (r) => { r.request.mode = "fly"; }],
    ["request.extraMinutes", (r) => { r.request.extraMinutes = 21; }],
    ["request.extraMinutes", (r) => { r.request.extraMinutes = 2.5; }],
    ["request.preferences", (r) => { r.request.preferences = [1]; }],
    ["request.preferences", (r) => { r.request.preferences = { name: "Sam", address: "12 Main St" }; }],
    ["request.origin.placeID", (r) => { r.request.origin.placeID = "way/37056567"; }],
    ["request.origin.lat", (r) => { r.request.origin.lat = 47.5; }],
    ["request.origin.lon", (r) => { r.request.origin.lon = -122.1; }],
    ["request.origin.osmNode", (r) => { r.request.origin.osmNode = -1; }],
    ["request.origin.placeID", (r) => { r.request.origin.placeID = "Home"; }],
    ["request.destination.kind", (r) => { r.request.destination.kind = "address"; }],
    ["request.destination.name", (r) => { r.request.destination.name = "Home"; }],
    ["request.origin.kind", (r) => { r.request.origin = exactEndpoint; }],
    ["request.rerouted", (r) => { delete r.request.rerouted; }],
    ["chosen", (r) => { r.chosen = "safest"; }],
    ["route.dataVersion", (r) => { r.route.dataVersion = "A1B2C3D4E5F6"; }],
    ["route.edgeIDs", (r) => { r.route.edgeIDs = []; }],
    ["route.edgeIDs", (r) => { r.route.edgeIDs = Array.from({ length: 2001 }, (_, i) => i); }],
    ["route.edgeIDs[2]", (r) => { r.route.edgeIDs[2] = "9120"; }],
    ["route.wayIDs[0]", (r) => { r.route.wayIDs[0] = 0; }],
    ["route.hash", (r) => { r.route.hash = "3c5e"; }],
    ["route.meters", (r) => { r.route.meters = -1; }],
    ["route.alternativeHash", (r) => { r.route.alternativeHash = "9b02"; }],
    ["position.stepIndex", (r) => { r.position.stepIndex = -1; }],
    ["position.cell", (r) => { r.position.cell = "r50c0"; }],
    ["position.cell", (r) => { r.position.cell = "r0c27"; }],
    ["location", (r) => { r.location = { lat: 47.63, lon: -122.35, accuracy: 8, course: 71 }; }],
    ["spoken", (r) => { r.spoken = [...r.spoken, ...r.spoken]; }],
    ["spoken[1].text", (r) => { r.spoken[1].text = ""; }],
    ["spoken[0].secondsBefore", (r) => { r.spoken[0].secondsBefore = "41"; }],
    ["nav.state", (r) => { r.nav.state = "driving"; }],
    ["nav.voiceQuality", (r) => { r.nav.voiceQuality = "com.apple.voice.Ava"; }],
    ["nav.units", (r) => { r.nav.units = "ft"; }],
    ["app.version", (r) => { r.app.version = ""; }],
    ["device.model", (r) => { r.device.model = 16; }],
    ["device.name", (r) => { r.device.name = "Sam's iPhone"; }],
    ["locale", (r) => { r.locale = "en_US"; }],
  ];
  for (const [field, f] of cases) {
    it(`refuses a bad ${field}`, () => expect(fieldOf(mutate(f))).toBe(field));
  }

  it("refuses unknown schemas and non-objects", () => {
    expect(fieldOf([])).toBe("body");
    expect(fieldOf({ schema: 2 })).toBe("schema");
  });

  it("allows exact endpoints and a location only with exactLocations", () => {
    expect(fieldOf(mutate((r) => {
      r.exactLocations = true;
      r.request.origin = exactEndpoint;
      r.location = { lat: 47.63712, lon: -122.35588, accuracy: 8, course: null };
    }))).toBeUndefined();
  });

  it("keeps placeID only in the exact part", () => {
    const { public: pub, exact } = splitExact(validate(mutate((r) => {
      r.exactLocations = true;
      r.request.origin = { ...exactEndpoint, placeID: "way/37056567" };
    })));
    expect(JSON.stringify(pub)).not.toContain("placeID");
    expect(exact!.origin!.placeID).toBe("way/37056567");
  });

  it("allows removed endpoints, an empty note and a null note", () => {
    expect(fieldOf(mutate((r) => { r.request.origin = null; r.request.destination = null; r.note = null; }))).toBeUndefined();
    expect(fieldOf(mutate((r) => { r.note = ""; }))).toBeUndefined();
    expect(fieldOf(mutate((r) => { r.note = "é".repeat(280); }))).toBeUndefined();
  });

  it("accepts coordinates inside the bounds plus 1 km and refuses beyond", () => {
    expect(fieldOf(mutate((r) => { r.request.origin.lat = 47.685; }))).toBeUndefined();
    expect(fieldOf(mutate((r) => { r.request.origin.lat = 47.69; }))).toBe("request.origin.lat");
  });
});

describe("canonical", () => {
  it("sorts keys at every level and drops whitespace", () => {
    expect(canonical({ b: 1, a: { d: [1, { z: 1, y: 2 }], c: null } })).toBe('{"a":{"c":null,"d":[1,{"y":2,"z":1}]},"b":1}');
  });
  it("does not depend on key order", () => {
    const r = fixture() as any;
    const reordered = Object.fromEntries(Object.entries(r).reverse());
    expect(canonical(reordered)).toBe(canonical(r));
  });
});

// Shared with Tests/ReportsTests.swift (Docs/REPORTS.md 10, question 18): a report in, the public body and exact part out.
describe("splitExact parity fixtures", () => {
  const dir = join(import.meta.dirname, "fixtures", "parity");
  const files = readdirSync(dir).filter((f) => f.endsWith(".json"));
  it("has fixtures", () => expect(files.length).toBeGreaterThanOrEqual(3));
  for (const f of files) {
    it(f, () => {
      const c = JSON.parse(readFileSync(join(dir, f), "utf8"));
      const out = splitExact(validate(c.report));
      expect(out.public).toEqual(c.public);
      expect(out.exact).toEqual(c.exact);
      const text = JSON.stringify(out.public);
      expect(text).not.toContain('"exact"');
      expect(text).not.toContain('"snapped"');
    });
  }
});

describe("readJSON", () => {
  const req = (body: string, headers: Record<string, string> = {}) => new Request("https://x/v1/reports", { method: "POST", body, headers });
  it("refuses a declared length over 64 KB before reading", async () => {
    await expect(readJSON(req("{}", { "content-length": String(MAX_BODY + 1) }))).rejects.toMatchObject({ code: "too_large" });
  });
  it("refuses a streamed body over 64 KB", async () => {
    await expect(readJSON(req(" ".repeat(MAX_BODY + 1)))).rejects.toMatchObject({ code: "too_large" });
  });
  it("refuses a body that is not JSON", async () => {
    await expect(readJSON(req("{"))).rejects.toMatchObject({ code: "invalid_report", field: "body" });
  });
});
