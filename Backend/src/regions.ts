import { base64url } from "./bytes";
import type { Deps } from "./deps";
import { verifyDownloadToken } from "./download-token";
import { errorResponse, HttpError } from "./errors";
import { limitDownloads } from "./ratelimit";

// GET /v1/regions/{release}/{object} (Docs/REPORTS.md 4.7): a region's generated files from the private R2 bucket, to a
// holder of a download token. Only `expected` outputs are served, never importer inputs or `source/`.

export const RELEASE = /^data-[a-z-]+-\d{4}-\d{2}[a-z]?$/;
export const OBJECT = /^[a-z]+(-[a-z]+)*--expected__[A-Za-z0-9.-]+$/;

/** The key ID behind `Authorization: Bearer pmd_…`; 401 when the token is missing, bad or expired. The log route (4.8) uses it too. */
export async function authorize(request: Request, deps: Deps): Promise<string> {
  const m = /^Bearer (\S+)$/.exec(request.headers.get("authorization") ?? "");
  const secret = deps.attest.tokenSecret;
  const keyId = m && secret.length >= 32 ? await verifyDownloadToken(secret, m[1], deps.clock.now()) : null;
  if (!keyId) throw new HttpError("unauthorized", "Missing, expired or invalid download token.");
  return base64url(keyId);
}

type Range = { offset: number; length: number };

/** A single `bytes=` range against `size`: a range, "unsatisfiable", or null to send the whole object (RFC 9110 14.2). */
export function parseRange(header: string | null, size: number): Range | "unsatisfiable" | null {
  const m = header ? /^bytes=(\d*)-(\d*)$/.exec(header.trim()) : null;
  if (!m || (m[1] === "" && m[2] === "")) return null;
  if (m[1] === "") {
    const suffix = Number(m[2]);
    if (suffix === 0 || size === 0) return "unsatisfiable";
    const length = Math.min(suffix, size);
    return { offset: size - length, length };
  }
  const start = Number(m[1]), end = m[2] === "" ? Infinity : Number(m[2]);
  if (end < start) return null;
  if (start >= size) return "unsatisfiable";
  return { offset: start, length: Math.min(end, size - 1) - start + 1 };
}

export async function downloadRegionFile(request: Request, deps: Deps, release: string, object: string): Promise<Response> {
  const keyId = await authorize(request, deps);
  await limitDownloads(deps, keyId);
  if (!RELEASE.test(release) || !OBJECT.test(object)) throw new HttpError("not_found", "No such file.");
  const key = `${release}/${object}`;
  const missing = () => new HttpError("not_found", "No such file.");

  let range: Range | undefined;
  if (request.headers.has("range")) {
    const head = await deps.data.head(key);
    if (!head) throw missing();
    const ifRange = request.headers.get("if-range");
    if (ifRange === null || ifRange === head.httpEtag) {
      const r = parseRange(request.headers.get("range"), head.size);
      if (r === "unsatisfiable") {
        const res = errorResponse(new HttpError("range_not_satisfiable", "The range is outside the file."));
        res.headers.set("Content-Range", `bytes */${head.size}`);
        return res;
      }
      range = r ?? undefined;
    }
  }

  const obj = await deps.data.get(key, { range, onlyIf: request.headers });
  if (!obj) throw missing();
  const headers = new Headers();
  obj.writeHttpMetadata(headers);
  headers.set("ETag", obj.httpEtag);
  headers.set("Last-Modified", obj.uploaded.toUTCString());
  headers.set("Accept-Ranges", "bytes");
  headers.set("Cache-Control", "no-store");
  if (!("body" in obj)) {
    const notModified = request.headers.has("if-none-match") || request.headers.has("if-modified-since");
    if (notModified) return new Response(null, { status: 304, headers });
    const res = errorResponse(new HttpError("precondition_failed", "The file has changed."));
    res.headers.set("ETag", obj.httpEtag);
    return res;
  }
  if (!headers.has("Content-Type")) headers.set("Content-Type", "application/octet-stream");
  if (range) {
    headers.set("Content-Range", `bytes ${range.offset}-${range.offset + range.length - 1}/${obj.size}`);
    headers.set("Content-Length", String(range.length));
    return new Response(obj.body, { status: 206, headers });
  }
  headers.set("Content-Length", String(obj.size));
  return new Response(obj.body, { status: 200, headers });
}
