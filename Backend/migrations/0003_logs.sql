-- Trip logs sent from the app, Docs/REPORTS.md 4.8. Never edit once applied to the deployed database; add 000N_name.sql instead.
-- The file itself is in the private R2 bucket peoplemaps-logs under `key`; this row lists it and drives its deletion.
CREATE TABLE log_uploads (
  key          TEXT PRIMARY KEY,  -- <batch UUID>/<file name>
  batch        TEXT NOT NULL,     -- one per tap of Send in the app
  name         TEXT NOT NULL,
  bytes        INTEGER NOT NULL,
  sha256       TEXT NOT NULL,     -- hex, checked on upload and again by scripts/pull-logs.ts
  received_at  TEXT NOT NULL,     -- hour precision
  expires_at   TEXT NOT NULL
);
CREATE INDEX log_uploads_received ON log_uploads(received_at);
CREATE INDEX log_uploads_expires ON log_uploads(expires_at);
