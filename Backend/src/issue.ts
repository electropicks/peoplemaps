import { cellOf } from "./cells.ts";
import type { Category, PublicReport, SnappedEndpoint } from "./validate";

// Title, body and labels of the GitHub issue (Docs/REPORTS.md 6). Pure functions; `scripts/file-issue.ts` prints them.

const WORDS: Record<Category, string> = {
  wrong_instruction: "Wrong instruction",
  calmer_bad_choice: "Calmer route questioned",
  map_data: "Map data",
  voice_timing: "Voice or timing",
  other: "Other",
};

const endpointCell = (e: SnappedEndpoint | null) => (e === null ? "removed" : cellOf(e.lat, e.lon));
const oneLine = (s: string, max: number) => {
  const t = s.replace(/\s+/g, " ").trim();
  return [...t].length > max ? [...t].slice(0, max - 1).join("") + "…" : t;
};

export function issueTitle(r: PublicReport): string {
  const suffix = `(${r.request.mode}, ${r.route.dataVersion})`;
  if (r.category === "wrong_instruction" || r.category === "voice_timing") {
    const last = r.spoken.at(-1);
    const what = last && r.nav.state !== "arrived" ? `"${oneLine(last.text, 120)}"` : `step ${r.position.shownStepIndex}`;
    return `[app-report] ${WORDS[r.category]}: ${what} ${suffix}`;
  }
  return `[app-report] ${WORDS[r.category]}: ${endpointCell(r.request.origin)} → ${endpointCell(r.request.destination)} ${suffix}`;
}

export function issueLabels(r: PublicReport): string[] {
  return ["app-report", `report:${r.category}`, `mode:${r.request.mode}`];
}

// A backtick inside a JSON string is written as `, so no value can close the fence.
const fenced = (v: unknown) => "```json\n" + JSON.stringify(v, null, 2).replace(/`/g, "\\u0060") + "\n```";

// The note is the sender's own text and is kept as written, except that it cannot start a heading or open an HTML
// comment that would hide the rest of the body. The maintainer reads it before filing.
function noteText(note: string | null): string {
  if (note === null || note.trim() === "") return "No note";
  return note.replace(/<!--/g, "&lt;!--").split(/\r?\n/).map((l) => (/^\s*#/.test(l) ? "\\" + l.trimStart() : l)).join("\n");
}

/** `### <Label>` sections, one per field a replay or a reader needs. */
export function issueBody(r: PublicReport): string {
  const request = {
    mode: r.request.mode,
    extraMinutes: r.request.extraMinutes,
    preferences: r.request.preferences,
    origin: endpointCell(r.request.origin),
    destination: endpointCell(r.request.destination),
    rerouted: r.request.rerouted,
  };
  const route = {
    chosen: r.chosen,
    dataVersion: r.route.dataVersion,
    hash: r.route.hash,
    alternativeHash: r.route.alternativeHash,
    meters: r.route.meters,
    seconds: r.route.seconds,
    stress: r.route.stress,
    wayIDs: r.route.wayIDs,
    edgeIDs: r.route.edgeIDs,
  };
  const sections: [string, string][] = [
    ["Category", r.category],
    ["What happened", noteText(r.note)],
    ["Data version", r.route.dataVersion],
    ["App version", `${r.app.version} (${r.app.build})`],
    ["Flagged at", r.flaggedAt],
    ["Route request", fenced(request)],
    ["Route", fenced(route)],
    ["Position", fenced(r.position)],
    ["Spoken instructions", fenced(r.spoken)],
    ["Navigation state", fenced(r.nav)],
    ["Device", `${r.device.model}, ${r.device.os}`],
  ];
  return [
    ...sections.map(([label, value]) => `### ${label}\n\n${value}`),
    "Filed by a maintainer from a report the sender reviewed and sent. Times in the app are estimates; a calmer route is a preference, not a rating.",
  ].join("\n\n") + "\n";
}

export function issueFor(r: PublicReport) {
  return { title: issueTitle(r), body: issueBody(r), labels: issueLabels(r) };
}
