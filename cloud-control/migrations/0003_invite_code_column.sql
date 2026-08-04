ALTER TABLE invites ADD COLUMN code TEXT NOT NULL DEFAULT '';
CREATE INDEX IF NOT EXISTS idx_invites_code ON invites(code);
