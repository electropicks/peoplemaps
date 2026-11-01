import { StorageUnavailable } from "./errors";
import type { Sql, Statement } from "./store";

// D1's documented errors once its daily row or size limits are reached (4.6). Anything else is an ordinary failure (500).
const LIMIT_ERROR = /free tier daily row (read|write) limit|Exceeded maximum DB size|maximum account storage limit/;

async function guard<T>(f: () => Promise<T>): Promise<T> {
  try {
    return await f();
  } catch (e) {
    if (e instanceof Error && LIMIT_ERROR.test(e.message)) throw new StorageUnavailable("D1 limits reached");
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
