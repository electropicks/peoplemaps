import { base64, concat, equal, fromBase64, sha256 } from "./bytes";
import { decodeCBOR, type CBOR } from "./cbor";
import type { AttestConfig, Deps } from "./deps";
import { issueChallenge, issueDownloadToken, verifyChallenge } from "./download-token";
import { HttpError, invalid, json } from "./errors";
import { attestCeiling, limitByIP } from "./ratelimit";
import { hour, iso } from "./time";
import { readJSON } from "./validate";
import { children, issuedBy, parseCertificate, pemToDER, readDER, validAt, type Certificate } from "./x509";

// POST /v1/attest/challenge and POST /v1/attest (Docs/REPORTS.md 4.5): App Attest verification with WebCrypto only, per
// Apple's "Validating apps that connect to your server". A verified key gets a download token (4.7). Nothing here is
// specific to downloads, so POST /v1/installs can require the same attestation later.
//
// Assertions are not built. The stored key and counter are what they need: a later `POST /v1/attest/assert` would take
// `{ keyId, assertion, challenge }`, CBOR-decode `{ signature, authenticatorData }`, check the ECDSA P-256 signature over
// SHA-256(authenticatorData || SHA-256(challenge)) with `attest_keys.public_key`, the rpIdHash, and a counter above the
// stored one, then store the new counter and issue a token. Until then the app attests a new key when its token expires.

const NONCE_OID = "1.2.840.113635.100.8.2";
const AAGUID_PRODUCTION = new TextEncoder().encode("appattest\0\0\0\0\0\0\0");
const AAGUID_DEVELOPMENT = new TextEncoder().encode("appattestdevelop");

export interface AttestedKey { publicKey: Uint8Array; environment: "production" | "development"; receipt: Uint8Array }

export interface AttestationInput {
  attestation: Uint8Array;
  /** The challenge bytes the app hashed into `clientDataHash`. */
  challenge: Uint8Array;
  /** The decoded key ID, the SHA-256 of the key's uncompressed public point. */
  keyId: Uint8Array;
  appId: string;
  allowDevelopment: boolean;
  rootPEM: string;
  now: Date;
}

const refuse = (why: string): never => { throw new Error(`attestation: ${why}`); };
const field = (m: CBOR, k: string): CBOR | undefined => (m instanceof Map ? m.get(k) : undefined);

/** Checks an attestation object; throws with the failed step. */
export async function verifyAttestation(a: AttestationInput): Promise<AttestedKey> {
  let obj: CBOR;
  try {
    obj = decodeCBOR(a.attestation);
  } catch {
    return refuse("not CBOR");
  }
  if (field(obj, "fmt") !== "apple-appattest") refuse("fmt");
  const stmt = field(obj, "attStmt"), authData = field(obj, "authData");
  const x5c = field(stmt ?? null, "x5c"), receipt = field(stmt ?? null, "receipt");
  if (!(authData instanceof Uint8Array) || !Array.isArray(x5c) || x5c.length !== 2 || !x5c.every((c) => c instanceof Uint8Array)) refuse("shape");

  // 1. The chain: leaf, then Apple's intermediate, to the pinned root.
  let leaf: Certificate, intermediate: Certificate, root: Certificate;
  try {
    [leaf, intermediate] = (x5c as Uint8Array[]).map(parseCertificate);
    root = parsedRoot(a.rootPEM);
  } catch {
    return refuse("certificate");
  }
  if (leaf.curve.name !== "P-256") refuse("leaf curve");
  for (const c of [leaf, intermediate, root]) if (!validAt(c, a.now)) refuse("certificate validity");
  if (!(await issuedBy(intermediate, root)) || !(await issuedBy(leaf, intermediate))) refuse("chain");

  // 2-4. nonce = SHA-256(authData || SHA-256(challenge)), in the leaf's extension.
  const nonce = await sha256(concat(authData as Uint8Array, await sha256(a.challenge)));
  const ext = leaf.extensions.get(NONCE_OID) ?? refuse("no nonce extension");
  let inCert: Uint8Array;
  try {
    const tagged = children(readDER(ext)).find((c) => c.tag === 0xa1) ?? refuse("nonce");
    const octets = readDER(tagged.body);
    if (octets.tag !== 0x04) refuse("nonce");
    inCert = octets.body;
  } catch {
    return refuse("nonce");
  }
  if (!equal(inCert, nonce)) refuse("nonce");

  // 5. The key ID is the SHA-256 of the leaf's public key.
  if (!equal(await sha256(leaf.point), a.keyId)) refuse("key ID");

  // 6-9. authData: rpIdHash, counter, aaguid, credentialId.
  const d = authData as Uint8Array;
  if (d.length < 55) refuse("authData");
  if (!equal(d.subarray(0, 32), await sha256(new TextEncoder().encode(a.appId)))) refuse("app ID");
  if (new DataView(d.buffer, d.byteOffset).getUint32(33) !== 0) refuse("counter");
  const aaguid = d.subarray(37, 53);
  const environment = equal(aaguid, AAGUID_PRODUCTION) ? "production" : equal(aaguid, AAGUID_DEVELOPMENT) ? "development" : refuse("aaguid");
  if (environment === "development" && !a.allowDevelopment) refuse("development key");
  const idLength = (d[53] << 8) | d[54];
  if (d.length < 55 + idLength || !equal(d.subarray(55, 55 + idLength), a.keyId)) refuse("credential ID");

  return { publicKey: leaf.spki.slice(), environment, receipt: receipt instanceof Uint8Array ? receipt : new Uint8Array() };
}

const roots = new Map<string, Certificate>();
/** The pinned root, parsed once per isolate. */
function parsedRoot(pem: string): Certificate {
  let root = roots.get(pem);
  if (!root) {
    root = parseCertificate(pemToDER(pem));
    roots.set(pem, root);
  }
  return root;
}

function configured(deps: Deps): AttestConfig {
  const c = deps.attest;
  if (!/^[A-Z0-9]{10}\.[A-Za-z0-9.-]+$/.test(c.appId) || c.tokenSecret.length < 32 || !c.rootPEM) {
    throw new HttpError("internal", "Region downloads are not set up on this server.");
  }
  return c;
}

/** `POST /v1/attest/challenge`: a signed challenge valid for 5 minutes. Stateless: nothing is stored. */
export async function attestChallenge(request: Request, deps: Deps): Promise<Response> {
  await limitByIP(request, deps.limits.attest);
  const cfg = configured(deps);
  const { challenge, expiresAt } = await issueChallenge(cfg.tokenSecret, deps.clock.now());
  return json(201, { challenge: base64(challenge), expiresAt: iso(expiresAt) });
}

const unverified = () => new HttpError("unauthorized", "This copy of the app could not be verified.");

/** `POST /v1/attest`: `{ keyId, attestation, challenge }`, all base64. A verified key is stored and gets a download token. */
export async function attest(request: Request, deps: Deps): Promise<Response> {
  await limitByIP(request, deps.limits.attest);
  const cfg = configured(deps);
  const body = await readJSONObject(request);
  for (const k of Object.keys(body)) if (!["keyId", "attestation", "challenge"].includes(k)) throw invalid(k, "Unknown key.");
  const bytes = (k: "keyId" | "attestation" | "challenge", length?: number) => {
    const v = body[k];
    const b = typeof v === "string" && v.length > 0 ? fromBase64(v) : null;
    if (!b || (length !== undefined && b.length !== length) || b.length === 0) throw invalid(k);
    return b;
  };
  const keyId = bytes("keyId", 32), attestation = bytes("attestation"), challenge = bytes("challenge");
  const now = deps.clock.now();
  if (!(await verifyChallenge(cfg.tokenSecret, challenge, now))) {
    throw new HttpError("unauthorized", "The challenge is unknown or expired. Ask for a new one.");
  }
  await attestCeiling(deps);
  let key: AttestedKey;
  try {
    key = await verifyAttestation({ attestation, challenge, keyId, appId: cfg.appId, allowDevelopment: cfg.allowDevelopment, rootPEM: cfg.rootPEM, now });
  } catch {
    throw unverified();
  }
  // A key is attested once: the key ID is the primary key, so a replay or a second attestation of it stores nothing.
  const row = { key_id: base64(keyId), public_key: base64(key.publicKey), counter: 0, environment: key.environment, created_at: hour(now) };
  if (!(await deps.store.insertAttestKey(row))) throw new HttpError("unauthorized", "This key was already attested.");
  const { token, expiresAt } = await issueDownloadToken(cfg.tokenSecret, keyId, now);
  return json(200, { token, expiresAt: iso(expiresAt) });
}

async function readJSONObject(request: Request): Promise<Record<string, unknown>> {
  const body = await readJSON(request);
  if (typeof body !== "object" || body === null || Array.isArray(body)) throw invalid("body", "Expected an object.");
  return body as Record<string, unknown>;
}
