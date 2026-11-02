import { StorageUnavailable } from "./errors";
import type { Sql, Statement } from "./store";

// D1's documented errors once its daily row or size limits are reached (4.6). Anything else is an ordinary failure (500).
const DAILY_LIMIT = /free tier daily row (read|write) limit/;
const SIZE_LIMIT = /Exceeded maximum DB size|maximum account storage limit/;

async function guard<T>(f: () => Promise<T>): Promise<T> {
  try {
    return await f();
  } catch (e) {
    if (e instanceof Error && DAILY_LIMIT.test(e.message)) throw new StorageUnavailable("D1 daily limits spent");
    if (e instanceof Error && SIZE_LIMIT.test(e.message)) throw new StorageUnavailable("D1 full", false);
    throw e;
  }
}

/** The run/all/batch shim over the D1 binding. */
export function d1Sql(db: D1Database): Sql {
  const prep = (s: Statement) => db.prepare(s.sql).bind(...s.params);
  return {
    all: <T>(sql: string, ...params: unknown[]) => guard(async () => (await prep({ sql, params }).all<T>()).results),
    run: (sql: string, ...params: unknown[]) => guard(async () => ({ changes: (await prep({ sql, params }).run()).meta.changes ?? 0 })),
    batch: (statements: Statement[]) => guard(async () => { await db.batch(statements.map(prep)); }),
  };
}
