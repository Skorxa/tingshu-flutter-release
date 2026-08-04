import type { Env } from './types'
import { HttpError } from './utils'

export const DEFAULT_APP_CONFIG = {
  appEnabled: true,
  appDisabledMessage: '服务维护中，请稍后再试',
  subscriptionEnabled: true,
  subscriptionDisabledMessage: '云端音源暂时停止更新',
} as const

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value)
}

export function normalizeAppConfig(value: unknown): Record<string, unknown> {
  const source = isRecord(value) ? value : {}
  return {
    ...source,
    appEnabled: source.appEnabled !== false,
    appDisabledMessage:
      typeof source.appDisabledMessage === 'string' &&
      source.appDisabledMessage.trim()
        ? source.appDisabledMessage.trim().slice(0, 200)
        : DEFAULT_APP_CONFIG.appDisabledMessage,
    subscriptionEnabled: source.subscriptionEnabled !== false,
    subscriptionDisabledMessage:
      typeof source.subscriptionDisabledMessage === 'string' &&
      source.subscriptionDisabledMessage.trim()
        ? source.subscriptionDisabledMessage.trim().slice(0, 200)
        : DEFAULT_APP_CONFIG.subscriptionDisabledMessage,
  }
}

export function validateAppConfig(value: unknown): Record<string, unknown> {
  if (!isRecord(value)) {
    throw new HttpError(400, 'invalid_cloud_config', '云控配置必须是 JSON 对象')
  }
  for (const key of ['appEnabled', 'subscriptionEnabled']) {
    if (key in value && typeof value[key] !== 'boolean') {
      throw new HttpError(400, 'invalid_cloud_config', `${key} 必须是布尔值`)
    }
  }
  for (const key of ['appDisabledMessage', 'subscriptionDisabledMessage']) {
    if (key in value && typeof value[key] !== 'string') {
      throw new HttpError(400, 'invalid_cloud_config', `${key} 必须是字符串`)
    }
  }
  return normalizeAppConfig(value)
}

export async function loadAppConfig(env: Env): Promise<Record<string, unknown>> {
  const row = await env.DB.prepare(
    'SELECT value FROM cloud_settings WHERE key = ?',
  )
    .bind('app_config')
    .first<{ value: string }>()
  if (row?.value) {
    try {
      return normalizeAppConfig(JSON.parse(row.value))
    } catch {
      throw new HttpError(500, 'invalid_cloud_config', 'D1 云控配置格式错误')
    }
  }

  const object = await env.PRIVATE_BUCKET.get(
    env.CONFIG_OBJECT_KEY || 'control/config.json',
  )
  if (!object) return normalizeAppConfig(DEFAULT_APP_CONFIG)
  try {
    return normalizeAppConfig(JSON.parse(await object.text()))
  } catch {
    throw new HttpError(500, 'invalid_cloud_config', 'R2 云控配置格式错误')
  }
}

export async function assertAppAvailable(env: Env): Promise<void> {
  const config = await loadAppConfig(env)
  if (config.appEnabled === false) {
    throw new HttpError(
      403,
      'app_disabled',
      String(config.appDisabledMessage || DEFAULT_APP_CONFIG.appDisabledMessage),
    )
  }
}

export async function assertSubscriptionAvailable(env: Env): Promise<void> {
  const config = await loadAppConfig(env)
  if (config.appEnabled === false) {
    throw new HttpError(
      403,
      'app_disabled',
      String(config.appDisabledMessage || DEFAULT_APP_CONFIG.appDisabledMessage),
    )
  }
  if (config.subscriptionEnabled === false) {
    throw new HttpError(
      503,
      'subscription_disabled',
      String(
        config.subscriptionDisabledMessage ||
          DEFAULT_APP_CONFIG.subscriptionDisabledMessage,
      ),
    )
  }
}
