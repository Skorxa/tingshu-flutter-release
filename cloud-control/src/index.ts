import { handleAdminRequest } from './admin-routes'
import { handleAppRequest } from './app-routes'
import type { Env } from './types'
import { HttpError, errorResponse, json } from './utils'

function secure(response: Response, adminPage = false): Response {
  const headers = new Headers(response.headers)
  headers.set('X-Content-Type-Options', 'nosniff')
  headers.set('Referrer-Policy', 'no-referrer')
  headers.set('Permissions-Policy', 'camera=(), microphone=(), geolocation=()')
  headers.set('Cross-Origin-Resource-Policy', 'same-origin')
  headers.set('Strict-Transport-Security', 'max-age=31536000')
  if (adminPage) {
    headers.set(
      'Content-Security-Policy',
      "default-src 'self'; connect-src 'self'; img-src 'self' data:; " +
        "style-src 'self'; script-src 'self'; frame-ancestors 'none'; " +
        "base-uri 'none'; form-action 'self'",
    )
  }
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  })
}

async function adminAsset(request: Request, env: Env): Promise<Response> {
  if (!env.ASSETS) throw new HttpError(503, 'assets_not_configured', '管理页面尚未部署')
  const url = new URL(request.url)
  if (url.pathname === '/admin' || url.pathname === '/admin/') {
    url.pathname = '/admin/index.html'
  }
  const asset = await env.ASSETS.fetch(new Request(url, request))
  return secure(asset, true)
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const url = new URL(request.url)
      const localHosts = new Set(['localhost', '127.0.0.1', '10.0.2.2'])
      if (url.protocol === 'http:' && !localHosts.has(url.hostname.toLowerCase())) {
        url.protocol = 'https:'
        return secure(Response.redirect(url.toString(), 308))
      }
      if (request.method === 'OPTIONS') {
        return secure(new Response(null, { status: 204 }))
      }
      if (request.method === 'GET' && url.pathname === '/health') {
        const db = await env.DB.prepare('SELECT 1 AS ok').first<{ ok: number }>()
        return secure(
          json({
            ok: db?.ok === 1,
            service: env.APP_NAME || '橘听',
            time: Math.floor(Date.now() / 1000),
          }),
        )
      }
      if (url.pathname.startsWith('/admin/api/')) {
        return secure(await handleAdminRequest(request, env))
      }
      if (url.pathname === '/admin' || url.pathname.startsWith('/admin/')) {
        return adminAsset(request, env)
      }
      if (url.pathname.startsWith('/api/')) {
        return secure(await handleAppRequest(request, env))
      }
      throw new HttpError(404, 'not_found', '页面不存在')
    } catch (error) {
      return secure(errorResponse(error))
    }
  },
} satisfies ExportedHandler<Env>
