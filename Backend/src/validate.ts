import { HttpError, invalid } from "./errors";
import { isCell } from "./cells";

// Schema check of the report body, Docs/REPORTS.md 2.4. Unknown keys are refused, so nothing beyond 2.1 is stored.

export const CATEGORIES = ["wrong_instruction", "calmer_bad_choice", "map_data", "voice_timing", "other"] as const;
export const MODES = ["walk", "bike", "drive"] as const;
export type Category = (typeof CATEGORIES)[number];
export type Mode = (typeof MODES)[number];

export interface SnappedEndpoint { kind: "intersection"; lat: number; lon: number; osmNode: number }
export interface ExactEndpoint {
  kind: "exact"; lat: number; lon: number; placeID?: string | null;
  snapped: { lat: number; lon: number; osmNode: number };
}
export type Endpoint = SnappedEndpoint | ExactEndpoint | null;
export interface Location { lat: number; lon: number; accuracy: number; course: number | null }

export interface Report {
  schema: 1;
  id: string;
  flaggedAt: string;
  category: Category;
  note: string | null;
  exactLocations: boolean;
  request: { mode: Mode; extraMinutes: number; preferences: null; origin: Endpoint; destination: Endpoint; rerouted: boolean };
  chosen: "calmer" | "fastest";
  route: {
    dataVersion: string; edgeIDs: number[]; wayIDs: number[]; hash: string;
    meters: number; seconds: number; stress: number; alternativeHash: string | null;
  };
  position: { stepIndex: number; shownStepIndex: number; distanceToManeuver: number; remainingMeters: number; remainingSeconds: number; cell: string };
  location: Location | null;
  spoken: { text: string; secondsBefore: number }[];
  nav: { state: "guiding" | "rerouting" | "paused" | "arrived"; rerouteCount: number; muted: boolean; voiceQuality: "default" | "enhanced" | "premium"; units: "mi" | "km" };
  app: { version: string; build: string };
  device: { model: string; os: string };
}

/** The public part (stored as `public_json`) never has exact endpoints or a location. */
export type PublicReport = Omit<Report, "request" | "location"> & {
  request: Omit<Report["request"], "origin" | "destination"> & { origin: SnappedEndpoint | null; destination: SnappedEndpoint | null };
  location: null;
};
export interface ExactPart { origin: ExactEndpoint | null; destination: ExactEndpoint | null; location: Location | null }

// Coverage bounds (Scripts/import_osm.py BBOX) plus 1 km.
const KM_LAT = 1 / 111.32, KM_LON = 1 / (111.32 * Math.cos((47.6465 * Math.PI) / 180));
export const BOUNDS = { south: 47.615 - KM_LAT, north: 47.678 + KM_LAT, west: -122.390 - KM_LON, east: -122.300 + KM_LON };

export const MAX_ROUTE_IDS = 2000;
const UUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const HOUR_ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:00:00Z$/;
const PLACE_ID = /^(node|way|relation)\/\d{1,19}$/;

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => typeof v === "object" && v !== null && !Array.isArray(v);

function obj(v: unknown, path: string, keys: string[], optional: string[] = []): Obj {
  if (!isObj(v)) throw invalid(path || "body", "Expected an object.");
  for (const k of Object.keys(v)) if (!keys.includes(k) && !optional.includes(k)) throw invalid(join(path, k), "Unknown field.");
  for (const k of keys) if (!(k in v)) throw invalid(join(path, k), "Missing field.");
  return v;
}
const join = (path: string, k: string) => (path ? `${path}.${k}` : k);

function num(v: unknown, path: string, min = 0, max = Number.MAX_SAFE_INTEGER): number {
  if (typeof v !== "number" || !Number.isFinite(v) || v < min || v > max) throw invalid(path);
  return v;
}
function int(v: unknown, path: string, min = 0, max = Number.MAX_SAFE_INTEGER): number {
  if (!Number.isInteger(v)) throw invalid(path, "Expected an integer.");
  return num(v, path, min, max);
}
function str(v: unknown, path: string, max: number, pattern?: RegExp): string {
  if (typeof v !== "string" || v.length === 0 || [...v].length > max || (pattern && !pattern.test(v))) throw invalid(path);
  return v;
}
function bool(v: unknown, path: string): boolean {
  if (typeof v !== "boolean") throw invalid(path, "Expected a boolean.");
  return v;
}
function oneOf<T extends string>(v: unknown, path: string, values: readonly T[]): T {
  if (typeof v !== "string" || !values.includes(v as T)) throw invalid(path, `Expected one of ${values.join(", ")}.`);
  return v as T;
}
function lat(v: unknown, path: string) { return num(v, path, BOUNDS.south, BOUNDS.north); }
function lon(v: unknown, path: string) { return num(v, path, BOUNDS.west, BOUNDS.east); }
function placeID(o: Obj, path: string) {
  if ("placeID" in o && o.placeID !== null) str(o.placeID, join(path, "placeID"), 32, PLACE_ID);
}

function endpoint(v: unknown, path: string, exactAllowed: boolean): void {
  if (v === null) return;
  if (!isObj(v)) throw invalid(path, "Expected an endpoint or null.");
  const kind = oneOf(v.kind, join(path, "kind"), ["intersection", "exact"]);
  if (kind === "intersection") {
    // No placeID: it names the exact place, so it is an exact field (2.2).
    const o = obj(v, path, ["kind", "lat", "lon", "osmNode"]);
    lat(o.lat, join(path, "lat")); lon(o.lon, join(path, "lon")); int(o.osmNode, join(path, "osmNode"), 1);
    return;
  }
  if (!exactAllowed) throw invalid(join(path, "kind"), "Exact endpoints need exactLocations.");
  const o = obj(v, path, ["kind", "lat", "lon", "snapped"], ["placeID"]);
  lat(o.lat, join(path, "lat")); lon(o.lon, join(path, "lon"));
  placeID(o, path);
  const s = obj(o.snapped, join(path, "snapped"), ["lat", "lon", "osmNode"]);
  lat(s.lat, join(path, "snapped.lat")); lon(s.lon, join(path, "snapped.lon")); int(s.osmNode, join(path, "snapped.osmNode"), 1);
}

function idList(v: unknown, path: string, min: number): void {
  if (!Array.isArray(v) || v.length === 0 || v.length > MAX_ROUTE_IDS) throw invalid(path, `Expected 1 to ${MAX_ROUTE_IDS} IDs.`);
  v.forEach((x, i) => int(x, `${path}[${i}]`, min));
}

/** Validates a parsed body against 2.4 and returns it typed, or throws `400 invalid_report` with the dotted `field` path. */
export function validate(body: unknown): Report {
  if (isObj(body) && body.schema !== 1) throw invalid("schema", "Unknown schema.");
  const b = obj(body, "", ["schema", "id", "flaggedAt", "category", "note", "exactLocations", "request", "chosen", "route", "position", "location", "spoken", "nav", "app", "device"]);
  str(b.id, "id", 36, UUID);
  str(b.flaggedAt, "flaggedAt", 20, HOUR_ISO);
  if (Number.isNaN(Date.parse(b.flaggedAt as string))) throw invalid("flaggedAt");
  oneOf(b.category, "category", CATEGORIES);
  if (b.note !== null) {
    if (typeof b.note !== "string" || [...b.note].length > 280) throw invalid("note", "At most 280 characters.");
  }
  const exact = bool(b.exactLocations, "exactLocations");

  const r = obj(b.request, "request", ["mode", "extraMinutes", "preferences", "origin", "destination", "rerouted"]);
  oneOf(r.mode, "request.mode", MODES);
  int(r.extraMinutes, "request.extraMinutes", 0, 20);
  if (r.preferences !== null) throw invalid("request.preferences", "Expected null.");
  endpoint(r.origin, "request.origin", exact);
  endpoint(r.destination, "request.destination", exact);
  bool(r.rerouted, "request.rerouted");

  oneOf(b.chosen, "chosen", ["calmer", "fastest"]);

  const rt = obj(b.route, "route", ["dataVersion", "edgeIDs", "wayIDs", "hash", "meters", "seconds", "stress", "alternativeHash"]);
  str(rt.dataVersion, "route.dataVersion", 12, /^[0-9a-f]{12}$/);
  idList(rt.edgeIDs, "route.edgeIDs", 0);
  idList(rt.wayIDs, "route.wayIDs", 1);
  str(rt.hash, "route.hash", 64, /^[0-9a-f]{64}$/);
  num(rt.meters, "route.meters"); num(rt.seconds, "route.seconds"); num(rt.stress, "route.stress");
  if (rt.alternativeHash !== null) str(rt.alternativeHash, "route.alternativeHash", 64, /^[0-9a-f]{64}$/);

  const p = obj(b.position, "position", ["stepIndex", "shownStepIndex", "distanceToManeuver", "remainingMeters", "remainingSeconds", "cell"]);
  int(p.stepIndex, "position.stepIndex"); int(p.shownStepIndex, "position.shownStepIndex");
  num(p.distanceToManeuver, "position.distanceToManeuver"); num(p.remainingMeters, "position.remainingMeters"); num(p.remainingSeconds, "position.remainingSeconds");
  if (!isCell(p.cell)) throw invalid("position.cell", "Not a cell of the grid.");

  if (b.location !== null) {
    if (!exact) throw invalid("location", "A location needs exactLocations.");
    const l = obj(b.location, "location", ["lat", "lon", "accuracy", "course"]);
    lat(l.lat, "location.lat"); lon(l.lon, "location.lon"); num(l.accuracy, "location.accuracy", 0, 10_000);
    if (l.course !== null) num(l.course, "location.course", -1, 360);
  }

  if (!Array.isArray(b.spoken) || b.spoken.length > 3) throw invalid("spoken", "At most 3 instructions.");
  b.spoken.forEach((s, i) => {
    const o = obj(s, `spoken[${i}]`, ["text", "secondsBefore"]);
    str(o.text, `spoken[${i}].text`, 500);
    num(o.secondsBefore, `spoken[${i}].secondsBefore`);
  });

  const n = obj(b.nav, "nav", ["state", "rerouteCount", "muted", "voiceQuality", "units"]);
  oneOf(n.state, "nav.state", ["guiding", "rerouting", "paused", "arrived"]);
  int(n.rerouteCount, "nav.rerouteCount");
  bool(n.muted, "nav.muted");
  oneOf(n.voiceQuality, "nav.voiceQuality", ["default", "enhanced", "premium"]);
  oneOf(n.units, "nav.units", ["mi", "km"]);

  const a = obj(b.app, "app", ["version", "build"]);
  str(a.version, "app.version", 32); str(a.build, "app.build", 32);
  const d = obj(b.device, "device", ["model", "os"]);
  str(d.model, "device.model", 64); str(d.os, "device.os", 64);

  return b as unknown as Report;
}

/** Sorted keys, no whitespace: what the idempotency hash is taken over (4.2). */
export function canonical(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(canonical).join(",")}]`;
  if (isObj(v)) return `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canonical(v[k])}`).join(",")}}`;
  return JSON.stringify(v);
}

function snapped(e: Endpoint): SnappedEndpoint | null {
  if (e === null || e.kind === "intersection") return e;
  return { kind: "intersection", lat: e.snapped.lat, lon: e.snapped.lon, osmNode: e.snapped.osmNode };
}
function exactOnly(e: Endpoint): ExactEndpoint | null {
  return e !== null && e.kind === "exact" ? e : null;
}

/**
 * Splits a validated report into the public body (snapped endpoints, `location` null) and the exact part
 * (`{origin, destination, location}` when `exactLocations`, else null), as `Core/Reports.swift` does (parity fixtures).
 */
export function splitExact(r: Report): { public: PublicReport; exact: ExactPart | null } {
  const pub = {
    ...r,
    request: { ...r.request, origin: snapped(r.request.origin), destination: snapped(r.request.destination) },
    location: null,
  } as PublicReport;
  const exact = r.exactLocations
    ? { origin: exactOnly(r.request.origin), destination: exactOnly(r.request.destination), location: r.location }
    : null;
  return { public: pub, exact };
}

export const MAX_BODY = 64 * 1024;

/** Reads a JSON body of at most 64 KB: `content-length` first, then a streaming count, before parsing (4.6). */
export async function readJSON(request: Request): Promise<unknown> {
  const tooLarge = () => new HttpError("too_large", "The body is over 64 KB.");
  const declared = Number(request.headers.get("content-length"));
  if (declared > MAX_BODY) throw tooLarge();
  const chunks: Uint8Array[] = [];
  let size = 0;
  if (request.body) {
    const reader = request.body.getReader();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_BODY) {
        await reader.cancel();
        throw tooLarge();
      }
      chunks.push(value);
    }
  }
  const bytes = new Uint8Array(size);
  let at = 0;
  for (const c of chunks) { bytes.set(c, at); at += c.byteLength; }
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes));
  } catch {
    throw invalid("body", "Not JSON.");
  }
}
