import type { AdminIdentity, AppIdentity, Env, SessionTokens } from './types'
import {
  HttpError,
  adminCookieHeader,
  bearerToken,
  clientKey,
  cookieValue,
  createAdminCookie,
  envInt,
  hmacBase64Url,
  nowSeconds,
  randomId,
  randomToken,
  requireSameOrigin,
  secureStringEquals,
  sha256Hex,
  verifyAdminCookie,
  verifyDeviceRequest,
} from './utils'

interface SessionRow {
  session_id: string
  user_id: string
  device_id: string
  display_name: string
  user_status: string
  user_expires_at: number | null
  max_devices: number
  device_status: string
  public_key: string
}

function assertEntitlement(row: SessionRow): void {
  if (row.user_status !== 'active') {
    throw new HttpError(403, 'user_disabled', '当前授权已被停用')
  }
  if (row.user_expires_at != null && row.user_expires_at <= nowSeconds()) {
    throw new HttpError(403, 'license_expired', '当前授权已到期')
  }
  if (row.device_status !== 'active') {
    throw new HttpError(403, 'device_disabled', '当前设备已被停用')
  }
}

function toIdentity(row: SessionRow): AppIdentity {
  return {
    sessionId: row.session_id,
    userId: row.user_id,
    deviceId: row.device_id,
    displayName: row.display_name,
    userStatus: row.user_status,
    expiresAt: row.user_expires_at,
    maxDevices: row.max_devices,
    publicKey: row.public_key,
  }
}

const sessionSelect = `
  SELECT
    s.id AS session_id,
    u.id AS user_id,
    d.id AS device_id,
    u.display_name AS display_name,
    u.status AS user_status,
    u.expires_at AS user_expires_at,
    u.max_devices AS max_devices,
    d.status AS device_status,
    d.public_key AS public_key
  FROM sessions s
  JOIN users u ON u.id = s.user_id
  JOIN devices d ON d.id = s.device_id
`

export async function authenticateAccess(
  request: Request,
  env: Env,
  bodyText = '',
): Promise<AppIdentity> {
  const token = bearerToken(request)
  if (!token) throw new HttpError(401, 'access_token_required', '请先激活设备')
  const hash = await sha256Hex(token)
  const row = await env.DB.prepare(
    `${sessionSelect}
     WHERE s.access_hash = ?
       AND s.revoked_at IS NULL
       AND s.access_expires_at > ?`,
  )
    .bind(hash, nowSeconds())
    .first<SessionRow>()
  if (!row) throw new HttpError(401, 'access_token_expired', '访问凭据已过期')
  assertEntitlement(row)
  await verifyDeviceRequest(request, env, row.public_key, row.device_id, bodyText)
  const now = nowSeconds()
  await env.DB.batch([
    env.DB.prepare('UPDATE sessions SET last_seen_at = ? WHERE id = ?').bind(
      now,
      row.session_id,
    ),
    env.DB.prepare(
      'UPDATE devices SET last_seen_at = ?, app_version = COALESCE(NULLIF(?, ""), app_version) WHERE id = ?',
    ).bind(now, request.headers.get('x-app-version') || '', row.device_id),
  ])
  return toIdentity(row)
}

export async function authenticateRefresh(
  request: Request,
  env: Env,
  refreshToken: string,
  bodyText: string,
): Promise<AppIdentity> {
  if (!refreshToken) {
    throw new HttpError(401, 'refresh_token_required', '刷新凭据为空')
  }
  const hash = await sha256Hex(refreshToken)
  const row = await env.DB.prepare(
    `${sessionSelect}
     WHERE s.refresh_hash = ?
       AND s.revoked_at IS NULL
       AND s.refresh_expires_at > ?`,
  )
    .bind(hash, nowSeconds())
    .first<SessionRow>()
  if (!row) throw new HttpError(401, 'refresh_token_expired', '设备授权已失效')
  assertEntitlement(row)
  await verifyDeviceRequest(request, env, row.public_key, row.device_id, bodyText)
  return toIdentity(row)
}

export async function issueSession(
  env: Env,
  userId: string,
  deviceId: string,
  existingSessionId = '',
): Promise<SessionTokens> {
  const now = nowSeconds()
  const accessTtl = envInt(env.ACCESS_TOKEN_TTL_SECONDS, 1800, 300, 86400)
  const refreshTtl = envInt(
    env.REFRESH_TOKEN_TTL_SECONDS,
    30 * 24 * 60 * 60,
    86400,
    180 * 24 * 60 * 60,
  )
  const accessToken = randomToken(32)
  const refreshToken = randomToken(48)
  const accessExpiresAt = now + accessTtl
  const refreshExpiresAt = now + refreshTtl
  const values = [
    await sha256Hex(accessToken),
    accessExpiresAt,
    await sha256Hex(refreshToken),
    refreshExpiresAt,
    now,
  ] as const

  if (existingSessionId) {
    await env.DB.prepare(
      `UPDATE sessions
       SET access_hash = ?, access_expires_at = ?, refresh_hash = ?,
           refresh_expires_at = ?, revoked_at = NULL, last_seen_at = ?
       WHERE id = ?`,
    )
      .bind(...values, existingSessionId)
      .run()
  } else {
    await env.DB.prepare(
      `INSERT INTO sessions(
        id, user_id, device_id, access_hash, access_expires_at,
        refresh_hash, refresh_expires_at, created_at, last_seen_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
      .bind(
        randomId('ses'),
        userId,
        deviceId,
        values[0],
        values[1],
        values[2],
        values[3],
        now,
        now,
      )
      .run()
  }
  return { accessToken, accessExpiresAt, refreshToken, refreshExpiresAt }
}

export async function rotateSession(
  env: Env,
  identity: AppIdentity,
): Promise<SessionTokens> {
  return issueSession(env, identity.userId, identity.deviceId, identity.sessionId)
}

function allowedAdminEmail(email: string, configured: string | undefined): boolean {
  const allowed = String(configured || '')
    .split(',')
    .map((item) => item.trim().toLowerCase())
    .filter(Boolean)
  return allowed.length > 0 && allowed.includes(email.trim().toLowerCase())
}

export async function authenticateAdmin(
  request: Request,
  env: Env,
): Promise<AdminIdentity> {
  const secret = env.ADMIN_SESSION_SECRET || ''
  const accessEmail = request.headers.get('cf-access-authenticated-user-email') || ''
  if (accessEmail && allowedAdminEmail(accessEmail, env.ADMIN_EMAILS)) {
    return {
      id: accessEmail.toLowerCase(),
      mode: 'access',
      csrfToken: await hmacBase64Url(secret, `access:${accessEmail.toLowerCase()}`),
    }
  }
  const token = cookieValue(request, 'juting_admin')
  if (token) {
    const payload = await verifyAdminCookie(secret, token)
    if (payload) {
      return { id: payload.sub, mode: 'password', csrfToken: payload.csrf }
    }
  }
  throw new HttpError(401, 'admin_login_required', '管理员尚未登录')
}

export function requireAdminMutation(
  request: Request,
  admin: AdminIdentity,
): void {
  requireSameOrigin(request)
  const csrf = request.headers.get('x-csrf-token') || ''
  if (!csrf || csrf !== admin.csrfToken) {
    throw new HttpError(403, 'invalid_csrf', '管理请求校验失败')
  }
}

export async function loginAdmin(
  request: Request,
  env: Env,
  password: string,
): Promise<Response> {
  requireSameOrigin(request)
  const configured = env.ADMIN_PASSWORD || ''
  const secret = env.ADMIN_SESSION_SECRET || ''
  if (!configured || secret.length < 24) {
    throw new HttpError(503, 'admin_login_not_configured', '管理员密码登录尚未配置')
  }
  const key = await clientKey(request, secret)
  const attempt = await env.DB.prepare(
    'SELECT failures, blocked_until FROM admin_login_attempts WHERE client_key = ?',
  )
    .bind(key)
    .first<{ failures: number; blocked_until: number }>()
  const now = nowSeconds()
  if (attempt && attempt.blocked_until > now) {
    throw new HttpError(429, 'admin_login_limited', '登录尝试过多，请稍后再试')
  }

  if (!(await secureStringEquals(password, configured))) {
    const failures = (attempt?.failures || 0) + 1
    const blockedUntil = failures >= 5 ? now + 15 * 60 : 0
    await env.DB.prepare(
      `INSERT INTO admin_login_attempts(client_key, failures, blocked_until, updated_at)
       VALUES (?, ?, ?, ?)
       ON CONFLICT(client_key) DO UPDATE SET
         failures = excluded.failures,
         blocked_until = excluded.blocked_until,
         updated_at = excluded.updated_at`,
    )
      .bind(key, failures, blockedUntil, now)
      .run()
    throw new HttpError(401, 'invalid_admin_password', '管理员密码错误')
  }

  await env.DB.prepare('DELETE FROM admin_login_attempts WHERE client_key = ?')
    .bind(key)
    .run()
  const ttl = envInt(env.ADMIN_SESSION_TTL_SECONDS, 8 * 60 * 60, 900, 86400)
  const session = await createAdminCookie(secret, 'password-admin', now + ttl)
  return new Response(
    JSON.stringify({ ok: true, data: { csrfToken: session.csrf } }),
    {
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'Cache-Control': 'no-store',
        'Set-Cookie': adminCookieHeader(session.token, ttl),
      },
    },
  )
}
