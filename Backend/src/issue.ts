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

// A zero-width space after "@" and "#" stops GitHub turning sender text in a title into a mention or an issue link.
const inert = (s: string) => s.replace(/[@#]/g, "$&\u200b");

export function issueTitle(r: PublicReport): string {
  const suffix = `(${r.request.mode}, ${r.route.dataVersion})`;
  if (r.category === "wrong_instruction" || r.category === "voice_timing") {
    const last = r.spoken.at(-1);
    const what = last && r.nav.state !== "arrived" ? `"${inert(oneLine(last.text, 120))}"` : `step ${r.position.shownStepIndex}`;
    return `[app-report] ${WORDS[r.category]}: ${what} ${suffix}`;
  }
  return `[app-report] ${WORDS[r.category]}: ${endpointCell(r.request.origin)} → ${endpointCell(r.request.destination)} ${suffix}`;
}

export function issueLabels(r: PublicReport): string[] {
  return ["app-report", `report:${r.category}`, `mode:${r.request.mode}`];
}

// A backtick inside a JSON string is written as `, so no value can close the fence.
const fenced = (v: unknown) => "```json\n" + JSON.stringify(v, null, 2).replace(/`/g, "\\u0060") + "\n```";

// Sender text is shown as an indented code block, where GitHub does not mention users, link issues or render markup.
// Unlike a fence it has no closing line, so no text can end it. The maintainer reads it before filing.
function noteText(note: string | null): string {
  if (note === null || note.trim() === "") return "No note";
  return note.split(/\r\n|\r|\n/).map((l) => "    " + l).join("\n");
}

// The same for a short sender string that sits in a sentence: an inline code span whose delimiter the text cannot close.
const inline = (raw: string) => {
  const text = raw.replace(/\s+/g, " ").trim();
  const d = "`".repeat(Math.max(1, ...[...text.matchAll(/`+/g)].map((m) => m[0].length + 1)));
  return `${d} ${text} ${d}`;
};

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
    ["App version", inline(`${r.app.version} (${r.app.build})`)],
    ["Flagged at", r.flaggedAt],
    ["Route request", fenced(request)],
    ["Route", fenced(route)],
    ["Position", fenced(r.position)],
    ["Spoken instructions", fenced(r.spoken)],
    ["Navigation state", fenced(r.nav)],
    ["Device", inline(`${r.device.model}, ${r.device.os}`)],
  ];
  return [
    ...sections.map(([label, value]) => `### ${label}\n\n${value}`),
    "Filed by a maintainer from a report the sender reviewed and sent. Times in the app are estimates; a calmer route is a preference, not a rating.",
  ].join("\n\n") + "\n";
}

export function issueFor(r: PublicReport) {
  return { title: issueTitle(r), body: issueBody(r), labels: issueLabels(r) };
}
