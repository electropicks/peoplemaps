-- Problem reports, Docs/REPORTS.md 5.1. Never edit after it ships; add 000N_name.sql instead.
CREATE TABLE installs (
  id            TEXT PRIMARY KEY,
  token_hash    TEXT NOT NULL UNIQUE,
  app_version   TEXT NOT NULL,
  created_at    TEXT NOT NULL,
  last_seen_at  TEXT NOT NULL
);
CREATE INDEX installs_created ON installs(created_at);

CREATE TABLE reports (
  id             TEXT PRIMARY KEY,
  install_id     TEXT NOT NULL REFERENCES installs(id) ON DELETE CASCADE,
  received_at    TEXT NOT NULL,
  expires_at     TEXT NOT NULL,
  body_hash      TEXT NOT NULL,
  category       TEXT NOT NULL,
  mode           TEXT NOT NULL,
  data_version   TEXT NOT NULL,
  app_version    TEXT NOT NULL,
  cell           TEXT NOT NULL,
  public_json    TEXT NOT NULL,
  exact_json     TEXT,
  issue_number   INTEGER,
  issue_node_id  TEXT,
  issue_url      TEXT,
  issue_filed_at TEXT,
  issue_state    TEXT NOT NULL DEFAULT 'held',
  reviewed_by    TEXT,
  issue_attempts INTEGER NOT NULL DEFAULT 0,
  issue_error    TEXT
);
CREATE INDEX reports_install ON reports(install_id);
CREATE INDEX reports_expires ON reports(expires_at);
CREATE INDEX reports_pending ON reports(issue_state) WHERE issue_state = 'pending';
CREATE INDEX reports_held ON reports(received_at) WHERE issue_state = 'held';
CREATE INDEX reports_filed ON reports(issue_filed_at) WHERE issue_filed_at IS NOT NULL;
CREATE UNIQUE INDEX reports_issue ON reports(issue_number) WHERE issue_number IS NOT NULL;

CREATE TABLE aggregates (
  week      TEXT NOT NULL,
  cell      TEXT NOT NULL,
  category  TEXT NOT NULL,
  mode      TEXT NOT NULL,
  count     INTEGER NOT NULL,
  PRIMARY KEY (week, cell, category, mode)
);

CREATE TABLE maintainer_reads (
  issue_number INTEGER NOT NULL,
  login        TEXT NOT NULL,
  read_at      TEXT NOT NULL
);
