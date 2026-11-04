// The CBOR subset an App Attest attestation object uses (RFC 8949): integers, byte and text strings, arrays, maps,
// false, true and null, all definite length. Anything else throws.

export type CBOR = number | Uint8Array | string | CBOR[] | Map<CBOR, CBOR> | boolean | null;

const MAX_DEPTH = 8;

export function decodeCBOR(bytes: Uint8Array): CBOR {
  let at = 0;
  const fail = (why: string): never => { throw new Error(`cbor: ${why}`); };
  const byte = () => (at < bytes.length ? bytes[at++] : fail("truncated"));
  const take = (n: number) => {
    if (n > bytes.length - at) fail("truncated");
    const out = bytes.subarray(at, at + n);
    at += n;
    return out;
  };
  const arg = (info: number): number => {
    if (info < 24) return info;
    if (info > 27) return fail("indefinite or reserved length");
    let n = 0;
    for (let i = 0; i < 1 << (info - 24); i++) n = n * 256 + byte();
    return Number.isSafeInteger(n) ? n : fail("integer too large");
  };
  const item = (depth: number): CBOR => {
    if (depth > MAX_DEPTH) fail("too deep");
    const head = byte();
    const major = head >> 5, info = head & 31;
    switch (major) {
      case 0: return arg(info);
      case 1: return -1 - arg(info);
      case 2: return take(arg(info)).slice();
      case 3: return new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(take(arg(info)));
      case 4: {
        const n = arg(info), out: CBOR[] = [];
        for (let i = 0; i < n; i++) out.push(item(depth + 1));
        return out;
      }
      case 5: {
        const n = arg(info), out = new Map<CBOR, CBOR>();
        for (let i = 0; i < n; i++) out.set(item(depth + 1), item(depth + 1));
        return out;
      }
      case 7:
        if (info === 20) return false;
        if (info === 21) return true;
        if (info === 22) return null;
        return fail("unsupported simple value");
      default: return fail("unsupported type");
    }
  };
  const out = item(0);
  if (at !== bytes.length) fail("trailing bytes");
  return out;
}
