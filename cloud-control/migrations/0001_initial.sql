PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
  expires_at INTEGER,
  max_devices INTEGER NOT NULL DEFAULT 1 CHECK (max_devices BETWEEN 1 AND 20),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS invites (
  id TEXT PRIMARY KEY,
  code_hash TEXT NOT NULL UNIQUE,
  label TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked')),
  expires_at INTEGER,
  max_uses INTEGER NOT NULL DEFAULT 1 CHECK (max_uses BETWEEN 1 AND 100),
  used_count INTEGER NOT NULL DEFAULT 0 CHECK (used_count >= 0),
  max_devices INTEGER NOT NULL DEFAULT 1 CHECK (max_devices BETWEEN 1 AND 20),
  authorization_days INTEGER NOT NULL DEFAULT 365 CHECK (authorization_days BETWEEN 0 AND 3650),
  user_id TEXT REFERENCES users(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  created_by TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS devices (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  public_key TEXT NOT NULL,
  name TEXT NOT NULL,
  platform TEXT NOT NULL,
  app_version TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
  activation_invite_id TEXT REFERENCES invites(id) ON DELETE SET NULL,
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  access_hash TEXT NOT NULL UNIQUE,
  access_expires_at INTEGER NOT NULL,
  refresh_hash TEXT NOT NULL UNIQUE,
  refresh_expires_at INTEGER NOT NULL,
  revoked_at INTEGER,
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS request_nonces (
  device_id TEXT NOT NULL,
  nonce TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  PRIMARY KEY (device_id, nonce)
);

CREATE TABLE IF NOT EXISTS cloud_settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  updated_by TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS audit_logs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  actor_type TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  action TEXT NOT NULL,
  target_type TEXT NOT NULL,
  target_id TEXT NOT NULL,
  details TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS admin_login_attempts (
  client_key TEXT PRIMARY KEY,
  failures INTEGER NOT NULL DEFAULT 0,
  blocked_until INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_users_status ON users(status);
CREATE INDEX IF NOT EXISTS idx_devices_user ON devices(user_id, status);
CREATE INDEX IF NOT EXISTS idx_devices_seen ON devices(last_seen_at DESC);
CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id, revoked_at);
CREATE INDEX IF NOT EXISTS idx_sessions_device ON sessions(device_id, revoked_at);
CREATE INDEX IF NOT EXISTS idx_sessions_access_expiry ON sessions(access_expires_at);
CREATE INDEX IF NOT EXISTS idx_sessions_refresh_expiry ON sessions(refresh_expires_at);
CREATE INDEX IF NOT EXISTS idx_invites_status ON invites(status, expires_at);
CREATE INDEX IF NOT EXISTS idx_nonces_expiry ON request_nonces(expires_at);
CREATE INDEX IF NOT EXISTS idx_audit_created ON audit_logs(created_at DESC);
