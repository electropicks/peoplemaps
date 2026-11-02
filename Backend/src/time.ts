// Hour-precision timestamps, the only precision stored (Docs/REPORTS.md 5.1).
const HOUR = 3_600_000, DAY = 86_400_000;

export function iso(d: Date): string { return d.toISOString().slice(0, 19) + "Z"; }
export function hour(d: Date): string { return iso(new Date(Math.floor(d.getTime() / HOUR) * HOUR)); }
export function addDays(d: Date, days: number): Date { return new Date(d.getTime() + days * DAY); }
export function secondsToMidnightUTC(d: Date): number { return Math.ceil((Math.floor(d.getTime() / DAY) * DAY + DAY - d.getTime()) / 1000); }
export function secondsToNextHour(d: Date): number { return Math.ceil((Math.floor(d.getTime() / HOUR) * HOUR + HOUR - d.getTime()) / 1000); }
