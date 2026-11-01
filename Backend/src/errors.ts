/** The error envelope of Docs/REPORTS.md 4.6. Every response carries `Cache-Control: no-store`. */
export type ErrorCode =
  | "unauthorized" | "not_found" | "invalid_report" | "too_large" | "conflict"
  | "rate_limited" | "storage_unavailable" | "internal";

const statusOf: Record<ErrorCode, number> = {
  unauthorized: 401, not_found: 404, invalid_report: 400, too_large: 413, conflict: 409,
  rate_limited: 429, storage_unavailable: 503, internal: 500,
};

export class HttpError extends Error {
  constructor(readonly code: ErrorCode, message: string, readonly field?: string, readonly retryAfter?: number) {
    super(message);
  }
  get status() { return statusOf[this.code]; }
}

/** Thrown by a store shim when the database refuses work because its daily limits are spent (4.6). */
export class StorageUnavailable extends Error {}

export function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(status === 204 ? null : JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...headers },
  });
}

export function errorResponse(e: HttpError): Response {
  const body: Record<string, string> = { error: e.code, message: e.message };
  if (e.field !== undefined) body.field = e.field;
  return json(e.status, body, e.retryAfter !== undefined ? { "Retry-After": String(e.retryAfter) } : {});
}

export function invalid(field: string, message = "Invalid value."): HttpError {
  return new HttpError("invalid_report", message, field);
}
