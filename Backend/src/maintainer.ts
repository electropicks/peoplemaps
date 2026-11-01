import type { Deps } from "./deps";
import { HttpError, json } from "./errors";
import { GitHubError } from "./github";
import { sha256Hex } from "./installs";
import { issueFor, reportIDFromBody } from "./issue";
import { limitAuth } from "./ratelimit";
import { fileIssue } from "./reports";
import type { ReportRow } from "./store";
import { hour } from "./time";
import type { PublicReport } from "./validate";

// Maintainer routes: exact fields by issue number (Docs/REPORTS.md 4.5) and approval (6.1).

const ALLOWED = new Set(["write", "maintain", "admin"]);
const unavailable = () => new HttpError("github_unavailable", "GitHub could not be reached. Try again later.");

/** The maintainer's own GitHub token, checked for write, maintain or admin, then dropped. Returns the login. */
async function maintainer(request: Request, deps: Deps): Promise<string> {
  const m = /^Bearer (\S{1,255})$/.exec(request.headers.get("authorization") ?? "");
  if (!m || m[1].startsWith("pm_")) throw new HttpError("unauthorized", "A GitHub token is needed.");
  await limitAuth(deps, await sha256Hex(m[1]));
  let login: string | null, permission: string;
  try {
    login = await deps.github.loginForToken(m[1]);
    if (login === null) throw new HttpError("unauthorized", "GitHub refused the token.");
    permission = await deps.github.permission(login);
  } catch (e) {
    if (e instanceof GitHubError) throw unavailable();
    throw e;
  }
  if (!ALLOWED.has(permission)) throw new HttpError("forbidden", "Needs write, maintain or admin on the repository.");
  return login;
}

export async function exactForIssue(request: Request, deps: Deps, number: number): Promise<Response> {
  const login = await maintainer(request, deps);
  let row = await deps.store.reportByIssueNumber(number);
  if (!row) {
    // The marker in the body finds the row if the issue number was lost from the database (6).
    let body: string | null;
    try {
      body = await deps.github.issueBody(number);
    } catch {
      throw unavailable();
    }
    const id = body ? reportIDFromBody(body) : null;
    row = id ? await deps.store.reportById(id) : null;
  }
  if (!row) throw new HttpError("not_found", "No stored report for that issue.");
  await deps.store.insertMaintainerRead(number, login, hour(deps.clock.now()));
  return json(200, {
    id: row.id,
    receivedAt: row.received_at,
    report: JSON.parse(row.public_json),
    exact: row.exact_json ? JSON.parse(row.exact_json) : null,
  });
}

export async function listHeld(request: Request, deps: Deps): Promise<Response> {
  await maintainer(request, deps);
  const rows = await deps.store.heldReports();
  return json(200, {
    reports: rows.map((r) => {
      const { title, body } = issueFor(JSON.parse(r.public_json) as PublicReport);
      return { id: r.id, receivedAt: r.received_at, category: r.category, issuePreview: { title, body } };
    }),
  });
}

async function heldRow(deps: Deps, id: string): Promise<ReportRow> {
  const row = await deps.store.reportById(id);
  if (!row) throw new HttpError("not_found", "No such report.");
  if (row.issue_state !== "held") throw new HttpError("conflict", "The report is not held.");
  return row;
}

export async function approve(request: Request, deps: Deps, id: string): Promise<Response> {
  const login = await maintainer(request, deps);
  await heldRow(deps, id);
  if (!(await deps.store.review(id, "pending", login))) throw new HttpError("conflict", "The report is not held.");
  await fileIssue(id, deps);
  const row = (await deps.store.reportById(id))!;
  const out: Record<string, unknown> = { issueState: row.issue_state };
  if (row.issue_number !== null) out.issue = { number: row.issue_number, url: row.issue_url };
  return json(200, out);
}

export async function reject(request: Request, deps: Deps, id: string): Promise<Response> {
  const login = await maintainer(request, deps);
  await heldRow(deps, id);
  if (!(await deps.store.review(id, "rejected", login))) throw new HttpError("conflict", "The report is not held.");
  return json(200, { issueState: "rejected" });
}

/** GET /maintainer: a static page with no data in it. The token stays in sessionStorage; previews come from the API. */
export function maintainerPage(): Response {
  return new Response(PAGE, {
    status: 200,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "Content-Security-Policy": "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'",
      "Referrer-Policy": "no-referrer",
    },
  });
}

const PAGE = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Held reports</title>
<style>
  body { font: 15px/1.45 system-ui, sans-serif; margin: 0 auto; max-width: 860px; padding: 16px; }
  pre { white-space: pre-wrap; background: #f4f4f4; padding: 12px; overflow-wrap: anywhere; }
  article { border-top: 1px solid #ccc; padding: 12px 0; }
  button { font: inherit; padding: 6px 14px; margin-right: 8px; }
  @media (prefers-color-scheme: dark) { body { background: #111; color: #eee; } pre { background: #222; } }
</style>
</head>
<body>
<h1>Held reports</h1>
<p id="status"></p>
<form id="login" hidden>
  <label>GitHub token <input id="token" type="password" autocomplete="off" required></label>
  <button>Use token</button>
</form>
<div id="list"></div>
<script>
const $ = (id) => document.getElementById(id);
const token = () => sessionStorage.getItem("gh");
const status = (t) => { $("status").textContent = t; };
async function call(method, path) {
  const res = await fetch(path, { method, headers: { Authorization: "Bearer " + token() } });
  const body = await res.json().catch(() => ({}));
  if (res.status === 401) { sessionStorage.removeItem("gh"); $("login").hidden = false; }
  if (!res.ok) throw new Error(body.message || res.status);
  return body;
}
async function load() {
  if (!token()) { $("login").hidden = false; return; }
  $("login").hidden = true;
  status("Loading…");
  try {
    const { reports } = await call("GET", "/v1/maintainer/held");
    $("list").replaceChildren(...reports.map(row));
    status(reports.length ? reports.length + " held, oldest first." : "Nothing held.");
  } catch (e) { status("Could not load: " + e.message); }
}
function row(r) {
  const a = document.createElement("article");
  const h = document.createElement("h2"); h.textContent = r.issuePreview.title;
  const meta = document.createElement("p"); meta.textContent = r.category + ", received " + r.receivedAt;
  const pre = document.createElement("pre"); pre.textContent = r.issuePreview.body;
  const ok = document.createElement("button"); ok.textContent = "Approve";
  const no = document.createElement("button"); no.textContent = "Reject";
  const act = (verb) => async () => {
    ok.disabled = no.disabled = true;
    try { const out = await call("POST", "/v1/maintainer/reports/" + encodeURIComponent(r.id) + "/" + verb); meta.textContent = "Now " + out.issueState + (out.issue ? ", issue #" + out.issue.number : ""); }
    catch (e) { meta.textContent = "Failed: " + e.message; ok.disabled = no.disabled = false; }
  };
  ok.onclick = act("approve"); no.onclick = act("reject");
  a.append(h, meta, pre, ok, no);
  return a;
}
$("login").onsubmit = (e) => { e.preventDefault(); sessionStorage.setItem("gh", $("token").value); $("token").value = ""; load(); };
load();
</script>
</body>
</html>
`;
