import type { AdminIdentity, Env } from './types'
import { HttpError, audit, json } from './utils'

type SourceEntry = Record<string, unknown> & { url?: string }

interface SourceManifest extends Record<string, unknown> {
  name: string
  version: number
  updatedAt: string
  sources: SourceEntry[]
}

const maxFileBytes = 2 * 1024 * 1024
const maxUploadBytes = 10 * 1024 * 1024
const maxUploadFiles = 20

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value)
}

function subscriptionKey(env: Env): string {
  return (env.SUBSCRIPTION_OBJECT_KEY || 'sources/subscription.json').replace(
    /^\/+/,
    '',
  )
}

function sourcePrefix(env: Env): string {
  const value = (env.SOURCE_PREFIX || 'sources/files/').replace(/^\/+/, '')
  return value.endsWith('/') ? value : `${value}/`
}

function validateFileName(raw: string): string {
  const name = raw.normalize('NFC').trim()
  if (
    !name ||
    name.length > 180 ||
    !name.toLowerCase().endsWith('.js') ||
    name.includes('/') ||
    name.includes('\\') ||
    name.includes('..') ||
    /[\u0000-\u001f\u007f]/.test(name)
  ) {
    throw new HttpError(400, 'invalid_source_name', `音源文件名无效：${raw}`)
  }
  return name
}

function fileNameFromEntry(entry: SourceEntry): string {
  const raw = String(entry.url || '').split(/[?#]/, 1)[0]
  if (!raw) return ''
  const encoded = raw.slice(raw.lastIndexOf('/') + 1)
  try {
    return decodeURIComponent(encoded)
  } catch {
    return encoded
  }
}

function sourceUrl(name: string): string {
  return `sources/${encodeURIComponent(name)}`
}

function nextVersion(value: unknown): number {
  const parsed = Number(value)
  if (Number.isSafeInteger(parsed) && parsed >= 0) return parsed + 1
  return Date.now()
}

export async function readSourceManifest(env: Env): Promise<SourceManifest> {
  const object = await env.PRIVATE_BUCKET.get(subscriptionKey(env))
  if (!object) {
    return {
      name: '橘听音源订阅',
      version: 0,
      updatedAt: '',
      sources: [],
    }
  }
  let decoded: unknown
  try {
    decoded = JSON.parse(await object.text())
  } catch {
    throw new HttpError(500, 'invalid_source_manifest', '云端订阅清单 JSON 无效')
  }
  if (!isRecord(decoded) || !Array.isArray(decoded.sources)) {
    throw new HttpError(500, 'invalid_source_manifest', '云端订阅清单缺少 sources')
  }
  return {
    ...decoded,
    name: String(decoded.name || '橘听音源订阅').slice(0, 100),
    version: Number(decoded.version) || 0,
    updatedAt: String(decoded.updatedAt || ''),
    sources: decoded.sources.filter(isRecord) as SourceEntry[],
  }
}

async function writeSourceManifest(
  env: Env,
  current: SourceManifest,
  sources: SourceEntry[],
): Promise<SourceManifest> {
  const manifest: SourceManifest = {
    ...current,
    name: current.name || '橘听音源订阅',
    version: nextVersion(current.version),
    updatedAt: new Date().toISOString(),
    sources,
  }
  await env.PRIVATE_BUCKET.put(
    subscriptionKey(env),
    `${JSON.stringify(manifest, null, 2)}\n`,
    { httpMetadata: { contentType: 'application/json; charset=utf-8' } },
  )
  return manifest
}

async function listObjects(env: Env): Promise<R2Object[]> {
  const objects: R2Object[] = []
  let cursor: string | undefined
  do {
    const page = await env.PRIVATE_BUCKET.list({
      prefix: sourcePrefix(env),
      cursor,
      limit: 1000,
    })
    objects.push(...page.objects)
    cursor = page.truncated ? page.cursor : undefined
  } while (cursor && objects.length < 5000)
  return objects
}

export async function sourceSnapshot(request: Request, env: Env): Promise<Response> {
  const [manifest, objects] = await Promise.all([
    readSourceManifest(env),
    listObjects(env),
  ])
  const prefix = sourcePrefix(env)
  const entries = new Map<string, SourceEntry>()
  for (const entry of manifest.sources) {
    const name = fileNameFromEntry(entry)
    if (name) entries.set(name, entry)
  }
  const files = objects.map((object) => {
    const name = object.key.slice(prefix.length)
    const inManifest = entries.delete(name)
    return {
      name,
      size: object.size,
      uploadedAt: object.uploaded.toISOString(),
      inManifest: Boolean(inManifest),
      missing: false,
    }
  })
  for (const name of entries.keys()) {
    files.push({
      name,
      size: 0,
      uploadedAt: '',
      inManifest: true,
      missing: true,
    })
  }
  files.sort((left, right) => left.name.localeCompare(right.name, 'zh-CN'))
  return json({
    ok: true,
    data: {
      subscriptionUrl: new URL('/api/subscription', request.url).toString(),
      name: manifest.name,
      version: manifest.version,
      updatedAt: manifest.updatedAt,
      sourceCount: manifest.sources.length,
      objectCount: objects.length,
      files,
    },
  })
}

export async function uploadSources(
  request: Request,
  env: Env,
  admin: AdminIdentity,
): Promise<Response> {
  const declaredSize = Number(request.headers.get('content-length') || 0)
  if (declaredSize > maxUploadBytes) {
    throw new HttpError(413, 'source_upload_too_large', '单次上传不能超过 10 MB')
  }
  const form = await request.formData()
  const files = form
    .getAll('files')
    .filter((value): value is File => value instanceof File)
  if (files.length < 1) {
    throw new HttpError(400, 'source_files_required', '请选择要上传的 JS 音源')
  }
  if (files.length > maxUploadFiles) {
    throw new HttpError(400, 'too_many_source_files', '单次最多上传 20 个音源')
  }
  const totalSize = files.reduce((sum, file) => sum + file.size, 0)
  if (totalSize > maxUploadBytes) {
    throw new HttpError(413, 'source_upload_too_large', '单次上传不能超过 10 MB')
  }

  const names = new Set<string>()
  const uploaded: string[] = []
  for (const file of files) {
    const name = validateFileName(file.name)
    if (names.has(name)) {
      throw new HttpError(400, 'duplicate_source_file', `文件名重复：${name}`)
    }
    names.add(name)
    if (file.size < 1 || file.size > maxFileBytes) {
      throw new HttpError(413, 'invalid_source_size', `${name} 必须小于 2 MB`)
    }
    const code = await file.text()
    if (!code.trim()) {
      throw new HttpError(400, 'empty_source_file', `${name} 内容为空`)
    }
    await env.PRIVATE_BUCKET.put(`${sourcePrefix(env)}${name}`, code, {
      httpMetadata: { contentType: 'text/javascript; charset=utf-8' },
    })
    uploaded.push(name)
  }

  const current = await readSourceManifest(env)
  const existingNames = new Set(current.sources.map(fileNameFromEntry))
  const entries = [...current.sources]
  for (const name of uploaded) {
    if (!existingNames.has(name)) entries.push({ url: sourceUrl(name) })
  }
  const manifest = await writeSourceManifest(env, current, entries)
  await audit(env, 'admin', admin.id, 'source.upload', 'subscription', 'default', {
    files: uploaded,
    version: manifest.version,
  })
  return sourceSnapshot(request, env)
}

export async function deleteSource(
  request: Request,
  env: Env,
  admin: AdminIdentity,
  encodedName: string,
): Promise<Response> {
  let rawName: string
  try {
    rawName = decodeURIComponent(encodedName)
  } catch {
    throw new HttpError(400, 'invalid_source_name', '音源文件名编码无效')
  }
  const name = validateFileName(rawName)
  const current = await readSourceManifest(env)
  const nextEntries = current.sources.filter(
    (entry) => fileNameFromEntry(entry) !== name,
  )
  const key = `${sourcePrefix(env)}${name}`
  const object = await env.PRIVATE_BUCKET.head(key)
  if (!object && nextEntries.length === current.sources.length) {
    throw new HttpError(404, 'source_not_found', '云端音源不存在')
  }
  if (object) await env.PRIVATE_BUCKET.delete(key)
  const manifest = await writeSourceManifest(env, current, nextEntries)
  await audit(env, 'admin', admin.id, 'source.delete', 'source', name, {
    version: manifest.version,
  })
  return sourceSnapshot(request, env)
}
