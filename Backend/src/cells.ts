// The 550 m grid of Docs/REPORTS.md 5.2, over the all-Seattle box of Docs/COVERAGE_SPIKE.md: rows 0 to 49, columns 0 to 26.
const SOUTH = 47.49, WEST = -122.44, ROW_DEG = 0.005, COL_DEG = 0.0075;
export const MAX_ROW = 49, MAX_COL = 26;

export function isCell(s: unknown): s is string {
  if (typeof s !== "string") return false;
  const m = /^r(0|[1-9]\d?)c(0|[1-9]\d?)$/.exec(s);
  return !!m && Number(m[1]) <= MAX_ROW && Number(m[2]) <= MAX_COL;
}

export function cellOf(lat: number, lon: number): string {
  const clamp = (v: number, max: number) => Math.min(max, Math.max(0, v));
  return `r${clamp(Math.floor((lat - SOUTH) / ROW_DEG), MAX_ROW)}c${clamp(Math.floor((lon - WEST) / COL_DEG), MAX_COL)}`;
}
