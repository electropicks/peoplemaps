import { describe, expect, it } from "vitest";
import { retryIssues } from "../src/retention";
import { fixture, world } from "./helpers";
import exactCase from "./fixtures/parity/exact.json";

const ID = fixture().id;

async function heldWorld(vars = {}) {
  const w = world(vars);
  const sender = await w.mint();
  await w.send(sender.token);
  return { w, sender };
}

describe("approval (6.1)", () => {
  it("lists held reports oldest first with the exact issue preview", async () => {
    const { w, sender } = await heldWorld();
    w.clock.t = new Date("2026-10-31T23:10:00Z");
    await w.send(sender.token, { ...fixture(), id: "00000000-0000-4000-8000-000000000002", category: "calmer_bad_choice" });
    const res = await w.call("GET", "/v1/maintainer/held", { token: w.maintainer() });
    const { reports } = (await res.json()) as any;
    expect(reports.map((r: any) => r.id)).toEqual([ID, "00000000-0000-4000-8000-000000000002"]);
    expect(reports[0].issuePreview.title).toBe('[app-report] Wrong instruction: "Turn left onto Dexter Avenue North" (drive, a1b2c3d4e5f6)');
    expect(reports[0].issuePreview.body).toContain(`<!-- report:${ID} -->`);
    expect(Object.keys(reports[0]).sort()).toEqual(["category", "id", "issuePreview", "receivedAt"]);
  });

  it("approve files the issue and records the reviewer", async () => {
    const { w } = await heldWorld();
    const res = await w.call("POST", `/v1/maintainer/reports/${ID}/approve`, { token: w.maintainer("alex", "maintain") });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ issueState: "opened", issue: { number: 100, url: "https://github.com/electropicks/peoplemaps/issues/100" } });
    expect(w.rows("reports")[0]).toMatchObject({ issue_state: "opened", reviewed_by: "alex", issue_number: 100, issue_node_id: "I_node100", issue_filed_at: "2026-10-31T21:00:00Z" });
    const issue = w.gh.issues.get(100)!;
    expect(issue.title).toContain("[app-report] Wrong instruction");
    expect(issue.body).not.toContain("53070456");
    expect((await w.call("POST", `/v1/maintainer/reports/${ID}/approve`, { token: w.maintainer("alex", "maintain") })).status).toBe(409);
  });

  it("reject never files, and the sender sees it", async () => {
    const { w, sender } = await heldWorld();
    const res = await w.call("POST", `/v1/maintainer/reports/${ID}/reject`, { token: w.maintainer() });
    expect(await res.json()).toEqual({ issueState: "rejected" });
    expect(await retryIssues(w.deps)).toEqual({ opened: 0, pending: 0, failed: 0 });
    expect(w.gh.ownCalls().filter((r) => r.url.endsWith("/issues"))).toHaveLength(0);
    const mine = await (await w.call("GET", `/v1/reports/${ID}`, { token: sender.token })).json();
    expect(mine).toMatchObject({ issueState: "rejected", issue: null });
    expect((await w.call("POST", `/v1/maintainer/reports/${ID}/approve`, { token: w.maintainer() })).status).toBe(409);
  });

  it("needs write, maintain or admin", async () => {
    const { w } = await heldWorld();
    for (const permission of ["read", "triage"]) {
      const res = await w.call("POST", `/v1/maintainer/reports/${ID}/approve`, { token: w.maintainer(`u${permission}`, permission) });
      expect(res.status).toBe(403);
      expect(await res.json()).toMatchObject({ error: "forbidden" });
    }
    w.gh.users.set("ghp_stranger", "stranger");
    expect((await w.call("GET", "/v1/maintainer/held", { token: "ghp_stranger" })).status).toBe(403);
    expect((await w.call("GET", "/v1/maintainer/held", { token: "ghp_unknown" })).status).toBe(401);
    expect((await w.call("GET", "/v1/maintainer/held")).status).toBe(401);
    const { token } = await w.mint();
    expect((await w.call("GET", "/v1/maintainer/held", { token })).status).toBe(401);
    expect(w.rows("reports")[0].issue_state).toBe("held");
    expect(w.gh.issues.size).toBe(0);
  });

  it("answers 503 when GitHub cannot check the maintainer", async () => {
    const { w } = await heldWorld();
    const token = w.maintainer();
    w.gh.down = 502;
    const res = await w.call("POST", `/v1/maintainer/reports/${ID}/approve`, { token });
    expect(res.status).toBe(503);
    expect(await res.json()).toMatchObject({ error: "github_unavailable" });
  });

  it("over the daily cap or with GitHub down, approval leaves it pending for the cron", async () => {
    const { w } = await heldWorld({ issueDailyCap: 0 });
    const res = await w.call("POST", `/v1/maintainer/reports/${ID}/approve`, { token: w.maintainer() });
    expect(await res.json()).toEqual({ issueState: "pending" });
    w.deps.vars.issueDailyCap = 5;
    w.gh.createStatus = 503;
    expect(await retryIssues(w.deps)).toEqual({ opened: 0, pending: 1, failed: 0 });
    w.gh.createStatus = 201;
    expect(await retryIssues(w.deps)).toEqual({ opened: 1, pending: 0, failed: 0 });
  });

  it("404 for an unknown report", async () => {
    const { w } = await heldWorld();
    expect((await w.call("POST", "/v1/maintainer/reports/00000000-0000-4000-8000-00000000000f/reject", { token: w.maintainer() })).status).toBe(404);
  });

  it("serves a static page with no data in it", async () => {
    const { w } = await heldWorld();
    const res = await w.call("GET", "/maintainer");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");
    expect(res.headers.get("content-security-policy")).toContain("default-src 'none'");
    const html = await res.text();
    expect(html).not.toContain(ID);
    expect(html).toContain("sessionStorage");
  });
});

describe("GET /v1/maintainer/issues/{n}/report (4.5)", () => {
  async function filedExact() {
    const w = world({ holdForApproval: false });
    const { token } = await w.mint();
    await w.send(token, exactCase.report);
    return w;
  }

  it("returns the public body and the exact part, and leaves an audit row", async () => {
    const w = await filedExact();
    const token = w.maintainer("alex", "write");
    const res = await w.call("GET", "/v1/maintainer/issues/100/report", { token });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ id: exactCase.report.id, receivedAt: "2026-10-31T21:00:00Z", report: exactCase.public, exact: exactCase.exact });
    expect(w.rows("maintainer_reads")).toEqual([{ issue_number: 100, login: "alex", read_at: "2026-10-31T21:00:00Z" }]);
    expect(JSON.stringify(w.rows("maintainer_reads"))).not.toContain(token);
  });

  it("is refused without permission and leaves no audit row", async () => {
    const w = await filedExact();
    expect((await w.call("GET", "/v1/maintainer/issues/100/report", { token: w.maintainer("reader", "read") })).status).toBe(403);
    expect(w.rows("maintainer_reads")).toHaveLength(0);
  });

  it("finds the row from the issue's marker when the number is not stored", async () => {
    const w = await filedExact();
    w.sql.db.exec("UPDATE reports SET issue_number = NULL");
    const res = await w.call("GET", "/v1/maintainer/issues/100/report", { token: w.maintainer() });
    expect(res.status).toBe(200);
    expect(((await res.json()) as any).id).toBe(exactCase.report.id);
    expect((await w.call("GET", "/v1/maintainer/issues/555/report", { token: w.maintainer() })).status).toBe(404);
  });
});
