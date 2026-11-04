// Byte helpers shared by tokens, App Attest and the download route.

export function base64(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

export function base64url(bytes: Uint8Array): string {
  return base64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Standard or URL-safe base64, padded or not; null when it is neither. */
export function fromBase64(s: string): Uint8Array | null {
  if (!/^[A-Za-z0-9+/_-]*={0,2}$/.test(s)) return null;
  const std = s.replace(/-/g, "+").replace(/_/g, "/").replace(/=+$/, "");
  if (std.length % 4 === 1) return null;
  try {
    const bin = atob(std + "=".repeat((4 - (std.length % 4)) % 4));
    return Uint8Array.from(bin, (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
}

export function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.byteLength, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.byteLength; }
  return out;
}

/** Constant time in the length of the inputs. */
export function equal(a: Uint8Array, b: Uint8Array): boolean {
  if (a.byteLength !== b.byteLength) return false;
  let d = 0;
  for (let i = 0; i < a.byteLength; i++) d |= a[i] ^ b[i];
  return d === 0;
}

export function hex(bytes: Uint8Array): string {
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function sha256(bytes: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}
