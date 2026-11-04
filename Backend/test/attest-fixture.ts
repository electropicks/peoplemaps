import { base64, concat, sha256 } from "../src/bytes";

// A synthetic App Attest chain made with WebCrypto: a self-signed P-384 root standing in for Apple's, an intermediate, and
// a leaf with the nonce extension, wrapped in a CBOR attestation object. Nothing here touches Apple's real chain.

const u8 = (...b: number[]) => new Uint8Array(b);
const len = (n: number) => (n < 0x80 ? u8(n) : n < 0x100 ? u8(0x81, n) : u8(0x82, n >> 8, n & 0xff));
const tlv = (tag: number, ...parts: Uint8Array[]) => { const body = concat(...parts); return concat(u8(tag), len(body.length), body); };
const seq = (...p: Uint8Array[]) => tlv(0x30, ...p);
const set = (...p: Uint8Array[]) => tlv(0x31, ...p);
const octets = (b: Uint8Array) => tlv(0x04, b);
const bits = (b: Uint8Array) => tlv(0x03, u8(0), b);
const explicit = (n: number, inner: Uint8Array) => tlv(0xa0 + n, inner);
const bool = (v: boolean) => tlv(0x01, u8(v ? 0xff : 0));
function int(b: Uint8Array): Uint8Array {
  let i = 0;
  while (i < b.length - 1 && b[i] === 0) i++;
  const v = b.subarray(i);
  return tlv(0x02, v[0] & 0x80 ? concat(u8(0), v) : v);
}
function oid(dotted: string): Uint8Array {
  const [a, b, ...rest] = dotted.split(".").map(Number);
  const out = [40 * a + b];
  for (const n of rest) {
    const groups = [n & 0x7f];
    for (let v = n >>> 7; v > 0; v >>>= 7) groups.unshift((v & 0x7f) | 0x80);
    out.push(...groups);
  }
  return tlv(0x06, Uint8Array.from(out));
}
function utc(d: Date): Uint8Array {
  const s = d.toISOString().replace(/[-:T]/g, "").slice(2, 14) + "Z";
  return tlv(0x17, new TextEncoder().encode(s));
}
const name = (cn: string) => seq(set(seq(oid("2.5.4.3"), tlv(0x0c, new TextEncoder().encode(cn)))));
const SIG_ALG = { "SHA-256": seq(oid("1.2.840.10045.4.3.2")), "SHA-384": seq(oid("1.2.840.10045.4.3.3")) };
type Hash = keyof typeof SIG_ALG;
const CA_EXT = seq(oid("2.5.29.19"), bool(true), octets(seq(bool(true))));
export const NONCE_OID = "1.2.840.113635.100.8.2";

// Apple's shape: a P-384 root signs a P-384 intermediate with SHA-384, which signs the P-256 leaf with SHA-256.
type Curve = "P-256" | "P-384";
const newKey = (namedCurve: Curve) => crypto.subtle.generateKey({ name: "ECDSA", namedCurve }, true, ["sign", "verify"]) as Promise<CryptoKeyPair>;

export interface Validity { notBefore: Date; notAfter: Date }
const LONG: Validity = { notBefore: new Date("2020-01-01T00:00:00Z"), notAfter: new Date("2045-01-01T00:00:00Z") };

async function certificate(o: { subject: string; issuer: string; key: CryptoKey; signer: CryptoKey; hash: Hash; extensions: Uint8Array[]; validity?: Validity; serial: number }): Promise<Uint8Array> {
  const v = o.validity ?? LONG;
  const alg = SIG_ALG[o.hash], size = (o.signer.algorithm as { namedCurve?: string }).namedCurve === "P-384" ? 48 : 32;
  const spki = new Uint8Array((await crypto.subtle.exportKey("spki", o.key)) as ArrayBuffer);
  const tbs = seq(
    explicit(0, int(u8(2))), int(u8(o.serial)), alg, name(o.issuer), seq(utc(v.notBefore), utc(v.notAfter)), name(o.subject), spki,
    explicit(3, seq(...o.extensions)),
  );
  const raw = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: o.hash }, o.signer, tbs));
  if (raw.length !== 2 * size) throw new Error("unexpected signature size");
  return seq(tbs, alg, bits(seq(int(raw.subarray(0, size)), int(raw.subarray(size)))));
}

export interface CA { keys: CryptoKeyPair; cert: Uint8Array; name: string }

export async function makeRoot(cn = "Test App Attestation Root CA"): Promise<CA> {
  const keys = await newKey("P-384");
  return { keys, name: cn, cert: await certificate({ subject: cn, issuer: cn, key: keys.publicKey, signer: keys.privateKey, hash: "SHA-384", extensions: [CA_EXT], serial: 1 }) };
}

/** An intermediate issued by `root`; `signer` signs it with another key while still naming `root`, for a broken chain. */
export async function makeIntermediate(root: CA, signer = root.keys.privateKey): Promise<CA> {
  const keys = await newKey("P-384"), cn = "Test App Attestation CA 1";
  return { keys, name: cn, cert: await certificate({ subject: cn, issuer: root.name, key: keys.publicKey, signer, hash: "SHA-384", extensions: [CA_EXT], serial: 2 }) };
}

export function pem(der: Uint8Array): string {
  return `-----BEGIN CERTIFICATE-----\n${base64(der).replace(/.{64}/g, "$&\n")}\n-----END CERTIFICATE-----\n`;
}

type C = number | string | Uint8Array | C[] | { [k: string]: C };
function cbor(v: C): Uint8Array {
  const head = (major: number, n: number) =>
    n < 24 ? u8((major << 5) | n) : n < 0x100 ? u8((major << 5) | 24, n) : n < 0x10000 ? u8((major << 5) | 25, n >> 8, n & 0xff) : u8((major << 5) | 26, n >>> 24, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff);
  if (typeof v === "number") return v >= 0 ? head(0, v) : head(1, -1 - v);
  if (typeof v === "string") { const b = new TextEncoder().encode(v); return concat(head(3, b.length), b); }
  if (v instanceof Uint8Array) return concat(head(2, v.length), v);
  if (Array.isArray(v)) return concat(head(4, v.length), ...v.map(cbor));
  const entries = Object.entries(v);
  return concat(head(5, entries.length), ...entries.flatMap(([k, x]) => [cbor(k), cbor(x)]));
}

export interface AttestationOptions {
  appId: string;
  challenge: Uint8Array;
  /** Default `appattest` padded with zeros: production. */
  aaguid?: string;
  counter?: number;
  /** Hash a different challenge into the nonce. */
  nonceChallenge?: Uint8Array;
  /** Put a different credential ID in authData. */
  credentialId?: Uint8Array;
  leafValidity?: Validity;
  fmt?: string;
  /** Leave out the nonce extension. */
  noNonce?: boolean;
  /** Flip a byte of the leaf's signature. */
  badLeafSignature?: boolean;
  /** Default P-256, as Apple's leaf. */
  leafCurve?: Curve;
}

/** An attestation object over a fresh leaf key, issued by `ca`, and the key ID the app would send. */
export async function makeAttestation(ca: CA, o: AttestationOptions): Promise<{ attestation: Uint8Array; keyId: Uint8Array }> {
  const leafKeys = await newKey(o.leafCurve ?? "P-256");
  const point = new Uint8Array((await crypto.subtle.exportKey("raw", leafKeys.publicKey)) as ArrayBuffer);
  const keyId = await sha256(point);
  const aaguid = new TextEncoder().encode((o.aaguid ?? "appattest").padEnd(16, "\0"));
  const counter = new Uint8Array(4);
  new DataView(counter.buffer).setUint32(0, o.counter ?? 0);
  const credId = o.credentialId ?? keyId;
  const cose = cbor({ "1": 2, "3": -7 });
  const authData = concat(await sha256(new TextEncoder().encode(o.appId)), u8(0x40), counter, aaguid, u8(credId.length >> 8, credId.length & 0xff), credId, cose);
  const nonce = await sha256(concat(authData, await sha256(o.nonceChallenge ?? o.challenge)));
  const extensions = o.noNonce ? [] : [seq(oid(NONCE_OID), octets(seq(explicit(1, octets(nonce)))))];
  const leaf = await certificate({ subject: "test leaf", issuer: ca.name, key: leafKeys.publicKey, signer: ca.keys.privateKey, hash: "SHA-256", extensions, validity: o.leafValidity, serial: 3 });
  if (o.badLeafSignature) leaf[leaf.length - 5] ^= 0x01;
  const attestation = cbor({ fmt: o.fmt ?? "apple-appattest", attStmt: { x5c: [leaf, ca.cert], receipt: u8(1, 2, 3) }, authData });
  return { attestation, keyId };
}
