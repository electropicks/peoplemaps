-- Trip logs sent from the app, Docs/REPORTS.md 4.8. Never edit once applied to the deployed database; add 000N_name.sql instead.
-- The file itself, sealed to the owner's key, is in the private R2 bucket peoplemaps-logs under `key`; this row lists it
-- and drives its deletion.
CREATE TABLE log_uploads (
  key          TEXT PRIMARY KEY,  -- <batch UUID>/<file name>.enc
  batch        TEXT NOT NULL,     -- one per tap of Send in the app
  name         TEXT NOT NULL,
  bytes        INTEGER NOT NULL,
  sha256       TEXT NOT NULL,     -- hex, of the sealed bytes; checked on upload and again by scripts/pull-logs.ts
  delete_hash  TEXT NOT NULL,     -- hex SHA-256 of the batch's delete secret, which only the sending phone holds
  received_at  TEXT NOT NULL,     -- hour precision
  expires_at   TEXT NOT NULL
);
CREATE INDEX log_uploads_batch ON log_uploads(batch);
CREATE INDEX log_uploads_received ON log_uploads(received_at);
CREATE INDEX log_uploads_expires ON log_uploads(expires_at);
