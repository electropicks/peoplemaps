-- App Attest, Docs/REPORTS.md 4.5 and 5.1. Never edit once applied to the deployed database; add 000N_name.sql instead.
CREATE TABLE attest_challenges (
  id          TEXT PRIMARY KEY,   -- SHA-256 hex of the 32 challenge bytes
  expires_at  TEXT NOT NULL       -- second precision: issued + 5 minutes
);
CREATE INDEX attest_challenges_expires ON attest_challenges(expires_at);

CREATE TABLE attest_keys (
  key_id       TEXT PRIMARY KEY,  -- base64 App Attest key ID, the SHA-256 of the public key
  public_key   TEXT NOT NULL,     -- base64 SubjectPublicKeyInfo of the attested key
  counter      INTEGER NOT NULL,  -- 0 at attestation; assertions would raise it
  environment  TEXT NOT NULL,     -- production or development
  created_at   TEXT NOT NULL      -- hour precision
);
CREATE INDEX attest_keys_created ON attest_keys(created_at);
