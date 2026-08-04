import { authenticateAdmin, loginAdmin, requireAdminMutation } from './auth'
import { loadAppConfig, validateAppConfig } from './cloud-config'
import { deleteSource, sourceSnapshot, uploadSources } from './source-storage'
import type { AdminIdentity, Env } from './types'
import {
  HttpError,
  audit,
  clearAdminCookieHeader,
  json,
  normalizeInviteCode,
  nowSeconds,
  randomId,
  readJson,
  requireSameOrigin,
  sha256Hex,
} from './utils'

function cleanText(value: unknown, maxLength: number): string {
  return String(value || '').trim().slice(0, maxLength)
}

function boundedInt(value: unknown, fallback: number, min: number, max: number): number {
  const parsed = Number(value)
  return Number.isFinite(parsed)
    ? Math.max(min, Math.min(max, Math.floor(parsed)))
    : fallback
}

function inviteCode(): string {
  const alphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ'
  const bytes = new Uint8Array(12)
  crypto.getRandomValues(bytes)
  const text = [...bytes].map((byte) => alphabet[byte % alphabet.length]).join('')
  return `JT-${text.slice(0, 4)}-${text.slice(4, 8)}-${text.slice(8, 12)}`
}

async function summary(env: Env): Promise<Response> {
  const [users, activeUsers, devices, activeInvites] = await env.DB.batch([
    env.DB.prepare('SELECT COUNT(*) AS count FROM users'),
    env.DB.prepare("SELECT COUNT(*) AS count FROM users WHERE status = 'active'"),
    env.DB.prepare("SELECT COUNT(*) AS count FROM devices WHERE status = 'active'"),
    env.DB.prepare(
      "SELECT COUNT(*) AS count FROM invites WHERE status = 'active' AND used_count < max_uses AND (expires_at IS NULL OR expires_at > ?)",
    ).bind(nowSeconds()),
  ])
  const count = (result: D1Result<unknown>): number => {
    const row = result.results?.[0] as { count?: number } | undefined
    return Number(row?.count || 0)
  }
  return json({
    ok: true,
    data: {
      users: count(users),
      activeUsers: count(activeUsers),
      activeDevices: count(devices),
      activeInvites: count(activeInvites),
    },
  })
}

async function listUsers(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url)
  const search = cleanText(url.searchParams.get('q'), 80)
  const status = cleanText(url.searchParams.get('status'), 20)
  const offset = boundedInt(url.searchParams.get('offset'), 0, 0, 100000)
  const like = `%${search}%`
  const result = await env.DB.prepare(
    `SELECT
       u.id, u.display_name, u.status, u.expires_at, u.max_devices,
       u.created_at, u.updated_at,
       COUNT(DISTINCT d.id) AS device_count,
       MAX(d.last_seen_at) AS last_seen_at
     FROM users u
     LEFT JOIN devices d ON d.user_id = u.id
     WHERE (? = '' OR u.display_name LIKE ? OR u.id LIKE ?)
       AND (? = '' OR u.status = ?)
     GROUP BY u.id
     ORDER BY u.created_at DESC
     LIMIT 100 OFFSET ?`,
  )
    .bind(search, like, like, status, status, offset)
    .all()
  return json({ ok: true, data: result.results || [] })
}

async function userDevices(userId: string, env: Env): Promise<Response> {
  const result = await env.DB.prepare(
    `SELECT id, name, platform, app_version, status, created_at, last_seen_at
     FROM devices WHERE user_id = ? ORDER BY created_at DESC`,
  )
    .bind(userId)
    .all()
  return json({ ok: true, data: result.results || [] })
}

async function setUserStatus(
  request: Request,
  env: Env,
  admin: AdminIdentity,
  userId: string,
): Promise<Response> {
  const { value } = await readJson<Record<string, unknown>>(request)
  const status = cleanText(value.status, 20)
  if (!['active', 'disabled'].includes(status)) {
    throw new HttpError(400, 'invalid_user_status', '用户状态无效')
  }
  const result = await env.DB.prepare(
    'UPDATE users SET status = ?, updated_at = ? WHERE id = ?',
  )
    .bind(status, nowSeconds(), userId)
    .run()
  if ((result.meta.changes || 0) !== 1) {
    throw new HttpError(404, 'user_not_found', '用户不存在')
  }
  await audit(env, 'admin', admin.id, `user.${status}`, 'user', userId)
  return json({ ok: true })
}

async function updateUser(
  request: Request,
  env: Env,
  admin: AdminIdentity,
  userId: string,
): Promise<Response> {
  const { value } = await readJson<Record<string, unknown>>(request)
  const current = await env.DB.prepare(
    'SELECT display_name, expires_at, max_devices FROM users WHERE id = ?',
  )
    .bind(userId)
    .first<{ display_name: string; expires_at: number | null; max_devices: number }>()
  if (!current) throw new HttpError(404, 'user_not_found', '用户不存在')
  const displayName = cleanText(value.displayName, 50) || current.display_name
  const maxDevices = boundedInt(value.maxDevices, current.max_devices, 1, 20)
  let expiresAt = current.expires_at
  if (Object.prototype.hasOwnProperty.call(value, 'expiresAt')) {
    const parsed = Number(value.expiresAt)
    expiresAt = Number.isFinite(parsed) && parsed > 0 ? Math.floor(parsed) : null
  }
  await env.DB.prepare(
    `UPDATE users SET display_name = ?, expires_at = ?, max_devices = ?, updated_at = ?
     WHERE id = ?`,
  )
    .bind(displayName, expiresAt, maxDevices, nowSeconds(), userId)
    .run()
  await audit(env, 'admin', admin.id, 'user.update', 'user', userId, {
    displayName,
    expiresAt,
    maxDevices,
  })
  return json({ ok: true })
}

async function revokeUserSessions(
  env: Env,
  admin: AdminIdentity,
  userId: string,
): Promise<Response> {
  const result = await env.DB.prepare(
    'UPDATE sessions SET revoked_at = ? WHERE user_id = ? AND revoked_at IS NULL',
  )
    .bind(nowSeconds(), userId)
    .run()
  await audit(env, 'admin', admin.id, 'session.revoke_all', 'user', userId, {
    count: result.meta.changes || 0,
  })
  return json({ ok: true, data: { revoked: result.meta.changes || 0 } })
}

async function setDeviceStatus(
  request: Request,
  env: Env,
  admin: AdminIdentity,
  deviceId: string,
): Promise<Response> {
  const { value } = await readJson<Record<string, unknown>>(request)
  const status = cleanText(value.status, 20)
  if (!['active', 'disabled'].includes(status)) {
    throw new HttpError(400, 'invalid_device_status', '设备状态无效')
  }
  const result = await env.DB.prepare(
    'UPDATE devices SET status = ? WHERE id = ?',
  )
    .bind(status, deviceId)
    .run()
  if ((result.meta.changes || 0) !== 1) {
    throw new HttpError(404, 'device_not_found', '设备不存在')
  }
  if (status === 'disabled') {
    await env.DB.prepare(
      'UPDATE sessions SET revoked_at = ? WHERE device_id = ? AND revoked_at IS NULL',
    )
      .bind(nowSeconds(), deviceId)
      .run()
  }
  await audit(env, 'admin', admin.id, `device.${status}`, 'device', deviceId)
  return json({ ok: true })
}

async function listInvites(env: Env): Promise<Response> {
  const result = await env.DB.prepare(
    `SELECT
       i.id, i.label, i.status, i.expires_at, i.max_uses, i.used_count,
       i.max_devices, i.authorization_days, i.user_id, i.created_at,
       u.display_name AS user_name
     FROM invites i
     LEFT JOIN users u ON u.id = i.user_id
     ORDER BY i.created_at DESC LIMIT 200`,
  ).all()
  return json({ ok: true, data: result.results || [] })
}

async function createInvite(
  request: Request,
  env: Env,
  admin: AdminIdentity,
): Promise<Response> {
  const { value } = await readJson<Record<string, unknown>>(request)
  const code = inviteCode()
  const id = randomId('inv')
  const now = nowSeconds()
  const expiresDays = boundedInt(value.expiresDays, 7, 0, 365)
  const authorizationDays = boundedInt(value.authorizationDays, 365, 0, 3650)
  const maxUses = boundedInt(value.maxUses, 1, 1, 100)
  const maxDevices = boundedInt(value.maxDevices, 1, 1, 20)
  const userId = cleanText(value.userId, 100) || null
  if (userId) {
    const exists = await env.DB.prepare('SELECT id FROM users WHERE id = ?')
      .bind(userId)
      .first()
    if (!exists) throw new HttpError(404, 'user_not_found', '绑定用户不存在')
  }
  await env.DB.prepare(
    `INSERT INTO invites(
      id, code_hash, label, status, expires_at, max_uses, used_count,
      max_devices, authorization_days, user_id, created_at, updated_at, created_by
    ) VALUES (?, ?, ?, 'active', ?, ?, 0, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      id,
      await sha256Hex(normalizeInviteCode(code)),
      cleanText(value.label, 80) || '新用户',
      expiresDays > 0 ? now + expiresDays * 24 * 60 * 60 : null,
      maxUses,
      maxDevices,
      authorizationDays,
      userId,
      now,
      now,
      admin.id,
    )
    .run()
  await audit(env, 'admin', admin.id, 'invite.create', 'invite', id, {
    maxUses,
    maxDevices,
    authorizationDays,
    userId,
  })
  return json({ ok: true, data: { id, code } }, 201)
}

async function revokeInvite(
  env: Env,
  admin: AdminIdentity,
  inviteId: string,
): Promise<Response> {
  const result = await env.DB.prepare(
    "UPDATE invites SET status = 'revoked', updated_at = ? WHERE id = ?",
  )
    .bind(nowSeconds(), inviteId)
    .run()
  if ((result.meta.changes || 0) !== 1) {
    throw new HttpError(404, 'invite_not_found', '邀请码不存在')
  }
  await audit(env, 'admin', admin.id, 'invite.revoke', 'invite', inviteId)
  return json({ ok: true })
}

async function getConfig(env: Env): Promise<Response> {
  const row = await env.DB.prepare('SELECT value, updated_at FROM cloud_settings WHERE key = ?')
    .bind('app_config')
    .first<{ value: string; updated_at: number }>()
  const value = await loadAppConfig(env)
  return json({ ok: true, data: { value, updatedAt: row?.updated_at || null } })
}

async function saveConfig(
  request: Request,
  env: Env,
  admin: AdminIdentity,
): Promise<Response> {
  const { value } = await readJson<Record<string, unknown>>(request)
  const config = validateAppConfig(value.value ?? value)
  const encoded = JSON.stringify(config)
  if (encoded.length > 64 * 1024) {
    throw new HttpError(413, 'cloud_config_too_large', '云控配置过大')
  }
  const now = nowSeconds()
  await env.DB.prepare(
    `INSERT INTO cloud_settings(key, value, updated_at, updated_by)
     VALUES ('app_config', ?, ?, ?)
     ON CONFLICT(key) DO UPDATE SET
       value = excluded.value,
       updated_at = excluded.updated_at,
       updated_by = excluded.updated_by`,
  )
    .bind(encoded, now, admin.id)
    .run()
  await audit(env, 'admin', admin.id, 'config.update', 'config', 'app_config')
  return json({ ok: true, data: { value: config, updatedAt: now } })
}

async function listAudit(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url)
  const offset = boundedInt(url.searchParams.get('offset'), 0, 0, 100000)
  const result = await env.DB.prepare(
    `SELECT id, actor_type, actor_id, action, target_type, target_id, details, created_at
     FROM audit_logs ORDER BY id DESC LIMIT 200 OFFSET ?`,
  )
    .bind(offset)
    .all()
  return json({ ok: true, data: result.results || [] })
}

export async function handleAdminRequest(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url)
  const path = url.pathname

  if (request.method === 'POST' && path === '/admin/api/login') {
    const { value } = await readJson<Record<string, unknown>>(request, 4096)
    return loginAdmin(request, env, cleanText(value.password, 512))
  }
  if (request.method === 'POST' && path === '/admin/api/logout') {
    requireSameOrigin(request)
    return json({ ok: true }, 200, { 'Set-Cookie': clearAdminCookieHeader() })
  }

  const admin = await authenticateAdmin(request, env)
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    requireAdminMutation(request, admin)
  }

  if (request.method === 'GET' && path === '/admin/api/me') {
    return json({
      ok: true,
      data: { id: admin.id, mode: admin.mode, csrfToken: admin.csrfToken },
    })
  }
  if (request.method === 'GET' && path === '/admin/api/summary') return summary(env)
  if (request.method === 'GET' && path === '/admin/api/users') {
    return listUsers(request, env)
  }
  if (request.method === 'GET' && path === '/admin/api/invites') {
    return listInvites(env)
  }
  if (request.method === 'POST' && path === '/admin/api/invites') {
    return createInvite(request, env, admin)
  }
  if (request.method === 'GET' && path === '/admin/api/config') return getConfig(env)
  if (request.method === 'PUT' && path === '/admin/api/config') {
    return saveConfig(request, env, admin)
  }
  if (request.method === 'GET' && path === '/admin/api/sources') {
    return sourceSnapshot(request, env)
  }
  if (request.method === 'POST' && path === '/admin/api/sources/upload') {
    return uploadSources(request, env, admin)
  }
  if (request.method === 'GET' && path === '/admin/api/audit') {
    return listAudit(request, env)
  }

  let match = /^\/admin\/api\/users\/([^/]+)\/devices$/.exec(path)
  if (request.method === 'GET' && match) return userDevices(match[1], env)
  match = /^\/admin\/api\/users\/([^/]+)\/status$/.exec(path)
  if (request.method === 'POST' && match) {
    return setUserStatus(request, env, admin, match[1])
  }
  match = /^\/admin\/api\/users\/([^/]+)\/revoke-sessions$/.exec(path)
  if (request.method === 'POST' && match) {
    return revokeUserSessions(env, admin, match[1])
  }
  match = /^\/admin\/api\/users\/([^/]+)$/.exec(path)
  if (request.method === 'PUT' && match) {
    return updateUser(request, env, admin, match[1])
  }
  match = /^\/admin\/api\/devices\/([^/]+)\/status$/.exec(path)
  if (request.method === 'POST' && match) {
    return setDeviceStatus(request, env, admin, match[1])
  }
  match = /^\/admin\/api\/invites\/([^/]+)\/revoke$/.exec(path)
  if (request.method === 'POST' && match) {
    return revokeInvite(env, admin, match[1])
  }
  match = /^\/admin\/api\/sources\/([^/]+)$/.exec(path)
  if (request.method === 'DELETE' && match) {
    return deleteSource(request, env, admin, match[1])
  }
  throw new HttpError(404, 'admin_route_not_found', '管理接口不存在')
}
