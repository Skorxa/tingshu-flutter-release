export interface Env {
  DB: D1Database
  PRIVATE_BUCKET: R2Bucket
  ASSETS: Fetcher
  APP_NAME?: string
  ADMIN_EMAILS?: string
  ADMIN_PASSWORD?: string
  ADMIN_SESSION_SECRET?: string
  ACCESS_TOKEN_TTL_SECONDS?: string
  REFRESH_TOKEN_TTL_SECONDS?: string
  ADMIN_SESSION_TTL_SECONDS?: string
  OFFLINE_GRACE_SECONDS?: string
  CONFIG_OBJECT_KEY?: string
  SUBSCRIPTION_OBJECT_KEY?: string
  SOURCE_PREFIX?: string
}

export interface AppIdentity {
  sessionId: string
  userId: string
  deviceId: string
  displayName: string
  userStatus: string
  expiresAt: number | null
  maxDevices: number
  publicKey: string
}

export interface AdminIdentity {
  id: string
  mode: 'access' | 'password'
  csrfToken: string
}

export interface SessionTokens {
  accessToken: string
  accessExpiresAt: number
  refreshToken: string
  refreshExpiresAt: number
}
