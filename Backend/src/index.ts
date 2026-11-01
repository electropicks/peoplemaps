import type { Deps, RateLimiter } from "./deps";
import { parseVars } from "./deps";
import { errorResponse, HttpError, StorageUnavailable } from "./errors";
import { gitHubClient } from "./github";
import { deleteInstall, mintInstall } from "./installs";
import { approve, exactForIssue, listHeld, maintainerPage, reject } from "./maintainer";
import { deleteReport, getReport, listReports, sendReport } from "./reports";
import { retention, retryIssues, RETENTION_CRON, RETRY_CRON } from "./retention";
import { Store } from "./store";
import { d1Sql } from "./store-d1";
import { secondsToMidnightUTC } from "./time";

// The only Cloudflare-specific entry (Docs/REPORTS.md 7.1): builds Deps from env, routes requests, runs the crons.

export interface Env {
  DB: D1Database;
  GITHUB_TOKEN?: string;
  RL_AUTH: RateLimiter;
  RL_INSTALLS: RateLimiter;
  RL_REPORTS: RateLimiter;
  [key: string]: unknown;
}

export function depsFromEnv(env: Env): Deps {
  const vars = parseVars(env);
  return {
    store: new Store(d1Sql(env.DB)),
    github: gitHubClient({ token: env.GITHUB_TOKEN, repo: vars.githubRepo, fetch: (u, i) => fetch(u, i) }),
    limits: { auth: env.RL_AUTH, installs: env.RL_INSTALLS, reports: env.RL_REPORTS },
    clock: { now: () => new Date() },
    vars,
  };
}

type Handler = (request: Request, deps: Deps, param: string) => Promise<Response> | Response;
const ID = "([0-9A-Fa-f-]{36})";
const routes: [string, RegExp, Handler][] = [
  ["POST", /^\/v1\/installs$/, (r, d) => mintInstall(r, d)],
  ["DELETE", /^\/v1\/installs\/me$/, (r, d) => deleteInstall(r, d)],
  ["POST", /^\/v1\/reports$/, (r, d) => sendReport(r, d)],
  ["GET", /^\/v1\/reports$/, (r, d) => listReports(r, d)],
  ["GET", new RegExp(`^/v1/reports/${ID}$`), (r, d, id) => getReport(r, d, id)],
  ["DELETE", new RegExp(`^/v1/reports/${ID}$`), (r, d, id) => deleteReport(r, d, id)],
  ["GET", /^\/v1\/maintainer\/issues\/([1-9]\d{0,9})\/report$/, (r, d, n) => exactForIssue(r, d, Number(n))],
  ["GET", /^\/v1\/maintainer\/held$/, (r, d) => listHeld(r, d)],
  ["POST", new RegExp(`^/v1/maintainer/reports/${ID}/approve$`), (r, d, id) => approve(r, d, id)],
  ["POST", new RegExp(`^/v1/maintainer/reports/${ID}/reject$`), (r, d, id) => reject(r, d, id)],
  ["GET", /^\/maintainer$/, () => maintainerPage()],
];

/** Routes a request to its handler and turns failures into the error envelope (4.6). Platform-free; tests call it. */
export async function handle(request: Request, deps: Deps): Promise<Response> {
  try {
    const path = new URL(request.url).pathname;
    const matches = routes.filter(([, re]) => re.test(path));
    if (matches.length === 0) throw new HttpError("not_found", "No such route.");
    const route = matches.find(([method]) => method === request.method);
    if (!route) throw new HttpError("not_found", "No such route.");
    return await route[2](request, deps, route[1].exec(path)![1]);
  } catch (e) {
    if (e instanceof HttpError) return errorResponse(e);
    if (e instanceof StorageUnavailable) {
      return errorResponse(new HttpError("storage_unavailable", "The report server is full for today.", undefined, secondsToMidnightUTC(deps.clock.now())));
    }
    console.error("internal error", 500);
    return errorResponse(new HttpError("internal", "Something went wrong."));
  }
}

/** Runs the cron job for a schedule; a failing day (D1 limits spent) catches up on the next run (4.6). */
export async function runCron(cron: string, deps: Deps): Promise<void> {
  if (cron === RETENTION_CRON) await retention(deps);
  else if (cron === RETRY_CRON) await retryIssues(deps);
}

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return handle(request, depsFromEnv(env));
  },
  async scheduled(event: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(runCron(event.cron, depsFromEnv(env)));
  },
} satisfies ExportedHandler<Env>;
