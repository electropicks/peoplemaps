-- Problem reports, Docs/REPORTS.md 5.1. Never edit once applied to the deployed database; add 000N_name.sql instead.
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
  exact_json     TEXT
);
CREATE INDEX reports_install ON reports(install_id);
CREATE INDEX reports_expires ON reports(expires_at);

CREATE TABLE aggregates (
  week      TEXT NOT NULL,
  cell      TEXT NOT NULL,
  category  TEXT NOT NULL,
  mode      TEXT NOT NULL,
  count     INTEGER NOT NULL,
  PRIMARY KEY (week, cell, category, mode)
);
