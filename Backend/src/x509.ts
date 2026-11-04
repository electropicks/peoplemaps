import { equal, fromBase64 } from "./bytes";

// Just enough DER and X.509 to check an App Attest chain with WebCrypto: ECDSA P-256 and P-384 keys, ecdsa-with-SHA256
// and -SHA384 signatures, validity, issuer and subject names, basic constraints and raw extension values.

/** One DER element: `raw` is the whole TLV, `body` its contents. */
export interface DER { tag: number; raw: Uint8Array; body: Uint8Array }

const fail = (why: string): never => { throw new Error(`der: ${why}`); };

export function readDER(bytes: Uint8Array, at = 0): DER {
  if (bytes.length - at < 2) fail("truncated");
  const tag = bytes[at];
  if ((tag & 0x1f) === 0x1f) fail("high tag number");
  let len = bytes[at + 1], head = 2;
  if (len & 0x80) {
    const n = len & 0x7f;
    if (n === 0 || n > 4 || bytes.length - at < 2 + n) fail("bad length");
    len = 0;
    for (let i = 0; i < n; i++) len = len * 256 + bytes[at + 2 + i];
    head += n;
  }
  if (bytes.length - at - head < len) fail("truncated");
  return { tag, raw: bytes.subarray(at, at + head + len), body: bytes.subarray(at + head, at + head + len) };
}

export function children(el: DER): DER[] {
  const out: DER[] = [];
  for (let at = 0; at < el.body.length;) {
    const c = readDER(el.body, at);
    out.push(c);
    at += c.raw.length;
  }
  return out;
}

function expect(el: DER | undefined, tag: number): DER {
  return el && el.tag === tag ? el : fail(`expected tag ${tag}`);
}

export function oid(el: DER): string {
  const b = expect(el, 0x06).body, parts: number[] = [];
  let v = 0;
  for (const x of b) {
    v = v * 128 + (x & 0x7f);
    if (!(x & 0x80)) { parts.push(v); v = 0; }
  }
  const first = parts.shift() ?? fail("empty oid");
  const head = first < 80 ? [Math.floor(first / 40), first % 40] : [2, first - 80];
  return [...head, ...parts].join(".");
}

function time(el: DER): Date {
  const s = new TextDecoder().decode(el.body);
  const m = el.tag === 0x17 ? /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(s) : el.tag === 0x18 ? /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(s) : null;
  if (!m) return fail("bad time");
  let y = Number(m[1]);
  if (el.tag === 0x17) y += y < 50 ? 2000 : 1900;
  return new Date(Date.UTC(y, Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6])));
}

const CURVES: Record<string, { name: string; size: number }> = {
  "1.2.840.10045.3.1.7": { name: "P-256", size: 32 },
  "1.3.132.0.34": { name: "P-384", size: 48 },
};
const HASHES: Record<string, string> = { "1.2.840.10045.4.3.2": "SHA-256", "1.2.840.10045.4.3.3": "SHA-384" };
const EC_PUBLIC_KEY = "1.2.840.10045.2.1";
const BASIC_CONSTRAINTS = "2.5.29.19";

export interface Certificate {
  tbs: Uint8Array;
  hash: string;
  signature: Uint8Array;
  issuer: Uint8Array;
  subject: Uint8Array;
  notBefore: Date;
  notAfter: Date;
  /** The SubjectPublicKeyInfo, as WebCrypto imports it. */
  spki: Uint8Array;
  curve: { name: string; size: number };
  /** The uncompressed EC point. */
  point: Uint8Array;
  extensions: Map<string, Uint8Array>;
}

export function parseCertificate(der: Uint8Array): Certificate {
  const cert = expect(readDER(der), 0x30);
  if (cert.raw.length !== der.length) fail("trailing bytes");
  const [tbsEl, algEl, sigEl] = children(cert);
  const tbs = children(expect(tbsEl, 0x30));
  let i = tbs[0]?.tag === 0xa0 ? 1 : 0;
  i++; // serial
  i++; // signature algorithm, repeated below
  const issuer = expect(tbs[i++], 0x30).raw;
  const [nb, na] = children(expect(tbs[i++], 0x30));
  const subject = expect(tbs[i++], 0x30).raw;
  const spkiEl = expect(tbs[i++], 0x30);
  const [keyAlg, keyBits] = children(spkiEl);
  const [keyType, curveOID] = children(expect(keyAlg, 0x30));
  if (oid(keyType) !== EC_PUBLIC_KEY) fail("not an EC key");
  const curve = CURVES[oid(curveOID)] ?? fail("unsupported curve");
  const bits = expect(keyBits, 0x03).body;
  if (bits[0] !== 0 || bits[1] !== 0x04 || bits.length !== 2 + 2 * curve.size) fail("bad public key");
  const extensions = new Map<string, Uint8Array>();
  for (; i < tbs.length; i++) {
    if (tbs[i].tag !== 0xa3) continue;
    for (const ext of children(expect(children(tbs[i])[0], 0x30))) {
      const parts = children(expect(ext, 0x30));
      extensions.set(oid(parts[0]), expect(parts[parts.length - 1], 0x04).body);
    }
  }
  const hash = HASHES[oid(children(expect(algEl, 0x30))[0])] ?? fail("unsupported signature algorithm");
  const sig = expect(sigEl, 0x03).body;
  if (sig[0] !== 0) fail("bad signature");
  return {
    tbs: tbsEl.raw, hash, signature: sig.subarray(1), issuer, subject, notBefore: time(nb), notAfter: time(na),
    spki: spkiEl.raw, curve, point: bits.subarray(1), extensions,
  };
}

/** An ECDSA-Sig-Value as WebCrypto's r || s, each `size` bytes. */
function rawSignature(der: Uint8Array, size: number): Uint8Array {
  const parts = children(expect(readDER(der), 0x30));
  if (parts.length !== 2) fail("bad signature");
  const out = new Uint8Array(2 * size);
  parts.forEach((p, k) => {
    let v = expect(p, 0x02).body;
    while (v.length > 1 && v[0] === 0) v = v.subarray(1);
    if (v.length > size) fail("bad signature");
    out.set(v, (k + 1) * size - v.length);
  });
  return out;
}

/** Whether `child` is signed by `parent`'s key, names `parent` as issuer, and `parent` may issue certificates. */
export async function issuedBy(child: Certificate, parent: Certificate): Promise<boolean> {
  if (!equal(child.issuer, parent.subject) || !isCA(parent)) return false;
  const key = await crypto.subtle.importKey("spki", parent.spki, { name: "ECDSA", namedCurve: parent.curve.name }, false, ["verify"]);
  let sig: Uint8Array;
  try {
    sig = rawSignature(child.signature, parent.curve.size);
  } catch {
    return false;
  }
  return crypto.subtle.verify({ name: "ECDSA", hash: child.hash }, key, sig, child.tbs);
}

function isCA(cert: Certificate): boolean {
  const bc = cert.extensions.get(BASIC_CONSTRAINTS);
  if (!bc) return false;
  const first = children(expect(readDER(bc), 0x30))[0];
  return first?.tag === 0x01 && first.body[0] !== 0;
}

export function validAt(cert: Certificate, now: Date): boolean {
  return cert.notBefore <= now && now <= cert.notAfter;
}

export function pemToDER(pem: string): Uint8Array {
  const m = /-----BEGIN CERTIFICATE-----([\s\S]+?)-----END CERTIFICATE-----/.exec(pem);
  return (m && fromBase64(m[1].replace(/\s+/g, ""))) ?? fail("bad PEM");
}
