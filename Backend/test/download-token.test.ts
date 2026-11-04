import { describe, expect, it } from "vitest";
import { base64url, fromBase64 } from "../src/bytes";
import { DOWNLOAD_TOKEN, issueChallenge, issueDownloadToken, verifyChallenge, verifyDownloadToken } from "../src/download-token";
import { TEST_TOKEN_SECRET } from "./helpers";

const NOW = new Date("2026-10-31T21:34:00Z");
const keyId = Uint8Array.from({ length: 32 }, (_, i) => i);

describe("attest challenges", () => {
  it("verify under the same secret for 5 minutes only", async () => {
    const { challenge, expiresAt } = await issueChallenge(TEST_TOKEN_SECRET, NOW);
    expect(challenge).toHaveLength(68);
    expect(expiresAt.toISOString()).toBe("2026-10-31T21:39:00.000Z");
    expect(await verifyChallenge(TEST_TOKEN_SECRET, challenge, new Date("2026-10-31T21:38:59Z"))).toBe(true);
    expect(await verifyChallenge(TEST_TOKEN_SECRET, challenge, expiresAt)).toBe(false);
    expect(await verifyChallenge("another-secret-that-is-long-enough-000000", challenge, NOW)).toBe(false);
    for (const at of [0, 32, 35, 36, 67]) {
      const t = challenge.slice();
      t[at] ^= 1;
      expect(await verifyChallenge(TEST_TOKEN_SECRET, t, NOW), `byte ${at}`).toBe(false);
    }
  });

  it("are different each time", async () => {
    const a = (await issueChallenge(TEST_TOKEN_SECRET, NOW)).challenge, b = (await issueChallenge(TEST_TOKEN_SECRET, NOW)).challenge;
    expect(a).not.toEqual(b);
  });
});

describe("download tokens", () => {
  it("round-trips the key ID and expires 24 hours after issue", async () => {
    const { token, expiresAt } = await issueDownloadToken(TEST_TOKEN_SECRET, keyId, NOW);
    expect(token).toMatch(DOWNLOAD_TOKEN);
    expect(expiresAt.toISOString()).toBe("2026-11-01T21:34:00.000Z");
    expect(await verifyDownloadToken(TEST_TOKEN_SECRET, token, NOW)).toEqual(keyId);
    expect(await verifyDownloadToken(TEST_TOKEN_SECRET, token, new Date("2026-11-01T21:33:59Z"))).toEqual(keyId);
    expect(await verifyDownloadToken(TEST_TOKEN_SECRET, token, new Date("2026-11-01T21:34:00Z"))).toBeNull();
  });

  it("does not show the secret and differs per key", async () => {
    const a = (await issueDownloadToken(TEST_TOKEN_SECRET, keyId, NOW)).token;
    const b = (await issueDownloadToken(TEST_TOKEN_SECRET, new Uint8Array(32), NOW)).token;
    expect(a).not.toBe(b);
    expect(a).not.toContain(base64url(new TextEncoder().encode(TEST_TOKEN_SECRET)).slice(0, 12));
  });

  it("refuses a token signed with another secret", async () => {
    const { token } = await issueDownloadToken("another-secret-that-is-long-enough-000000", keyId, NOW);
    expect(await verifyDownloadToken(TEST_TOKEN_SECRET, token, NOW)).toBeNull();
  });

  it("refuses any changed byte: version, expiry, key ID or MAC", async () => {
    const { token } = await issueDownloadToken(TEST_TOKEN_SECRET, keyId, NOW);
    const bytes = fromBase64(token.slice(4))!;
    for (const at of [0, 1, 4, 5, 36, 37, 68]) {
      const t = bytes.slice();
      t[at] ^= 0x01;
      expect(await verifyDownloadToken(TEST_TOKEN_SECRET, "pmd_" + base64url(t), NOW), `byte ${at}`).toBeNull();
    }
    // Pushing the expiry later without the secret fails too.
    const later = bytes.slice();
    later[1] = 0xff;
    expect(await verifyDownloadToken(TEST_TOKEN_SECRET, "pmd_" + base64url(later), NOW)).toBeNull();
  });

  it("refuses malformed tokens", async () => {
    const { token } = await issueDownloadToken(TEST_TOKEN_SECRET, keyId, NOW);
    for (const t of ["", "pmd_", token.slice(0, -1), token + "A", "pm_" + token.slice(4), token.replace("pmd_", "pmd_!").slice(0, token.length)]) {
      expect(await verifyDownloadToken(TEST_TOKEN_SECRET, t, NOW), t).toBeNull();
    }
  });
});
