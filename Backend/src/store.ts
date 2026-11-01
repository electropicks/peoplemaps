// Plain SQLite over a run/all/batch shim (Docs/REPORTS.md 7.1). store-d1.ts and test/store-sqlite.ts implement Sql.

export interface Statement { sql: string; params: unknown[] }
/** The only thing the store needs from a database. A shim throws `StorageUnavailable` when the database's limits are spent. */
export interface Sql {
  all<T>(sql: string, ...params: unknown[]): Promise<T[]>;
  run(sql: string, ...params: unknown[]): Promise<{ changes: number }>;
  /** Runs every statement in one transaction. */
  batch(statements: Statement[]): Promise<void>;
}
const stmt = (sql: string, ...params: unknown[]): Statement => ({ sql, params });

export interface InstallRow { id: string; token_hash: string; app_version: string; created_at: string; last_seen_at: string }
export interface ReportRow {
  id: string; install_id: string; received_at: string; expires_at: string; body_hash: string;
  category: string;
  public_json: string; exact_json: string | null;
}
export interface RetentionCounts { reports: number; installs: number }

const count = async (sql: Sql, q: string, ...p: unknown[]) => (await sql.all<{ n: number }>(q, ...p))[0]?.n ?? 0;

export class Store {
  constructor(readonly sql: Sql) {}

  // installs

  async insertInstall(row: InstallRow): Promise<void> {
    await this.sql.run(
      "INSERT INTO installs (id, token_hash, app_version, created_at, last_seen_at) VALUES (?, ?, ?, ?, ?)",
      row.id, row.token_hash, row.app_version, row.created_at, row.last_seen_at,
    );
  }
  async installByTokenHash(hash: string): Promise<InstallRow | null> {
    return (await this.sql.all<InstallRow>("SELECT * FROM installs WHERE token_hash = ?", hash))[0] ?? null;
  }
  async touchInstall(id: string, hour: string): Promise<void> {
    await this.sql.run("UPDATE installs SET last_seen_at = ? WHERE id = ? AND last_seen_at <> ?", hour, id, hour);
  }
  countInstallsSince(since: string): Promise<number> {
    return count(this.sql, "SELECT COUNT(*) AS n FROM installs WHERE created_at >= ?", since);
  }
  /** Every report of the install and the install itself, in one batch (4.4). */
  async deleteInstall(id: string): Promise<void> {
    await this.sql.batch([stmt("DELETE FROM reports WHERE install_id = ?", id), stmt("DELETE FROM installs WHERE id = ?", id)]);
  }

  // reports

  async reportById(id: string): Promise<ReportRow | null> {
    return (await this.sql.all<ReportRow>("SELECT * FROM reports WHERE id = ?", id))[0] ?? null;
  }
  reportsByInstall(installID: string): Promise<ReportRow[]> {
    return this.sql.all<ReportRow>("SELECT * FROM reports WHERE install_id = ? ORDER BY received_at, id", installID);
  }
  countReportsSince(installID: string, since: string): Promise<number> {
    return count(this.sql, "SELECT COUNT(*) AS n FROM reports WHERE install_id = ? AND received_at >= ?", installID, since);
  }
  /** The row and the install's app version, in one batch so a refused write keeps nothing (4.6). */
  async insertReport(row: ReportRow, appVersion: string): Promise<void> {
    await this.sql.batch([
      stmt(
        "INSERT INTO reports (id, install_id, received_at, expires_at, body_hash, category, public_json, exact_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        row.id, row.install_id, row.received_at, row.expires_at, row.body_hash, row.category, row.public_json, row.exact_json,
      ),
      stmt("UPDATE installs SET app_version = ? WHERE id = ?", appVersion, row.install_id),
    ]);
  }
  async deleteReport(id: string): Promise<void> {
    await this.sql.run("DELETE FROM reports WHERE id = ?", id);
  }
  // retention (5.3)

  async retain(now: string, idleBefore: string): Promise<RetentionCounts> {
    const reports = (await this.sql.run("DELETE FROM reports WHERE expires_at < ?", now)).changes;
    const installs = (await this.sql.run(
      "DELETE FROM installs WHERE last_seen_at < ? AND NOT EXISTS (SELECT 1 FROM reports WHERE reports.install_id = installs.id)", idleBefore,
    )).changes;
    return { reports, installs };
  }
}
