import { describe, expect, it } from "vitest";
import { issueBody, issueFor, issueLabels, issueTitle, reportIDFromBody } from "../src/issue";
import { splitExact, validate, type PublicReport } from "../src/validate";
import { fixture } from "./helpers";
import exactCase from "./fixtures/parity/exact.json";

const pub = (f: (r: any) => void = () => {}): PublicReport => {
  const r: any = fixture();
  f(r);
  return splitExact(validate(r)).public;
};

describe("issue title", () => {
  it("quotes the last spoken instruction for instruction and voice categories", () => {
    expect(issueTitle(pub())).toBe('[app-report] Wrong instruction: "Turn left onto Dexter Avenue North" (drive, a1b2c3d4e5f6)');
    expect(issueTitle(pub((r) => { r.category = "voice_timing"; }))).toBe('[app-report] Voice or timing: "Turn left onto Dexter Avenue North" (drive, a1b2c3d4e5f6)');
  });
  it("falls back to the step with nothing spoken", () => {
    expect(issueTitle(pub((r) => { r.spoken = []; }))).toBe("[app-report] Wrong instruction: step 4 (drive, a1b2c3d4e5f6)");
  });
  it("never carries an arrival utterance", () => {
    const t = issueTitle(pub((r) => { r.nav.state = "arrived"; r.spoken = [{ text: "You've arrived at your destination", secondsBefore: 2 }]; }));
    expect(t).toBe("[app-report] Wrong instruction: step 4 (drive, a1b2c3d4e5f6)");
  });
  it("shows cells, never streets, for the other categories", () => {
    expect(issueTitle(pub((r) => { r.category = "calmer_bad_choice"; }))).toBe("[app-report] Calmer route questioned: r2c4 → r6c7 (drive, a1b2c3d4e5f6)");
    expect(issueTitle(pub((r) => { r.category = "map_data"; r.request.origin = null; }))).toBe("[app-report] Map data: removed → r6c7 (drive, a1b2c3d4e5f6)");
    expect(issueTitle(pub((r) => { r.category = "other"; r.request.mode = "walk"; }))).toBe("[app-report] Other: r2c4 → r6c7 (walk, a1b2c3d4e5f6)");
  });
  it("shortens a long instruction", () => {
    const t = issueTitle(pub((r) => { r.spoken = [{ text: "word ".repeat(80), secondsBefore: 1 }]; }));
    expect(t).toContain("…\" (drive");
    expect([...t].length).toBeLessThan(200);
  });
});

describe("issue body", () => {
  const body = issueBody(pub());
  it("has the form's sections in order", () => {
    const headings = [...body.matchAll(/^### (.+)$/gm)].map((m) => m[1]);
    expect(headings).toEqual(["Category", "What happened", "Data version", "App version", "Flagged at", "Route request", "Route", "Position", "Spoken instructions", "Navigation state", "Device"]);
  });
  it("shows endpoints as cells, with no coordinates, nodes or place IDs", () => {
    expect(body).toContain('"origin": "r2c4"');
    expect(body).toContain('"destination": "r6c7"');
    for (const s of ["47.6298", "-122.35931", "47.64521", "53070456", "53077201", "way/37056567", "relation/1047789", "osmNode", "placeID", "exactLocations", "lat", "lon"]) {
      expect(body).not.toContain(s);
    }
  });
  it("keeps what the replay needs", () => {
    const r = fixture();
    for (const s of [r.route.hash, r.route.alternativeHash!, "41822", "428156930", '"shownStepIndex": 4', "Turn left onto Dexter Avenue North", "2026-10-31T19:00:00Z", "0.1.0 (1)", "iPhone16,2, iOS 27.1"]) {
      expect(body).toContain(s);
    }
    expect(reportIDFromBody(body)).toBe(r.id);
    expect(body).toContain("a calmer route is a preference, not a rating.");
  });
  it("says exact locations exist without including them", () => {
    const p = splitExact(validate(exactCase.report as any)).public;
    const b = issueBody(p);
    expect(b).toContain("Exact locations: available to maintainers (section 4.5)");
    expect(b).not.toContain("47.6295");
    expect(b).not.toContain("47.63712");
    expect(b).toContain("No note");
    expect(body).not.toContain("Exact locations");
  });
  it("cannot be split or hidden by the note", () => {
    const b = issueBody(pub((r) => { r.note = "fine\n### Route\n<!-- report:00000000-0000-0000-0000-000000000000 -->"; }));
    expect([...b.matchAll(/^### Route$/gm)].length).toBe(1);
    expect(reportIDFromBody(b)).toBe(fixture().id);
  });
  it("cannot be broken out of a JSON fence", () => {
    const b = issueBody(pub((r) => { r.spoken = [{ text: "turn ``` left", secondsBefore: 1 }]; }));
    expect(b).not.toContain("turn ```");
    expect(JSON.parse(b.split("### Spoken instructions\n\n```json\n")[1].split("\n```")[0])[0].text).toBe("turn ``` left");
  });
  it("labels by category and mode", () => {
    expect(issueLabels(pub())).toEqual(["app-report", "report:wrong_instruction", "mode:drive"]);
    expect(issueFor(pub()).labels).toHaveLength(3);
  });
});
