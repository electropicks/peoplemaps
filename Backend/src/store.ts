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

export type IssueState = "held" | "pending" | "opened" | "failed" | "rejected";

export interface InstallRow { id: string; token_hash: string; app_version: string; created_at: string; last_seen_at: string }
export interface ReportRow {
  id: string; install_id: string; received_at: string; expires_at: string; body_hash: string;
  category: string; mode: string; data_version: string; app_version: string; cell: string;
  public_json: string; exact_json: string | null;
  issue_number: number | null; issue_node_id: string | null; issue_url: string | null; issue_filed_at: string | null;
  issue_state: IssueState; reviewed_by: string | null; issue_attempts: number; issue_error: string | null;
}
export type NewReport = Omit<ReportRow, "issue_number" | "issue_node_id" | "issue_url" | "issue_filed_at" | "reviewed_by" | "issue_attempts" | "issue_error">;
export interface RetentionCounts { reports: number; installs: number; maintainerReads: number }

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
  async reportByIssueNumber(n: number): Promise<ReportRow | null> {
    return (await this.sql.all<ReportRow>("SELECT * FROM reports WHERE issue_number = ?", n))[0] ?? null;
  }
  reportsByInstall(installID: string): Promise<ReportRow[]> {
    return this.sql.all<ReportRow>("SELECT * FROM reports WHERE install_id = ? ORDER BY received_at, id", installID);
  }
  countReportsSince(installID: string, since: string): Promise<number> {
    return count(this.sql, "SELECT COUNT(*) AS n FROM reports WHERE install_id = ? AND received_at >= ?", installID, since);
  }
  /** The row, its aggregate bump and the install's app version, in one batch so a refused write keeps nothing (4.6, 5.2). */
  async insertReport(row: NewReport, week: string): Promise<void> {
    await this.sql.batch([
      stmt(
        `INSERT INTO reports (id, install_id, received_at, expires_at, body_hash, category, mode, data_version, app_version, cell, public_json, exact_json, issue_state)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        row.id, row.install_id, row.received_at, row.expires_at, row.body_hash, row.category, row.mode, row.data_version,
        row.app_version, row.cell, row.public_json, row.exact_json, row.issue_state,
      ),
      stmt(
        `INSERT INTO aggregates (week, cell, category, mode, count) VALUES (?, ?, ?, ?, 1)
         ON CONFLICT (week, cell, category, mode) DO UPDATE SET count = count + 1`,
        week, row.cell, row.category, row.mode,
      ),
      stmt("UPDATE installs SET app_version = ? WHERE id = ?", row.app_version, row.install_id),
    ]);
  }
  async deleteReport(id: string): Promise<void> {
    await this.sql.run("DELETE FROM reports WHERE id = ?", id);
  }
  heldReports(): Promise<ReportRow[]> {
    return this.sql.all<ReportRow>("SELECT * FROM reports WHERE issue_state = 'held' ORDER BY received_at, id");
  }
  pendingReports(limit: number, maxAttempts: number): Promise<ReportRow[]> {
    return this.sql.all<ReportRow>(
      "SELECT * FROM reports WHERE issue_state = 'pending' AND issue_attempts < ? ORDER BY received_at, id LIMIT ?", maxAttempts, limit,
    );
  }
  /** Moves a row out of `held`; false when it was no longer held. */
  async review(id: string, state: "pending" | "rejected", login: string): Promise<boolean> {
    const r = await this.sql.run("UPDATE reports SET issue_state = ?, reviewed_by = ? WHERE id = ? AND issue_state = 'held'", state, login, id);
    return r.changes > 0;
  }
  async markFiled(id: string, issue: { number: number; nodeId: string; url: string }, filedAt: string): Promise<void> {
    await this.sql.run(
      "UPDATE reports SET issue_state = 'opened', issue_number = ?, issue_node_id = ?, issue_url = ?, issue_filed_at = ?, issue_error = NULL WHERE id = ?",
      issue.number, issue.nodeId, issue.url, filedAt, id,
    );
  }
  async markIssueFailure(id: string, error: string, maxAttempts: number): Promise<void> {
    await this.sql.run(
      `UPDATE reports SET issue_attempts = issue_attempts + 1, issue_error = ?,
         issue_state = CASE WHEN issue_attempts + 1 >= ? THEN 'failed' ELSE issue_state END WHERE id = ?`,
      error, maxAttempts, id,
    );
  }
  countFiledSince(since: string): Promise<number> {
    return count(this.sql, "SELECT COUNT(*) AS n FROM reports WHERE issue_filed_at IS NOT NULL AND issue_filed_at >= ?", since);
  }

  // maintainer reads

  async insertMaintainerRead(issueNumber: number, login: string, hour: string): Promise<void> {
    await this.sql.run("INSERT INTO maintainer_reads (issue_number, login, read_at) VALUES (?, ?, ?)", issueNumber, login, hour);
  }

  // retention (5.3)

  async retain(now: string, idleBefore: string, readsBefore: string): Promise<RetentionCounts> {
    const reports = (await this.sql.run("DELETE FROM reports WHERE expires_at < ?", now)).changes;
    const installs = (await this.sql.run(
      "DELETE FROM installs WHERE last_seen_at < ? AND NOT EXISTS (SELECT 1 FROM reports WHERE reports.install_id = installs.id)", idleBefore,
    )).changes;
    const maintainerReads = (await this.sql.run("DELETE FROM maintainer_reads WHERE read_at < ?", readsBefore)).changes;
    return { reports, installs, maintainerReads };
  }
}
