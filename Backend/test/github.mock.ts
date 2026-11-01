// A fetch mock standing in for api.github.com. It records every request so tests can assert the exact call made.

export interface Recorded { method: string; url: string; headers: Record<string, string>; body: unknown }

export class GitHubMock {
  requests: Recorded[] = [];
  nextIssue = 100;
  issues = new Map<number, { nodeId: string; body: string; title: string; labels: string[] }>();
  /** Status to answer issue creation with; 201 files it. */
  createStatus = 201;
  /** Status for GraphQL deletes; 200 deletes. `deleteErrors` answers 200 with GraphQL errors of that type. */
  deleteStatus = 200;
  deleteErrors: string | null = null;
  /** Personal tokens and their logins, for GET /user. */
  users = new Map<string, string>();
  /** Logins and their permission answer; anything else is a 404 (not a collaborator). */
  permissions = new Map<string, { permission: string; role_name: string }>();
  /** Answer every request with this status, as if GitHub were down. */
  down: number | null = null;

  fetch = async (url: string, init: RequestInit): Promise<Response> => {
    const headers = Object.fromEntries(Object.entries((init.headers ?? {}) as Record<string, string>));
    const body = typeof init.body === "string" ? JSON.parse(init.body) : undefined;
    const method = init.method ?? "GET";
    this.requests.push({ method, url, headers, body });
    const res = (status: number, b?: unknown) => new Response(b === undefined ? null : JSON.stringify(b), { status });
    if (this.down !== null) return res(this.down, { message: "down" });
    const path = new URL(url).pathname;
    const auth = headers.Authorization?.replace(/^Bearer /, "");

    if (method === "POST" && /^\/repos\/[^/]+\/[^/]+\/issues$/.test(path)) {
      if (this.createStatus !== 201) return res(this.createStatus, { message: "nope" });
      const number = this.nextIssue++;
      const nodeId = `I_node${number}`;
      this.issues.set(number, { nodeId, body: body.body, title: body.title, labels: body.labels });
      return res(201, { number, node_id: nodeId, html_url: `https://github.com/electropicks/peoplemaps/issues/${number}` });
    }
    if (method === "POST" && path === "/graphql") {
      if (this.deleteStatus !== 200) return res(this.deleteStatus, { message: "nope" });
      if (this.deleteErrors) return res(200, { data: null, errors: [{ type: this.deleteErrors, message: "x" }] });
      const id = body.variables.id;
      const found = [...this.issues].find(([, i]) => i.nodeId === id);
      if (!found) return res(200, { data: null, errors: [{ type: "NOT_FOUND", message: "gone" }] });
      this.issues.delete(found[0]);
      return res(200, { data: { deleteIssue: { clientMutationId: null } } });
    }
    let m = /^\/repos\/[^/]+\/[^/]+\/issues\/(\d+)$/.exec(path);
    if (method === "GET" && m) {
      const issue = this.issues.get(Number(m[1]));
      return issue ? res(200, { body: issue.body }) : res(404, { message: "Not Found" });
    }
    if (method === "GET" && path === "/user") {
      const login = auth ? this.users.get(auth) : undefined;
      return login ? res(200, { login }) : res(401, { message: "Bad credentials" });
    }
    m = /^\/repos\/[^/]+\/[^/]+\/collaborators\/([^/]+)\/permission$/.exec(path);
    if (method === "GET" && m) {
      const p = this.permissions.get(decodeURIComponent(m[1]));
      return p ? res(200, { ...p, user: { login: m[1] } }) : res(404, { message: "Not Found" });
    }
    return res(404, { message: "unmocked" });
  };

  /** Requests that used the Worker's own token, i.e. anything but GET /user. */
  ownCalls(token = "gh_worker_token") {
    return this.requests.filter((r) => r.headers.Authorization === `Bearer ${token}`);
  }
}
