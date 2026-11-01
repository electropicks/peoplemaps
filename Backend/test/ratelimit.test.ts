import { describe, expect, it } from "vitest";
import { limitByIP } from "../src/ratelimit";
import { FakeLimiter, world } from "./helpers";

describe("rate limits", () => {
  it("passes the bare cf-connecting-ip to the binding", async () => {
    const l = new FakeLimiter();
    await limitByIP(new Request("https://x/", { headers: { "cf-connecting-ip": "2001:db8::1" } }), l);
    expect(l.keys).toEqual(["2001:db8::1"]);
  });

  it("answers 429 rate_limited with Retry-After", async () => {
    const l = new FakeLimiter();
    l.allow = false;
    await expect(limitByIP(new Request("https://x/"), l)).rejects.toMatchObject({ code: "rate_limited", retryAfter: 60 });
  });

  it("checks the IP limit before reading the body", async () => {
    const w = world();
    w.limits.installs.allow = false;
    const res = await w.call("POST", "/v1/installs", { raw: "{" });
    expect(res.status).toBe(429);
  });
});
