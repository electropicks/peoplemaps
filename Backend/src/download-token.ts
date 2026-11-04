import { base64url, concat, fromBase64 } from "./bytes";

// The download token of Docs/REPORTS.md 4.7: `pmd_` + base64url(version, expiry, keyId, HMAC-SHA256). Stateless, so a
// download needs no D1 read. Opaque to the app, which only sends it back.

export const DOWNLOAD_TOKEN_TTL = 24 * 3600;
const VERSION = 1;
const CONTEXT = new TextEncoder().encode("peoplemaps download token v1");
const KEY_ID = 32, PAYLOAD = 1 + 4 + KEY_ID, MAC = 32;
export const DOWNLOAD_TOKEN = /^pmd_[A-Za-z0-9_-]{92}$/;

async function hmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}

/** A token for `keyId` (the 32-byte App Attest key ID), valid for 24 hours from `now`. */
export async function issueDownloadToken(secret: string, keyId: Uint8Array, now: Date): Promise<{ token: string; expiresAt: Date }> {
  if (keyId.length !== KEY_ID) throw new Error("key ID must be 32 bytes");
  const exp = Math.floor(now.getTime() / 1000) + DOWNLOAD_TOKEN_TTL;
  const payload = new Uint8Array(PAYLOAD);
  payload[0] = VERSION;
  new DataView(payload.buffer).setUint32(1, exp);
  payload.set(keyId, 5);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", await hmacKey(secret), concat(CONTEXT, payload)));
  return { token: "pmd_" + base64url(concat(payload, mac)), expiresAt: new Date(exp * 1000) };
}

// The App Attest challenge of 4.5, stateless too so issuing one writes nothing: 32 random bytes, the expiry, and an HMAC
// under the same secret with its own context, so a challenge can never pass as a token or the other way round.
const CHALLENGE_CONTEXT = new TextEncoder().encode("peoplemaps attest challenge v1");
export const CHALLENGE_TTL = 5 * 60;
const CHALLENGE_BODY = 32 + 4, CHALLENGE_LENGTH = CHALLENGE_BODY + MAC;

/** A challenge valid for 5 minutes from `now`: 68 bytes the app hashes into `clientDataHash`. */
export async function issueChallenge(secret: string, now: Date): Promise<{ challenge: Uint8Array; expiresAt: Date }> {
  const exp = Math.floor(now.getTime() / 1000) + CHALLENGE_TTL;
  const body = new Uint8Array(CHALLENGE_BODY);
  crypto.getRandomValues(body.subarray(0, 32));
  new DataView(body.buffer).setUint32(32, exp);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", await hmacKey(secret), concat(CHALLENGE_CONTEXT, body)));
  return { challenge: concat(body, mac), expiresAt: new Date(exp * 1000) };
}

/** Whether `challenge` was issued under `secret` and has not expired. Single use is up to the caller. */
export async function verifyChallenge(secret: string, challenge: Uint8Array, now: Date): Promise<boolean> {
  if (challenge.length !== CHALLENGE_LENGTH) return false;
  const body = challenge.subarray(0, CHALLENGE_BODY), mac = challenge.subarray(CHALLENGE_BODY);
  if (!(await crypto.subtle.verify("HMAC", await hmacKey(secret), mac, concat(CHALLENGE_CONTEXT, body)))) return false;
  return now.getTime() < new DataView(body.buffer, body.byteOffset).getUint32(32) * 1000;
}

/** The key ID a token was issued for, or null when it is malformed, tampered with, signed with another secret or expired. */
export async function verifyDownloadToken(secret: string, token: string, now: Date): Promise<Uint8Array | null> {
  if (!DOWNLOAD_TOKEN.test(token)) return null;
  const bytes = fromBase64(token.slice(4));
  if (!bytes || bytes.length !== PAYLOAD + MAC) return null;
  const payload = bytes.subarray(0, PAYLOAD), mac = bytes.subarray(PAYLOAD);
  if (!(await crypto.subtle.verify("HMAC", await hmacKey(secret), mac, concat(CONTEXT, payload)))) return null;
  if (payload[0] !== VERSION) return null;
  const exp = new DataView(payload.buffer, payload.byteOffset).getUint32(1);
  if (now.getTime() >= exp * 1000) return null;
  return payload.slice(5);
}
