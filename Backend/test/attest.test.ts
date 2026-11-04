import { beforeAll, describe, expect, it } from "vitest";
import { APPLE_APP_ATTEST_ROOT } from "../src/apple-root";
import { verifyAttestation, type AttestationInput } from "../src/attest";
import { base64, fromBase64 } from "../src/bytes";
import { decodeCBOR } from "../src/cbor";
import { verifyDownloadToken } from "../src/download-token";
import { issuedBy, parseCertificate, pemToDER } from "../src/x509";
import { makeAttestation, makeIntermediate, makeRoot, pem, type AttestationOptions, type CA } from "./attest-fixture";
import { TEST_APP_ID, TEST_TOKEN_SECRET, world } from "./helpers";

// Every attestation here comes from the synthetic chain in attest-fixture.ts. Apple's real chain is not exercised: that
// needs a recorded attestation from a real phone (Docs/REPORTS.md 4.5).

const NOW = new Date("2026-10-31T21:34:00Z");
let root: CA, ca: CA, rootPEM: string;
beforeAll(async () => {
  root = await makeRoot();
  ca = await makeIntermediate(root);
  rootPEM = pem(root.cert);
});

async function input(o: Partial<AttestationOptions> = {}, over: Partial<AttestationInput> = {}): Promise<AttestationInput> {
  const challenge = crypto.getRandomValues(new Uint8Array(32));
  const { attestation, keyId } = await makeAttestation(ca, { appId: TEST_APP_ID, challenge, ...o });
  return { attestation, challenge, keyId, appId: TEST_APP_ID, allowDevelopment: false, rootPEM, now: NOW, ...over };
}

describe("Apple's App Attest root", () => {
  it("is the P-384 root valid to 2045, and its self-signature checks with our verifier", async () => {
    const cert = parseCertificate(pemToDER(APPLE_APP_ATTEST_ROOT));
    expect(new TextDecoder().decode(cert.subject)).toContain("Apple App Attestation Root CA");
    expect(cert.curve.name).toBe("P-384");
    expect(cert.hash).toBe("SHA-384");
    expect(cert.notAfter.toISOString()).toBe("2045-03-15T00:00:00.000Z");
    expect(await issuedBy(cert, cert)).toBe(true);
  });
});

describe("CBOR", () => {
  it("decodes maps, byte strings and integers, and refuses indefinite lengths and trailing bytes", () => {
    const m = decodeCBOR(new Uint8Array([0xa2, 0x61, 0x61, 0x42, 1, 2, 0x61, 0x62, 0x38, 0x18])) as Map<unknown, unknown>;
    expect(m.get("a")).toEqual(new Uint8Array([1, 2]));
    expect(m.get("b")).toBe(-25);
    expect(() => decodeCBOR(new Uint8Array([0x5f, 0xff]))).toThrow();
    expect(() => decodeCBOR(new Uint8Array([0x01, 0x02]))).toThrow();
    expect(() => decodeCBOR(new Uint8Array([0x42, 1]))).toThrow();
  });
});

describe("verifyAttestation", () => {
  it("accepts a production attestation and returns the leaf key", async () => {
    const a = await input();
    const key = await verifyAttestation(a);
    expect(key.environment).toBe("production");
    expect(key.receipt).toEqual(new Uint8Array([1, 2, 3]));
    const imported = await crypto.subtle.importKey("spki", key.publicKey, { name: "ECDSA", namedCurve: "P-256" }, true, ["verify"]);
    const point = new Uint8Array((await crypto.subtle.exportKey("raw", imported)) as ArrayBuffer);
    expect(new Uint8Array(await crypto.subtle.digest("SHA-256", point))).toEqual(a.keyId);
  });

  it("accepts a development key only when allowed", async () => {
    await expect(verifyAttestation(await input({ aaguid: "appattestdevelop" }))).rejects.toThrow(/development key/);
    expect((await verifyAttestation(await input({ aaguid: "appattestdevelop" }, { allowDevelopment: true }))).environment).toBe("development");
  });

  const refusals: [string, Partial<AttestationOptions>, Partial<AttestationInput>, RegExp][] = [
    ["another challenge in the nonce", { nonceChallenge: new Uint8Array(32) }, {}, /nonce/],
    ["no nonce extension", { noNonce: true }, {}, /nonce/],
    ["another app ID", { appId: "ABCDE12345.org.example.other" }, {}, /app ID/],
    ["a non-zero counter", { counter: 1 }, {}, /counter/],
    ["an unknown aaguid", { aaguid: "somethingelse" }, {}, /aaguid/],
    ["a credential ID that is not the key ID", { credentialId: new Uint8Array(32) }, {}, /credential ID/],
    ["another format", { fmt: "packed" }, {}, /fmt/],
    ["an expired leaf", { leafValidity: { notBefore: new Date("2025-01-01T00:00:00Z"), notAfter: new Date("2026-01-01T00:00:00Z") } }, {}, /validity/],
    ["a bad leaf signature", { badLeafSignature: true }, {}, /chain/],
    ["a key ID that is not the leaf's", {}, { keyId: new Uint8Array(32).fill(7) }, /key ID/],
    ["a clock before the leaf is valid", { leafValidity: { notBefore: new Date("2027-01-01T00:00:00Z"), notAfter: new Date("2028-01-01T00:00:00Z") } }, {}, /validity/],
    ["junk", {}, { attestation: new Uint8Array([1, 2, 3]) }, /CBOR/],
  ];
  for (const [what, o, over, why] of refusals) {
    it(`refuses ${what}`, async () => {
      await expect(verifyAttestation(await input(o, over))).rejects.toThrow(why);
    });
  }

  it("refuses a chain to another root, even one with the same name", async () => {
    await expect(verifyAttestation(await input({}, { rootPEM: APPLE_APP_ATTEST_ROOT }))).rejects.toThrow(/chain/);
    const impostor = await makeRoot();
    await expect(verifyAttestation(await input({}, { rootPEM: pem(impostor.cert) }))).rejects.toThrow(/chain/);
  });

  it("refuses an intermediate that names the root but is signed by another key", async () => {
    const other = await makeRoot();
    const forged = await makeIntermediate(root, other.keys.privateKey);
    const challenge = crypto.getRandomValues(new Uint8Array(32));
    const { attestation, keyId } = await makeAttestation(forged, { appId: TEST_APP_ID, challenge });
    await expect(verifyAttestation({ attestation, challenge, keyId, appId: TEST_APP_ID, allowDevelopment: false, rootPEM, now: NOW })).rejects.toThrow(/chain/);
  });
});

describe("POST /v1/attest/challenge and POST /v1/attest", () => {
  const setup = () => world({}, "2026-10-31T21:34:00Z", { rootPEM });
  async function challenge(w: ReturnType<typeof setup>) {
    const res = await w.call("POST", "/v1/attest/challenge");
    expect(res.status).toBe(201);
    const body = (await res.json()) as { challenge: string; expiresAt: string };
    return { ...body, bytes: fromBase64(body.challenge)! };
  }
  async function attestBody(c: Uint8Array, o: Partial<AttestationOptions> = {}) {
    const { attestation, keyId } = await makeAttestation(ca, { appId: TEST_APP_ID, challenge: c, ...o });
    return { keyId: base64(keyId), attestation: base64(attestation), challenge: base64(c) };
  }

  it("issues a 32-byte challenge for 5 minutes and stores only its hash", async () => {
    const w = setup();
    const c = await challenge(w);
    expect(c.bytes).toHaveLength(32);
    expect(c.expiresAt).toBe("2026-10-31T21:39:00Z");
    const [row] = w.rows("attest_challenges");
    expect(row.expires_at).toBe("2026-10-31T21:39:00Z");
    expect(JSON.stringify(row)).not.toContain(c.challenge);
  });

  it("verifies, stores the key at counter 0 and returns a 24-hour download token bound to the key", async () => {
    const w = setup();
    const c = await challenge(w);
    const body = await attestBody(c.bytes);
    const res = await w.call("POST", "/v1/attest", { body });
    expect(res.status).toBe(200);
    const { token, expiresAt } = (await res.json()) as { token: string; expiresAt: string };
    expect(expiresAt).toBe("2026-11-01T21:34:00Z");
    expect(await verifyDownloadToken(TEST_TOKEN_SECRET, token, w.clock.now())).toEqual(fromBase64(body.keyId));
    expect(w.rows("attest_keys")).toEqual([expect.objectContaining({ key_id: body.keyId, counter: 0, environment: "production", created_at: "2026-10-31T21:00:00Z" })]);
    expect(w.rows("attest_challenges")).toHaveLength(0);
  });

  it("uses a challenge once, even when the first attempt fails", async () => {
    const w = setup();
    const c = await challenge(w);
    expect((await w.call("POST", "/v1/attest", { body: await attestBody(c.bytes, { counter: 1 }) })).status).toBe(401);
    const res = await w.call("POST", "/v1/attest", { body: await attestBody(c.bytes) });
    expect(res.status).toBe(401);
    expect(await res.json()).toMatchObject({ error: "unauthorized" });
  });

  it("refuses an expired or unknown challenge", async () => {
    const w = setup();
    const c = await challenge(w);
    w.clock.t = new Date("2026-10-31T21:39:00Z");
    expect((await w.call("POST", "/v1/attest", { body: await attestBody(c.bytes) })).status).toBe(401);
    expect((await w.call("POST", "/v1/attest", { body: await attestBody(crypto.getRandomValues(new Uint8Array(32))) })).status).toBe(401);
    expect(w.rows("attest_keys")).toHaveLength(0);
  });

  it("refuses a bad body with the field", async () => {
    const w = setup();
    const c = await challenge(w);
    const good = await attestBody(c.bytes);
    for (const [body, field] of [[{ ...good, keyId: "short" }, "keyId"], [{ ...good, attestation: "" }, "attestation"], [{ ...good, extra: 1 }, "extra"], [[], "body"]] as const) {
      const res = await w.call("POST", "/v1/attest", { body });
      expect(res.status).toBe(400);
      expect(await res.json()).toMatchObject({ error: "invalid_report", field });
    }
  });

  it("is limited per IP on RL_ATTEST, before the body is read", async () => {
    const w = setup();
    await challenge(w);
    expect(w.limits.attest.keys).toEqual(["203.0.113.7"]);
    w.limits.attest.allow = false;
    expect((await w.call("POST", "/v1/attest/challenge")).status).toBe(429);
    expect((await w.call("POST", "/v1/attest", { raw: "{" })).status).toBe(429);
  });

  it("answers 500 when APP_ID or the token secret is not set, and stores nothing", async () => {
    for (const over of [{ appId: "" }, { tokenSecret: "" }]) {
      const w = world({}, undefined, { rootPEM, ...over });
      const res = await w.call("POST", "/v1/attest/challenge");
      expect(res.status).toBe(500);
      expect(await res.json()).toMatchObject({ error: "internal" });
      expect(w.rows("attest_challenges")).toHaveLength(0);
    }
  });

  it("retention drops expired challenges and keys older than RETENTION_DAYS", async () => {
    const { retention } = await import("../src/retention");
    const w = setup();
    await challenge(w);
    const c = await challenge(w);
    await w.call("POST", "/v1/attest", { body: await attestBody(c.bytes) });
    w.clock.t = new Date("2026-10-31T21:40:00Z");
    expect(await retention(w.deps)).toMatchObject({ challenges: 1, keys: 0 });
    w.clock.t = new Date("2027-01-30T00:00:00Z");
    expect(await retention(w.deps)).toMatchObject({ challenges: 0, keys: 1 });
  });
});
