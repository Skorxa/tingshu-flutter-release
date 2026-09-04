ALTER TABLE sessions ADD COLUMN prev_refresh_hash TEXT;
ALTER TABLE sessions ADD COLUMN prev_refresh_expires_at INTEGER;
CREATE INDEX IF NOT EXISTS idx_sessions_prev_refresh ON sessions(prev_refresh_hash);
