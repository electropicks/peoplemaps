import { StorageUnavailable } from "./errors";
import type { Sql, Statement } from "./store";

// D1 answers every query with an error once the Free plan's daily row limits are spent (4.6). The exact wording is
// checked at the first deploy; anything else is an ordinary failure (500).
const LIMIT_ERROR = /limit|exceeded|quota/i;

async function guard<T>(f: () => Promise<T>): Promise<T> {
  try {
    return await f();
  } catch (e) {
    if (e instanceof Error && LIMIT_ERROR.test(e.message)) throw new StorageUnavailable("D1 limits spent");
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
