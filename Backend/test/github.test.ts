import { describe, expect, it } from "vitest";
import { gitHubClient, GitHubError } from "../src/github";
import { GitHubMock } from "./github.mock";

const setup = (token: string | undefined = "gh_worker_token") => {
  const gh = new GitHubMock();
  return { gh, client: gitHubClient({ token, repo: "electropicks/peoplemaps", fetch: gh.fetch }) };
};

describe("github client", () => {
  it("creates an issue with exactly this request", async () => {
    const { gh, client } = setup();
    const out = await client.createIssue({ title: "t", body: "b", labels: ["app-report"] });
    expect(out).toEqual({ number: 100, nodeId: "I_node100", url: "https://github.com/electropicks/peoplemaps/issues/100" });
    expect(gh.requests).toEqual([{
      method: "POST",
      url: "https://api.github.com/repos/electropicks/peoplemaps/issues",
      headers: {
        Authorization: "Bearer gh_worker_token",
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "peoplemaps-reports",
        "Content-Type": "application/json",
      },
      body: { title: "t", body: "b", labels: ["app-report"] },
    }]);
  });

  it("deletes with the GraphQL deleteIssue mutation", async () => {
    const { gh, client } = setup();
    const { nodeId } = await client.createIssue({ title: "t", body: "b", labels: [] });
    await client.deleteIssue(nodeId);
    const r = gh.requests[1];
    expect(r.method).toBe("POST");
    expect(r.url).toBe("https://api.github.com/graphql");
    expect(r.body).toEqual({ query: "mutation($id: ID!) { deleteIssue(input: { issueId: $id }) { clientMutationId } }", variables: { id: nodeId } });
    expect(gh.issues.size).toBe(0);
  });

  it("treats an issue that is already gone as deleted, and other GraphQL errors as failures", async () => {
    const { gh, client } = setup();
    await expect(client.deleteIssue("I_missing")).resolves.toBeUndefined();
    gh.deleteErrors = "FORBIDDEN";
    await expect(client.deleteIssue("I_missing")).rejects.toBeInstanceOf(GitHubError);
  });

  it("fails without a token, so reports stay pending", async () => {
    const { gh, client } = setup("");
    await expect(client.createIssue({ title: "t", body: "b", labels: [] })).rejects.toMatchObject({ status: 0 });
    expect(gh.requests).toHaveLength(0);
  });

  it("reads a person's login with their token and the permission with ours", async () => {
    const { gh, client } = setup();
    gh.users.set("ghp_x", "alex");
    gh.permissions.set("alex", { permission: "write", role_name: "maintain" });
    expect(await client.loginForToken("ghp_x")).toBe("alex");
    expect(await client.loginForToken("ghp_bad")).toBeNull();
    expect(await client.permission("alex")).toBe("maintain");
    expect(await client.permission("stranger")).toBe("none");
    expect(gh.requests[0].headers.Authorization).toBe("Bearer ghp_x");
    expect(gh.requests[2].url).toBe("https://api.github.com/repos/electropicks/peoplemaps/collaborators/alex/permission");
    expect(gh.requests[2].headers.Authorization).toBe("Bearer gh_worker_token");
  });

  it("reports a server error with its status and no request data", async () => {
    const { gh, client } = setup();
    gh.createStatus = 500;
    await expect(client.createIssue({ title: "secret title", body: "b", labels: [] })).rejects.toMatchObject({ status: 500, message: "create issue: HTTP 500" });
  });
});
