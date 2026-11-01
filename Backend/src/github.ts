// GitHub calls (Docs/REPORTS.md 4.4, 4.5, 6). The only module that holds GITHUB_TOKEN; it is passed in by index.ts.

export interface GitHub {
  createIssue(issue: { title: string; body: string; labels: string[] }): Promise<{ number: number; nodeId: string; url: string }>;
  /** GraphQL `deleteIssue`. An issue that is already gone counts as deleted. */
  deleteIssue(nodeId: string): Promise<void>;
  /** The body of an issue in our repository, or null when there is none. */
  issueBody(number: number): Promise<string | null>;
  /** The login behind a person's token, or null when GitHub refuses the token. The token is not kept. */
  loginForToken(token: string): Promise<string | null>;
  /** `admin`, `maintain`, `write`, `triage`, `read` or `none` for a login on our repository. */
  permission(login: string): Promise<string>;
}

/** GitHub refused or could not be reached. `status` is 0 without a response. Carries no request data. */
export class GitHubError extends Error {
  constructor(readonly status: number, message: string) { super(message); }
}

const API = "https://api.github.com";
type Fetch = (input: string, init: RequestInit) => Promise<Response>;

export function gitHubClient(options: { token?: string; repo: string; fetch: Fetch }): GitHub {
  const { token, repo } = options;
  const headers = (bearer: string) => ({
    Authorization: `Bearer ${bearer}`,
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "peoplemaps-reports",
  });
  const own = () => {
    if (!token) throw new GitHubError(0, "no GITHUB_TOKEN");
    return token;
  };
  async function call(path: string, init: { method: string; body?: unknown }, bearer: string): Promise<Response> {
    try {
      return await options.fetch(API + path, {
        method: init.method,
        headers: { ...headers(bearer), ...(init.body !== undefined ? { "Content-Type": "application/json" } : {}) },
        body: init.body !== undefined ? JSON.stringify(init.body) : undefined,
      });
    } catch {
      throw new GitHubError(0, "network error");
    }
  }
  const fail = (res: Response, what: string) => new GitHubError(res.status, `${what}: HTTP ${res.status}`);

  return {
    async createIssue(issue) {
      const res = await call(`/repos/${repo}/issues`, { method: "POST", body: issue }, own());
      if (res.status !== 201) throw fail(res, "create issue");
      const j = (await res.json()) as { number: number; node_id: string; html_url: string };
      return { number: j.number, nodeId: j.node_id, url: j.html_url };
    },
    async deleteIssue(nodeId) {
      const res = await call("/graphql", {
        method: "POST",
        body: { query: "mutation($id: ID!) { deleteIssue(input: { issueId: $id }) { clientMutationId } }", variables: { id: nodeId } },
      }, own());
      if (res.status !== 200) throw fail(res, "delete issue");
      const j = (await res.json()) as { errors?: { type?: string }[] };
      if (j.errors?.length && !j.errors.every((e) => e.type === "NOT_FOUND")) throw new GitHubError(200, `delete issue: ${j.errors[0].type ?? "error"}`);
    },
    async issueBody(number) {
      const res = await call(`/repos/${repo}/issues/${number}`, { method: "GET" }, own());
      if (res.status === 404 || res.status === 410) return null;
      if (res.status !== 200) throw fail(res, "read issue");
      return ((await res.json()) as { body?: string | null }).body ?? null;
    },
    async loginForToken(personal) {
      const res = await call("/user", { method: "GET" }, personal);
      if (res.status === 401 || res.status === 403) return null;
      if (res.status !== 200) throw fail(res, "user");
      return ((await res.json()) as { login: string }).login;
    },
    async permission(login) {
      const res = await call(`/repos/${repo}/collaborators/${encodeURIComponent(login)}/permission`, { method: "GET" }, own());
      if (res.status === 404) return "none";
      if (res.status !== 200) throw fail(res, "permission");
      const j = (await res.json()) as { permission?: string; role_name?: string };
      // A maintainer reads as permission "write" with role_name "maintain".
      return j.role_name === "maintain" ? "maintain" : j.permission ?? "none";
    },
  };
}
