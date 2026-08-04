const state = {
  csrf: '',
  users: new Map(),
  currentUserId: '',
  sourceSnapshot: null,
  toastTimer: null,
}

const $ = (selector) => document.querySelector(selector)
const $$ = (selector) => [...document.querySelectorAll(selector)]

function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;')
}

function formatTime(value) {
  const seconds = Number(value)
  if (!seconds) return '不限'
  return new Intl.DateTimeFormat('zh-CN', {
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hour12: false,
  }).format(new Date(seconds * 1000))
}

function toLocalInput(value) {
  if (!value) return ''
  const date = new Date(Number(value) * 1000)
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000)
  return local.toISOString().slice(0, 16)
}

function formatDateTime(value) {
  if (!value) return '-'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return '-'
  return new Intl.DateTimeFormat('zh-CN', {
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hour12: false,
  }).format(date)
}

function formatBytes(value) {
  const bytes = Number(value) || 0
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / 1024 / 1024).toFixed(2)} MB`
}

function toast(message) {
  const node = $('#toast')
  node.textContent = message
  node.hidden = false
  clearTimeout(state.toastTimer)
  state.toastTimer = setTimeout(() => { node.hidden = true }, 3200)
}

async function api(path, options = {}) {
  const method = String(options.method || 'GET').toUpperCase()
  const headers = new Headers(options.headers || {})
  if (options.body != null && !(options.body instanceof FormData) && !headers.has('Content-Type')) {
    headers.set('Content-Type', 'application/json')
  }
  if (!['GET', 'HEAD'].includes(method) && state.csrf) {
    headers.set('X-CSRF-Token', state.csrf)
  }
  const response = await fetch(path, {
    ...options,
    method,
    headers,
    credentials: 'same-origin',
  })
  let payload = null
  try { payload = await response.json() } catch { payload = null }
  if (!response.ok) {
    if (response.status === 401 && path !== '/admin/api/login') showLogin()
    throw new Error(payload?.error?.message || `请求失败：${response.status}`)
  }
  return payload?.data ?? payload
}

function showLogin() {
  $('#appView').hidden = true
  $('#loginView').hidden = false
  state.csrf = ''
}

function showApp(me) {
  $('#loginView').hidden = true
  $('#appView').hidden = false
  state.csrf = me.csrfToken
  $('#adminIdentity').textContent = me.id
}

function badge(status, expiresAt = null) {
  const expired = expiresAt && Number(expiresAt) <= Math.floor(Date.now() / 1000)
  const value = expired ? 'expired' : status
  const labels = { active: '正常', disabled: '已禁用', revoked: '已撤销', expired: '已过期' }
  return `<span class="badge ${escapeHtml(value)}">${labels[value] || escapeHtml(value)}</span>`
}

async function loadSummary() {
  const data = await api('/admin/api/summary')
  $('#metricUsers').textContent = data.users
  $('#metricActiveUsers').textContent = data.activeUsers
  $('#metricDevices').textContent = data.activeDevices
  $('#metricInvites').textContent = data.activeInvites
}

async function loadUsers() {
  const query = new URLSearchParams({
    q: $('#userSearch').value.trim(),
    status: $('#userStatus').value,
  })
  const rows = await api(`/admin/api/users?${query}`)
  state.users = new Map(rows.map((row) => [row.id, row]))
  $('#usersBody').innerHTML = rows.map((row) => `
    <tr>
      <td><strong>${escapeHtml(row.display_name)}</strong><br><span class="muted">${escapeHtml(row.id)}</span></td>
      <td>${badge(row.status, row.expires_at)}</td>
      <td>${escapeHtml(formatTime(row.expires_at))}</td>
      <td>${Number(row.device_count || 0)} / ${Number(row.max_devices || 1)}</td>
      <td>${escapeHtml(row.last_seen_at ? formatTime(row.last_seen_at) : '从未')}</td>
      <td class="actions">
        <button data-action="edit-user" data-id="${escapeHtml(row.id)}">设置</button>
        <button data-action="revoke-user" data-id="${escapeHtml(row.id)}">下线</button>
        <button class="${row.status === 'active' ? 'danger' : ''}" data-action="toggle-user" data-id="${escapeHtml(row.id)}">${row.status === 'active' ? '禁用' : '启用'}</button>
      </td>
    </tr>
  `).join('')
  $('#usersEmpty').hidden = rows.length > 0
}

async function loadInvites() {
  const query = new URLSearchParams({
    q: $('#inviteSearch').value.trim(),
    status: $('#inviteStatus').value,
  })
  const rows = await api(`/admin/api/invites?${query}`)
  const now = Math.floor(Date.now() / 1000)
  $('#invitesBody').innerHTML = rows.map((row) => {
    let status = row.status
    if (status === 'active' && row.expires_at && Number(row.expires_at) <= now) status = 'expired'
    if (status === 'active' && Number(row.used_count) >= Number(row.max_uses)) status = 'expired'
    return `
      <tr>
        <td><strong>${escapeHtml(row.label)}</strong>${row.user_name ? `<br><span class="muted">${escapeHtml(row.user_name)}</span>` : ''}</td>
        <td><code class="invite-code-cell">${escapeHtml(row.code || '-')}</code></td>
        <td>${badge(status)}</td>
        <td>${Number(row.used_count)} / ${Number(row.max_uses)}</td>
        <td>${Number(row.authorization_days) === 0 ? '永久' : `${Number(row.authorization_days)} 天`}</td>
        <td>${escapeHtml(formatTime(row.expires_at))}</td>
        <td>${escapeHtml(formatTime(row.created_at))}</td>
        <td class="actions">
          <button data-action="detail-invite" data-id="${escapeHtml(row.id)}">详情</button>
          <button data-action="edit-invite" data-id="${escapeHtml(row.id)}">编辑</button>
          <button class="danger" data-action="revoke-invite" data-id="${escapeHtml(row.id)}" ${row.status !== 'active' ? 'disabled' : ''}>撤销</button>
          <button class="danger" data-action="delete-invite" data-id="${escapeHtml(row.id)}">删除</button>
        </td>
      </tr>
    `
  }).join('')
  $('#invitesEmpty').hidden = rows.length > 0
}

async function loadConfig() {
  const data = await api('/admin/api/config')
  $('#configEditor').value = JSON.stringify(data.value || {}, null, 2)
  $('#configMeta').textContent = data.updatedAt ? `最后保存：${formatTime(data.updatedAt)}` : '尚未保存云控配置'
}

function renderSources(data) {
  state.sourceSnapshot = data
  $('#sourceVersion').textContent = data.version ?? '-'
  $('#sourceManifestCount').textContent = Number(data.sourceCount || 0)
  $('#sourceObjectCount').textContent = Number(data.objectCount || 0)
  $('#sourceUpdatedAt').textContent = formatDateTime(data.updatedAt)
  $('#subscriptionUrl').value = data.subscriptionUrl || ''
  const files = Array.isArray(data.files) ? data.files : []
  $('#sourcesBody').innerHTML = files.map((file) => {
    const status = file.missing
      ? '<span class="badge disabled">文件缺失</span>'
      : file.inManifest
        ? '<span class="badge active">已订阅</span>'
        : '<span class="badge pending">未入清单</span>'
    return `
      <tr>
        <td><strong class="source-name">${escapeHtml(file.name)}</strong></td>
        <td>${status}</td>
        <td>${file.missing ? '-' : escapeHtml(formatBytes(file.size))}</td>
        <td>${escapeHtml(formatDateTime(file.uploadedAt))}</td>
        <td class="actions"><button class="danger" data-action="delete-source" data-name="${escapeHtml(file.name)}">删除</button></td>
      </tr>
    `
  }).join('')
  $('#sourcesEmpty').hidden = files.length > 0
}

async function loadSources() {
  renderSources(await api('/admin/api/sources'))
}

async function loadAudit() {
  const rows = await api('/admin/api/audit')
  $('#auditBody').innerHTML = rows.map((row) => {
    let details = row.details || ''
    try { details = row.details ? JSON.stringify(JSON.parse(row.details)) : '' } catch {}
    return `
      <tr>
        <td>${escapeHtml(formatTime(row.created_at))}</td>
        <td>${escapeHtml(row.actor_type)}<br><span class="muted">${escapeHtml(row.actor_id)}</span></td>
        <td>${escapeHtml(row.action)}</td>
        <td>${escapeHtml(row.target_type)}<br><span class="muted">${escapeHtml(row.target_id)}</span></td>
        <td title="${escapeHtml(details)}">${escapeHtml(details.slice(0, 100) || '-')}</td>
      </tr>
    `
  }).join('')
  $('#auditEmpty').hidden = rows.length > 0
}

async function refreshCurrentView() {
  const view = $('.nav-item.active')?.dataset.view || 'users'
  await loadSummary()
  if (view === 'users') await loadUsers()
  if (view === 'invites') await loadInvites()
  if (view === 'sources') await loadSources()
  if (view === 'config') await loadConfig()
  if (view === 'audit') await loadAudit()
}

async function openUser(userId) {
  const user = state.users.get(userId)
  if (!user) return
  state.currentUserId = userId
  $('#editUserId').value = userId
  $('#editDisplayName').value = user.display_name
  $('#editMaxDevices').value = user.max_devices
  $('#editExpiresAt').value = toLocalInput(user.expires_at)
  const devices = await api(`/admin/api/users/${encodeURIComponent(userId)}/devices`)
  $('#deviceList').innerHTML = devices.length ? devices.map((device) => `
    <div class="device-row">
      <div><strong>${escapeHtml(device.name)}</strong><span>${escapeHtml(device.app_version || device.platform)} · ${escapeHtml(formatTime(device.last_seen_at))}</span></div>
      <button class="${device.status === 'active' ? 'danger' : ''}" data-action="toggle-device" data-id="${escapeHtml(device.id)}" data-status="${escapeHtml(device.status)}">${device.status === 'active' ? '停用' : '启用'}</button>
    </div>
  `).join('') : '<p class="empty">暂无设备</p>'
  if (!$('#userDialog').open) $('#userDialog').showModal()
}

async function handleUserAction(button) {
  const id = button.dataset.id
  const action = button.dataset.action
  if (action === 'edit-user') return openUser(id)
  if (action === 'toggle-user') {
    const user = state.users.get(id)
    const next = user.status === 'active' ? 'disabled' : 'active'
    if (next === 'disabled' && !confirm(`确定禁用 ${user.display_name}？`)) return
    await api(`/admin/api/users/${encodeURIComponent(id)}/status`, {
      method: 'POST', body: JSON.stringify({ status: next }),
    })
    toast(next === 'disabled' ? '用户已禁用' : '用户已启用')
  }
  if (action === 'revoke-user') {
    if (!confirm('确定让该用户所有设备重新登录？')) return
    await api(`/admin/api/users/${encodeURIComponent(id)}/revoke-sessions`, {
      method: 'POST', body: '{}',
    })
    toast('用户会话已撤销')
  }
  await Promise.all([loadUsers(), loadSummary()])
}

async function init() {
  try {
    const me = await api('/admin/api/me')
    showApp(me)
    await Promise.all([loadSummary(), loadUsers()])
  } catch (error) {
    showLogin()
    if (!String(error.message).includes('管理员尚未登录')) {
      $('#loginError').textContent = error.message
    }
  }
}

$('#loginForm').addEventListener('submit', async (event) => {
  event.preventDefault()
  $('#loginError').textContent = ''
  try {
    const data = await api('/admin/api/login', {
      method: 'POST',
      body: JSON.stringify({ password: $('#adminPassword').value }),
    })
    state.csrf = data.csrfToken
    const me = await api('/admin/api/me')
    showApp(me)
    $('#adminPassword').value = ''
    await Promise.all([loadSummary(), loadUsers()])
  } catch (error) {
    $('#loginError').textContent = error.message
  }
})

$('#logoutButton').addEventListener('click', async () => {
  try { await api('/admin/api/logout', { method: 'POST', body: '{}' }) } catch {}
  showLogin()
})

$('#refreshAll').addEventListener('click', () => refreshCurrentView().catch((error) => toast(error.message)))
$('#searchUsers').addEventListener('click', () => loadUsers().catch((error) => toast(error.message)))
$('#userSearch').addEventListener('keydown', (event) => {
  if (event.key === 'Enter') loadUsers().catch((error) => toast(error.message))
})

$$('.nav-item').forEach((button) => button.addEventListener('click', async () => {
  $$('.nav-item').forEach((item) => item.classList.toggle('active', item === button))
  $$('.view-section').forEach((view) => { view.hidden = view.id !== `${button.dataset.view}View` })
  try {
    if (button.dataset.view === 'users') await loadUsers()
    if (button.dataset.view === 'invites') await loadInvites()
    if (button.dataset.view === 'sources') await loadSources()
    if (button.dataset.view === 'config') await loadConfig()
    if (button.dataset.view === 'audit') await loadAudit()
  } catch (error) { toast(error.message) }
}))

$('#usersBody').addEventListener('click', (event) => {
  const button = event.target.closest('button[data-action]')
  if (button) handleUserAction(button).catch((error) => toast(error.message))
})

$('#openInviteDialog').addEventListener('click', () => $('#inviteDialog').showModal())
$('#inviteForm').addEventListener('submit', async (event) => {
  if (event.submitter?.value === 'cancel') return
  event.preventDefault()
  const form = new FormData(event.currentTarget)
  const body = Object.fromEntries(form.entries())
  for (const key of ['expiresDays', 'authorizationDays', 'maxUses', 'maxDevices']) body[key] = Number(body[key])
  try {
    const data = await api('/admin/api/invites', { method: 'POST', body: JSON.stringify(body) })
    $('#inviteDialog').close()
    $('#createdInviteCode').textContent = data.code
    $('#inviteResultDialog').showModal()
    await Promise.all([loadInvites(), loadSummary()])
  } catch (error) { toast(error.message) }
})

$('#invitesBody').addEventListener('click', async (event) => {
  const button = event.target.closest('button[data-action]')
  if (!button) return
  const action = button.dataset.action
  const id = button.dataset.id
  try {
    if (action === 'detail-invite') return await openInviteDetail(id)
    if (action === 'edit-invite') return await openInviteEdit(id)
    if (action === 'revoke-invite') {
      if (!confirm('确定撤销这个邀请码？')) return
      await api(`/admin/api/invites/${encodeURIComponent(id)}/revoke`, { method: 'POST', body: '{}' })
      toast('邀请码已撤销')
      await Promise.all([loadInvites(), loadSummary()])
    }
    if (action === 'delete-invite') {
      if (!confirm('确定永久删除这个邀请码？此操作不可恢复。')) return
      await api(`/admin/api/invites/${encodeURIComponent(id)}`, { method: 'DELETE' })
      toast('邀请码已删除')
      await Promise.all([loadInvites(), loadSummary()])
    }
  } catch (error) { toast(error.message) }
})

$('#closeInviteResult').addEventListener('click', () => $('#inviteResultDialog').close())
$('#copyInviteCode').addEventListener('click', async () => {
  await navigator.clipboard.writeText($('#createdInviteCode').textContent)
  toast('邀请码已复制')
})

$('#searchInvites').addEventListener('click', () => loadInvites().catch((error) => toast(error.message)))
$('#inviteSearch').addEventListener('keydown', (event) => {
  if (event.key === 'Enter') loadInvites().catch((error) => toast(error.message))
})

async function openInviteDetail(id) {
  const data = await api(`/admin/api/invites/${encodeURIComponent(id)}`)
  const devices = Array.isArray(data.devices) ? data.devices : []
  $('#inviteDetailBody').innerHTML = `
    <div class="detail-grid">
      <div><span class="muted">激活码</span><code class="invite-code-cell">${escapeHtml(data.code || '-')}</code></div>
      <div><span class="muted">用途</span><strong>${escapeHtml(data.label)}</strong></div>
      <div><span class="muted">状态</span>${badge(data.status)}</div>
      <div><span class="muted">使用次数</span>${Number(data.used_count)} / ${Number(data.max_uses)}</div>
      <div><span class="muted">授权期限</span>${Number(data.authorization_days) === 0 ? '永久' : `${Number(data.authorization_days)} 天`}</div>
      <div><span class="muted">设备上限</span>${Number(data.max_devices)}</div>
      <div><span class="muted">邀请码到期</span>${escapeHtml(formatTime(data.expires_at))}</div>
      <div><span class="muted">创建时间</span>${escapeHtml(formatTime(data.created_at))}</div>
      <div><span class="muted">创建者</span>${escapeHtml(data.created_by || '-')}</div>
      ${data.user_name ? `<div><span class="muted">绑定用户</span>${escapeHtml(data.user_name)}</div>` : ''}
    </div>
    <h3>已激活设备（${devices.length}）</h3>
    <div class="device-list">
      ${devices.length ? devices.map((d) => `
        <div class="device-row">
          <div><strong>${escapeHtml(d.name)}</strong><span>${escapeHtml(d.app_version || d.platform)} · ${escapeHtml(formatTime(d.last_seen_at))}</span></div>
          ${badge(d.status)}
        </div>
      `).join('') : '<p class="empty">暂无设备使用此邀请码</p>'}
    </div>
  `
  if (!$('#inviteDetailDialog').open) $('#inviteDetailDialog').showModal()
}

async function openInviteEdit(id) {
  const data = await api(`/admin/api/invites/${encodeURIComponent(id)}`)
  $('#editInviteId').value = id
  $('#editInviteLabel').value = data.label || ''
  $('#editInviteMaxUses').value = data.max_uses ?? 1
  $('#editInviteMaxDevices').value = data.max_devices ?? 1
  $('#editInviteAuthDays').value = data.authorization_days ?? 365
  const now = Math.floor(Date.now() / 1000)
  const remaining = data.expires_at ? Math.max(0, Math.ceil((Number(data.expires_at) - now) / 86400)) : 0
  $('#editInviteExpiresDays').value = remaining
  if (!$('#inviteEditDialog').open) $('#inviteEditDialog').showModal()
}

document.querySelectorAll('[data-close]').forEach((btn) => {
  btn.addEventListener('click', () => {
    const dialog = document.getElementById(btn.dataset.close)
    if (dialog?.open) dialog.close()
  })
})

$('#inviteEditForm').addEventListener('submit', async (event) => {
  if (event.submitter?.value === 'cancel') return
  event.preventDefault()
  const body = {
    label: $('#editInviteLabel').value.trim(),
    maxUses: Number($('#editInviteMaxUses').value),
    maxDevices: Number($('#editInviteMaxDevices').value),
    authorizationDays: Number($('#editInviteAuthDays').value),
    expiresDays: Number($('#editInviteExpiresDays').value),
  }
  try {
    await api(`/admin/api/invites/${encodeURIComponent($('#editInviteId').value)}`, {
      method: 'PUT', body: JSON.stringify(body),
    })
    $('#inviteEditDialog').close()
    toast('邀请码已更新')
    await loadInvites()
  } catch (error) { toast(error.message) }
})

$('#refreshSources').addEventListener('click', () => loadSources().catch((error) => toast(error.message)))

$('#copySubscriptionUrl').addEventListener('click', async () => {
  const value = $('#subscriptionUrl').value
  if (!value) return toast('订阅链接尚未生成')
  try {
    await navigator.clipboard.writeText(value)
    toast('订阅链接已复制')
  } catch {
    $('#subscriptionUrl').select()
    toast('请手动复制已选中的订阅链接')
  }
})

$('#sourceFiles').addEventListener('change', (event) => {
  const files = [...event.currentTarget.files]
  $('#sourceSelection').textContent = files.length
    ? `${files.length} 个文件：${files.map((file) => file.name).join('、')}`
    : '未选择文件'
  $('#uploadSources').disabled = files.length === 0
})

$('#uploadSources').addEventListener('click', async () => {
  const input = $('#sourceFiles')
  const files = [...input.files]
  if (!files.length) return
  const form = new FormData()
  for (const file of files) form.append('files', file, file.name)
  const button = $('#uploadSources')
  button.disabled = true
  button.textContent = '上传中...'
  try {
    renderSources(await api('/admin/api/sources/upload', { method: 'POST', body: form }))
    input.value = ''
    $('#sourceSelection').textContent = '未选择文件'
    toast(`已上传 ${files.length} 个音源，订阅版本已更新`)
  } catch (error) {
    toast(error.message)
  } finally {
    button.textContent = '上传或覆盖'
    button.disabled = input.files.length === 0
  }
})

$('#sourcesBody').addEventListener('click', async (event) => {
  const button = event.target.closest('button[data-action="delete-source"]')
  if (!button) return
  const name = button.dataset.name
  if (!confirm(`确定删除音源「${name}」？`)) return
  button.disabled = true
  try {
    renderSources(await api(`/admin/api/sources/${encodeURIComponent(name)}`, { method: 'DELETE' }))
    toast('音源已删除，订阅版本已更新')
  } catch (error) {
    button.disabled = false
    toast(error.message)
  }
})

$('#saveConfig').addEventListener('click', async () => {
  try {
    const value = JSON.parse($('#configEditor').value)
    const data = await api('/admin/api/config', {
      method: 'PUT', body: JSON.stringify({ value }),
    })
    $('#configEditor').value = JSON.stringify(data.value || value, null, 2)
    $('#configMeta').textContent = `最后保存：${formatTime(data.updatedAt)}`
    toast('云控配置已保存')
  } catch (error) { toast(error instanceof SyntaxError ? 'JSON 格式无效' : error.message) }
})

$('#refreshAudit').addEventListener('click', () => loadAudit().catch((error) => toast(error.message)))

$('#userForm').addEventListener('submit', async (event) => {
  if (event.submitter?.value === 'cancel') return
  event.preventDefault()
  const expiresValue = $('#editExpiresAt').value
  const body = {
    displayName: $('#editDisplayName').value.trim(),
    maxDevices: Number($('#editMaxDevices').value),
    expiresAt: expiresValue ? Math.floor(new Date(expiresValue).getTime() / 1000) : null,
  }
  try {
    await api(`/admin/api/users/${encodeURIComponent(state.currentUserId)}`, {
      method: 'PUT', body: JSON.stringify(body),
    })
    $('#userDialog').close()
    toast('用户设置已保存')
    await loadUsers()
  } catch (error) { toast(error.message) }
})

$('#deviceList').addEventListener('click', async (event) => {
  const button = event.target.closest('button[data-action="toggle-device"]')
  if (!button) return
  const status = button.dataset.status === 'active' ? 'disabled' : 'active'
  try {
    await api(`/admin/api/devices/${encodeURIComponent(button.dataset.id)}/status`, {
      method: 'POST', body: JSON.stringify({ status }),
    })
    toast(status === 'disabled' ? '设备已停用' : '设备已启用')
    await openUser(state.currentUserId)
  } catch (error) { toast(error.message) }
})

init()
