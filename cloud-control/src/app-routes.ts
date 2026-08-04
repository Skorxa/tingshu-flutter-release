import type { Env } from './types'
import {
  authenticateAccess,
  authenticateRefresh,
  issueSession,
  rotateSession,
} from './auth'
import {
  assertAppAvailable,
  assertSubscriptionAvailable,
  loadAppConfig,
} from './cloud-config'
import {
  HttpError,
  audit,
  envInt,
  json,
  normalizeInviteCode,
  nowSeconds,
  publicKeyDeviceId,
  randomId,
  readJson,
  sha256Hex,
  verifyDeviceRequest,
} from './utils'

interface InviteRow {
  id: string
  label: string
  status: string
  expires_at: number | null
  max_uses: number
  used_count: number
  max_devices: number
  authorization_days: number
  user_id: string | null
}

interface UserRow {
  id: string
  display_name: string
  status: string
  expires_at: number | null
  max_devices: number
}

function cleanText(value: unknown, maxLength: number): string {
  return String(value || '').trim().slice(0, maxLength)
}

function licensePayload(
  user: UserRow,
  deviceId: string,
  env: Env,
): Record<string, unknown> {
  return {
    user: {
      id: user.id,
      displayName: user.display_name,
      status: user.status,
      expiresAt: user.expires_at,
      maxDevices: user.max_devices,
    },
    deviceId,
    serverTime: nowSeconds(),
    offlineGraceSeconds: envInt(
      env.OFFLINE_GRACE_SECONDS,
      48 * 60 * 60,
      0,
      7 * 24 * 60 * 60,
    ),
  }
}

async function activate(request: Request, env: Env): Promise<Response> {
  await assertAppAvailable(env)
  const { value, text } = await readJson<Record<string, unknown>>(request)
  const code = normalizeInviteCode(value.inviteCode)
  const publicKey = cleanText(value.publicKey, 4096)
  const suppliedDeviceId = cleanText(value.deviceId, 128)
  if (code.length < 8) throw new HttpError(400, 'invalid_invite', '邀请码格式无效')
  if (!publicKey) throw new HttpError(400, 'public_key_required', '缺少设备公钥')
  const deviceId = await publicKeyDeviceId(publicKey)
  if (suppliedDeviceId && suppliedDeviceId !== deviceId) {
    throw new HttpError(400, 'device_id_mismatch', '设备标识与公钥不匹配')
  }
  await verifyDeviceRequest(request, env, publicKey, deviceId, text)

  const invite = await env.DB.prepare(
    `SELECT id, label, status, expires_at, max_uses, used_count,
            max_devices, authorization_days, user_id
     FROM invites WHERE code_hash = ?`,
  )
    .bind(await sha256Hex(code))
    .first<InviteRow>()
  if (!invite) throw new HttpError(403, 'invite_not_found', '邀请码无效')

  const now = nowSeconds()
  const existingDevice = await env.DB.prepare(
    'SELECT id, user_id, status, activation_invite_id FROM devices WHERE id = ?',
  )
    .bind(deviceId)
    .first<{
      id: string
      user_id: string
      status: string
      activation_invite_id: string | null
    }>()

  if (existingDevice?.activation_invite_id === invite.id) {
    if (existingDevice.status !== 'active') {
      throw new HttpError(403, 'device_disabled', '当前设备已被停用')
    }
    const user = await env.DB.prepare(
      'SELECT id, display_name, status, expires_at, max_devices FROM users WHERE id = ?',
    )
      .bind(existingDevice.user_id)
      .first<UserRow>()
    if (!user) throw new HttpError(403, 'user_not_found', '授权用户不存在')
    if (user.status !== 'active') {
      throw new HttpError(403, 'user_disabled', '当前授权已被停用')
    }
    if (user.expires_at != null && user.expires_at <= now) {
      throw new HttpError(403, 'license_expired', '当前授权已到期')
    }
    const tokens = await issueSession(env, user.id, deviceId)
    return json({ ok: true, data: { ...tokens, ...licensePayload(user, deviceId, env) } })
  }

  if (invite.status !== 'active') {
    throw new HttpError(403, 'invite_disabled', '邀请码已被停用')
  }
  if (invite.expires_at != null && invite.expires_at <= now) {
    throw new HttpError(403, 'invite_expired', '邀请码已过期')
  }
  if (invite.used_count >= invite.max_uses) {
    throw new HttpError(403, 'invite_exhausted', '邀请码已被使用')
  }
  if (existingDevice) {
    throw new HttpError(409, 'device_already_bound', '当前设备已绑定其他授权')
  }

  let user: UserRow | null = null
  const newUser = !invite.user_id
  if (invite.user_id) {
    user = await env.DB.prepare(
      'SELECT id, display_name, status, expires_at, max_devices FROM users WHERE id = ?',
    )
      .bind(invite.user_id)
      .first<UserRow>()
    if (!user) throw new HttpError(404, 'invite_user_missing', '邀请码绑定用户不存在')
    if (user.status !== 'active') {
      throw new HttpError(403, 'user_disabled', '目标用户已被停用')
    }
  } else {
    const displayName =
      cleanText(value.displayName, 50) || cleanText(invite.label, 50) || '授权用户'
    user = {
      id: randomId('usr'),
      display_name: displayName,
      status: 'active',
      expires_at:
        invite.authorization_days > 0
          ? now + invite.authorization_days * 24 * 60 * 60
          : null,
      max_devices: Math.max(1, invite.max_devices),
    }
  }

  const deviceCount = await env.DB.prepare(
    "SELECT COUNT(*) AS count FROM devices WHERE user_id = ? AND status = 'active'",
  )
    .bind(user.id)
    .first<{ count: number }>()
  if ((deviceCount?.count || 0) >= user.max_devices) {
    throw new HttpError(409, 'device_limit_reached', '该用户已达到设备数量上限')
  }

  const consumed = await env.DB.prepare(
    `UPDATE invites
     SET used_count = used_count + 1, updated_at = ?
     WHERE id = ? AND status = 'active' AND used_count < max_uses
       AND (expires_at IS NULL OR expires_at > ?)
     RETURNING id`,
  )
    .bind(now, invite.id, now)
    .first<{ id: string }>()
  if (!consumed) throw new HttpError(409, 'invite_race', '邀请码刚刚已被使用')

  if (newUser) {
    await env.DB.prepare(
      `INSERT INTO users(
        id, display_name, status, expires_at, max_devices, created_at, updated_at
      ) VALUES (?, ?, 'active', ?, ?, ?, ?)`,
    )
      .bind(
        user.id,
        user.display_name,
        user.expires_at,
        user.max_devices,
        now,
        now,
      )
      .run()
  }

  await env.DB.prepare(
    `INSERT INTO devices(
      id, user_id, public_key, name, platform, app_version, status,
      activation_invite_id, created_at, last_seen_at
    ) VALUES (?, ?, ?, ?, ?, ?, 'active', ?, ?, ?)`,
  )
    .bind(
      deviceId,
      user.id,
      publicKey,
      cleanText(value.deviceName, 80) || 'Android 设备',
      cleanText(value.platform, 30) || 'android',
      cleanText(value.appVersion, 40),
      invite.id,
      now,
      now,
    )
    .run()

  const tokens = await issueSession(env, user.id, deviceId)
  await audit(env, 'device', deviceId, 'license.activate', 'user', user.id, {
    inviteId: invite.id,
    appVersion: cleanText(value.appVersion, 40),
  })
  return json(
    { ok: true, data: { ...tokens, ...licensePayload(user, deviceId, env) } },
    201,
  )
}

async function refresh(request: Request, env: Env): Promise<Response> {
  const { value, text } = await readJson<Record<string, unknown>>(request)
  const refreshToken = cleanText(value.refreshToken, 512)
  const identity = await authenticateRefresh(request, env, refreshToken, text)
  await assertAppAvailable(env)
  const tokens = await rotateSession(env, identity)
  const user: UserRow = {
    id: identity.userId,
    display_name: identity.displayName,
    status: identity.userStatus,
    expires_at: identity.expiresAt,
    max_devices: identity.maxDevices,
  }
  return json({ ok: true, data: { ...tokens, ...licensePayload(user, identity.deviceId, env) } })
}

async function status(request: Request, env: Env): Promise<Response> {
  const identity = await authenticateAccess(request, env)
  await assertAppAvailable(env)
  const user: UserRow = {
    id: identity.userId,
    display_name: identity.displayName,
    status: identity.userStatus,
    expires_at: identity.expiresAt,
    max_devices: identity.maxDevices,
  }
  return json({ ok: true, data: licensePayload(user, identity.deviceId, env) })
}

async function logout(request: Request, env: Env): Promise<Response> {
  const { text } = await readJson<Record<string, unknown>>(request)
  const identity = await authenticateAccess(request, env, text)
  await env.DB.prepare('UPDATE sessions SET revoked_at = ? WHERE id = ?')
    .bind(nowSeconds(), identity.sessionId)
    .run()
  await audit(env, 'device', identity.deviceId, 'session.logout', 'user', identity.userId)
  return json({ ok: true })
}

async function cloudConfig(request: Request, env: Env): Promise<Response> {
  await authenticateAccess(request, env)
  return json({ ok: true, data: await loadAppConfig(env) })
}

async function privateObject(
  request: Request,
  env: Env,
  objectKey: string,
  fallbackType: string,
): Promise<Response> {
  await authenticateAccess(request, env)
  await assertSubscriptionAvailable(env)
  const object = await env.PRIVATE_BUCKET.get(objectKey)
  if (!object) throw new HttpError(404, 'private_object_not_found', '私有资源不存在')
  const headers = new Headers({
    'Content-Type': object.httpMetadata?.contentType || fallbackType,
    'Cache-Control': 'private, no-store',
    ETag: object.httpEtag,
  })
  return new Response(object.body, { headers })
}

export async function handleAppRequest(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url)
  const path = url.pathname
  if (request.method === 'POST' && path === '/api/auth/activate') {
    return activate(request, env)
  }
  if (request.method === 'POST' && path === '/api/auth/refresh') {
    return refresh(request, env)
  }
  if (request.method === 'GET' && path === '/api/auth/status') {
    return status(request, env)
  }
  if (request.method === 'POST' && path === '/api/auth/logout') {
    return logout(request, env)
  }
  if (request.method === 'GET' && path === '/api/config') {
    return cloudConfig(request, env)
  }
  if (request.method === 'GET' && path === '/api/subscription') {
    return privateObject(
      request,
      env,
      env.SUBSCRIPTION_OBJECT_KEY || 'sources/subscription.json',
      'application/json; charset=utf-8',
    )
  }
  if (request.method === 'GET' && path.startsWith('/api/sources/')) {
    let relative: string
    try {
      relative = decodeURIComponent(path.slice('/api/sources/'.length))
    } catch {
      throw new HttpError(400, 'invalid_source_path', '音源文件路径编码无效')
    }
    if (!relative || relative.includes('..') || relative.includes('\\')) {
      throw new HttpError(400, 'invalid_source_path', '音源文件路径无效')
    }
    const prefix = (env.SOURCE_PREFIX || 'sources/files/').replace(/^\/+/, '')
    return privateObject(request, env, `${prefix}${relative}`, 'text/javascript; charset=utf-8')
  }
  throw new HttpError(404, 'route_not_found', '接口不存在')
}
