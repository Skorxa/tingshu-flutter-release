import type { Env } from './types'

const encoder = new TextEncoder()
const decoder = new TextDecoder()

function ownedBuffer(value: Uint8Array): ArrayBuffer {
  const copy = new Uint8Array(value.byteLength)
  copy.set(value)
  return copy.buffer
}

export class HttpError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string,
  ) {
    super(message)
  }
}

export function json(
  data: unknown,
  status = 200,
  headers: HeadersInit = {},
): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
      ...headers,
    },
  })
}

export function errorResponse(error: unknown): Response {
  if (error instanceof HttpError) {
    return json(
      { ok: false, error: { code: error.code, message: error.message } },
      error.status,
    )
  }
  console.error(error)
  return json(
    { ok: false, error: { code: 'internal_error', message: '服务器内部错误' } },
    500,
  )
}

export async function readJson<T = Record<string, unknown>>(
  request: Request,
  maxBytes = 64 * 1024,
): Promise<{ value: T; text: string }> {
  const declared = Number(request.headers.get('content-length') || 0)
  if (declared > maxBytes) {
    throw new HttpError(413, 'body_too_large', '请求内容过大')
  }
  const text = await request.text()
  if (encoder.encode(text).byteLength > maxBytes) {
    throw new HttpError(413, 'body_too_large', '请求内容过大')
  }
  try {
    const value = text.trim() ? JSON.parse(text) : {}
    if (!value || typeof value !== 'object' || Array.isArray(value)) {
      throw new Error('not an object')
    }
    return { value: value as T, text }
  } catch {
    throw new HttpError(400, 'invalid_json', '请求 JSON 格式无效')
  }
}

export function envInt(
  value: string | undefined,
  fallback: number,
  min: number,
  max: number,
): number {
  const parsed = Number(value)
  if (!Number.isFinite(parsed)) return fallback
  return Math.max(min, Math.min(max, Math.floor(parsed)))
}

export function nowSeconds(): number {
  return Math.floor(Date.now() / 1000)
}

export function randomToken(bytes = 32): string {
  const value = new Uint8Array(bytes)
  crypto.getRandomValues(value)
  return base64UrlEncode(value)
}

export function randomId(prefix: string): string {
  return `${prefix}_${randomToken(18)}`
}

export function base64UrlEncode(value: Uint8Array): string {
  let binary = ''
  for (let offset = 0; offset < value.length; offset += 0x8000) {
    binary += String.fromCharCode(...value.subarray(offset, offset + 0x8000))
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '')
}

export function base64Decode(value: string): Uint8Array {
  const normalized = value.replace(/-/g, '+').replace(/_/g, '/')
  const padded = normalized + '='.repeat((4 - (normalized.length % 4)) % 4)
  try {
    const binary = atob(padded)
    return Uint8Array.from(binary, (char) => char.charCodeAt(0))
  } catch {
    throw new HttpError(400, 'invalid_base64', '设备密钥或签名格式无效')
  }
}

export async function sha256Bytes(value: string | Uint8Array): Promise<Uint8Array> {
  const bytes = typeof value === 'string' ? encoder.encode(value) : value
  return new Uint8Array(await crypto.subtle.digest('SHA-256', ownedBuffer(bytes)))
}

export async function sha256Hex(value: string | Uint8Array): Promise<string> {
  const digest = await sha256Bytes(value)
  return [...digest].map((byte) => byte.toString(16).padStart(2, '0')).join('')
}

export async function hmacBase64Url(secret: string, value: string): Promise<string> {
  if (secret.length < 24) {
    throw new HttpError(503, 'server_not_configured', '管理员会话密钥尚未配置')
  }
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  )
  const signature = await crypto.subtle.sign('HMAC', key, encoder.encode(value))
  return base64UrlEncode(new Uint8Array(signature))
}

export async function secureStringEquals(a: string, b: string): Promise<boolean> {
  const [left, right] = await Promise.all([sha256Bytes(a), sha256Bytes(b)])
  let mismatch = left.length ^ right.length
  const length = Math.max(left.length, right.length)
  for (let i = 0; i < length; i++) {
    mismatch |= (left[i] || 0) ^ (right[i] || 0)
  }
  return mismatch === 0
}

export function normalizeInviteCode(value: unknown): string {
  return String(value || '').toUpperCase().replace(/[^A-Z0-9]/g, '')
}

export function bearerToken(request: Request): string {
  const value = request.headers.get('authorization') || ''
  const match = /^Bearer\s+(.+)$/i.exec(value.trim())
  return match?.[1]?.trim() || ''
}

export function cookieValue(request: Request, name: string): string {
  const cookie = request.headers.get('cookie') || ''
  for (const item of cookie.split(';')) {
    const index = item.indexOf('=')
    if (index < 0) continue
    if (item.slice(0, index).trim() === name) {
      return decodeURIComponent(item.slice(index + 1).trim())
    }
  }
  return ''
}

interface AdminCookiePayload {
  sub: string
  exp: number
  csrf: string
  jti: string
}

export async function createAdminCookie(
  secret: string,
  subject: string,
  expiresAt: number,
): Promise<{ token: string; csrf: string }> {
  const payload: AdminCookiePayload = {
    sub: subject,
    exp: expiresAt,
    csrf: randomToken(18),
    jti: randomToken(12),
  }
  const encoded = base64UrlEncode(encoder.encode(JSON.stringify(payload)))
  const signature = await hmacBase64Url(secret, encoded)
  return { token: `${encoded}.${signature}`, csrf: payload.csrf }
}

export async function verifyAdminCookie(
  secret: string,
  token: string,
): Promise<AdminCookiePayload | null> {
  const [encoded, signature, extra] = token.split('.')
  if (!encoded || !signature || extra) return null
  const expected = await hmacBase64Url(secret, encoded)
  if (!(await secureStringEquals(signature, expected))) return null
  try {
    const payload = JSON.parse(decoder.decode(base64Decode(encoded))) as AdminCookiePayload
    if (!payload.sub || !payload.csrf || payload.exp <= nowSeconds()) return null
    return payload
  } catch {
    return null
  }
}

export function adminCookieHeader(token: string, maxAge: number): string {
  return `juting_admin=${encodeURIComponent(token)}; Path=/admin; Max-Age=${maxAge}; HttpOnly; Secure; SameSite=Strict`
}

export function clearAdminCookieHeader(): string {
  return 'juting_admin=; Path=/admin; Max-Age=0; HttpOnly; Secure; SameSite=Strict'
}

export function requireSameOrigin(request: Request): void {
  const origin = request.headers.get('origin')
  if (origin && origin !== new URL(request.url).origin) {
    throw new HttpError(403, 'invalid_origin', '请求来源不受信任')
  }
}

export async function publicKeyDeviceId(publicKey: string): Promise<string> {
  return sha256Hex(base64Decode(publicKey.trim()))
}

function derToP1363(signature: Uint8Array, componentSize = 32): Uint8Array {
  if (signature.length === componentSize * 2) return signature
  let offset = 0
  const readLength = (): number => {
    const first = signature[offset++]
    if (first === undefined) throw new Error('invalid der')
    if ((first & 0x80) === 0) return first
    const count = first & 0x7f
    if (count < 1 || count > 2) throw new Error('invalid der')
    let length = 0
    for (let i = 0; i < count; i++) {
      const next = signature[offset++]
      if (next === undefined) throw new Error('invalid der')
      length = (length << 8) | next
    }
    return length
  }
  const readInteger = (): Uint8Array => {
    if (signature[offset++] !== 0x02) throw new Error('invalid der')
    const length = readLength()
    let value = signature.slice(offset, offset + length)
    offset += length
    while (value.length > 1 && value[0] === 0) value = value.slice(1)
    if (value.length > componentSize) throw new Error('invalid der')
    const result = new Uint8Array(componentSize)
    result.set(value, componentSize - value.length)
    return result
  }
  if (signature[offset++] !== 0x30) throw new Error('invalid der')
  const sequenceLength = readLength()
  const sequenceEnd = offset + sequenceLength
  const r = readInteger()
  const s = readInteger()
  if (offset !== sequenceEnd) throw new Error('invalid der')
  const result = new Uint8Array(componentSize * 2)
  result.set(r, 0)
  result.set(s, componentSize)
  return result
}

export async function verifyDeviceRequest(
  request: Request,
  env: Env,
  publicKey: string,
  expectedDeviceId: string,
  bodyText: string,
): Promise<void> {
  const timestamp = request.headers.get('x-device-timestamp') || ''
  const nonce = request.headers.get('x-device-nonce') || ''
  const signatureValue = request.headers.get('x-device-signature') || ''
  const deviceId = request.headers.get('x-device-id') || ''
  if (!timestamp || !nonce || !signatureValue || !deviceId) {
    throw new HttpError(401, 'device_signature_required', '缺少设备签名')
  }
  if (deviceId !== expectedDeviceId) {
    throw new HttpError(401, 'device_mismatch', '授权设备不匹配')
  }
  const timestampMs = Number(timestamp)
  if (!Number.isFinite(timestampMs) || Math.abs(Date.now() - timestampMs) > 5 * 60 * 1000) {
    throw new HttpError(401, 'request_expired', '设备签名已过期')
  }
  if (!/^[A-Za-z0-9_-]{12,128}$/.test(nonce)) {
    throw new HttpError(400, 'invalid_nonce', '设备请求随机值无效')
  }

  const url = new URL(request.url)
  const bodyHash = await sha256Hex(bodyText)
  const canonical = [
    request.method.toUpperCase(),
    `${url.pathname}${url.search}`,
    timestamp,
    nonce,
    bodyHash,
  ].join('\n')
  let verified = false
  try {
    const key = await crypto.subtle.importKey(
      'spki',
      ownedBuffer(base64Decode(publicKey)),
      { name: 'ECDSA', namedCurve: 'P-256' },
      false,
      ['verify'],
    )
    const signature = derToP1363(base64Decode(signatureValue))
    verified = await crypto.subtle.verify(
      { name: 'ECDSA', hash: 'SHA-256' },
      key,
      ownedBuffer(signature),
      ownedBuffer(encoder.encode(canonical)),
    )
  } catch {
    verified = false
  }
  if (!verified) {
    throw new HttpError(401, 'invalid_device_signature', '设备签名验证失败')
  }

  await env.DB.prepare('DELETE FROM request_nonces WHERE expires_at < ?')
    .bind(nowSeconds())
    .run()
  const inserted = await env.DB.prepare(
    'INSERT OR IGNORE INTO request_nonces(device_id, nonce, expires_at) VALUES (?, ?, ?)',
  )
    .bind(deviceId, nonce, nowSeconds() + 10 * 60)
    .run()
  if ((inserted.meta.changes || 0) !== 1) {
    throw new HttpError(409, 'request_replayed', '设备请求已被使用')
  }
}

export async function audit(
  env: Env,
  actorType: string,
  actorId: string,
  action: string,
  targetType: string,
  targetId: string,
  details: unknown = null,
): Promise<void> {
  const encoded = details == null ? '' : JSON.stringify(details).slice(0, 4000)
  await env.DB.prepare(
    `INSERT INTO audit_logs(
      actor_type, actor_id, action, target_type, target_id, details, created_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(actorType, actorId, action, targetType, targetId, encoded, nowSeconds())
    .run()
}

export async function clientKey(request: Request, secret: string): Promise<string> {
  const ip = request.headers.get('cf-connecting-ip') || 'unknown'
  const agent = request.headers.get('user-agent') || ''
  return sha256Hex(`${secret}:${ip}:${agent.slice(0, 200)}`)
}
