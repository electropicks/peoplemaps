import { describe, expect, it } from "vitest";
import { ipKey, limitByIP } from "../src/ratelimit";
import { FakeLimiter, world } from "./helpers";

describe("rate limits", () => {
  it("keys the binding on the IPv4 address or the IPv6 /64", async () => {
    const l = new FakeLimiter();
    await limitByIP(new Request("https://x/", { headers: { "cf-connecting-ip": "203.0.113.7" } }), l);
    await limitByIP(new Request("https://x/", { headers: { "cf-connecting-ip": "2001:db8::1" } }), l);
    expect(l.keys).toEqual(["203.0.113.7", "2001:db8:0:0::/64"]);
  });

  it("gives every spelling of one /64 the same key, and other /64s another", () => {
    const key = "2001:db8:1:2::/64";
    for (const ip of ["2001:db8:1:2::", "2001:db8:1:2::1", "2001:db8:1:2:3:4:5:6", "2001:0DB8:0001:0002:ffff:ffff:ffff:ffff"]) expect(ipKey(ip)).toBe(key);
    expect(ipKey("2001:db8:1:3::1")).not.toBe(key);
    expect(ipKey("::1")).toBe("0:0:0:0::/64");
    expect(ipKey("fe80:1::")).toBe("fe80:1:0:0::/64");
    expect(ipKey("::ffff:203.0.113.7")).toBe("203.0.113.7");
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
