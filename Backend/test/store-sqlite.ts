import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import type { Sql, Statement } from "../src/store";

const migrations = join(import.meta.dirname, "..", "migrations");

/** The store shim over node's built-in SQLite, in memory, with every migration applied (7.3). */
export function sqliteSql(): Sql & { db: DatabaseSync } {
  const db = new DatabaseSync(":memory:");
  db.exec("PRAGMA foreign_keys = ON");
  for (const f of readdirSync(migrations).filter((f) => f.endsWith(".sql")).sort()) db.exec(readFileSync(join(migrations, f), "utf8"));
  const p = (params: unknown[]) => params as SQLInputValue[];
  return {
    db,
    async all<T>(sql: string, ...params: unknown[]) { return db.prepare(sql).all(...p(params)) as T[]; },
    async run(sql: string, ...params: unknown[]) { return { changes: Number(db.prepare(sql).run(...p(params)).changes) }; },
    async batch(statements: Statement[]) {
      db.exec("BEGIN");
      try {
        for (const s of statements) db.prepare(s.sql).run(...p(s.params));
        db.exec("COMMIT");
      } catch (e) {
        db.exec("ROLLBACK");
        throw e;
      }
    },
  };
}
