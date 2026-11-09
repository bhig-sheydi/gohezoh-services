import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
})

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

async function accessToken(account: { client_email: string; private_key: string }): Promise<string> {
  const now = Math.floor(Date.now() / 1000)
  const header = base64url(new TextEncoder().encode(JSON.stringify({ alg: 'RS256', typ: 'JWT' })))
  const claims = base64url(new TextEncoder().encode(JSON.stringify({ iss: account.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token', iat: now, exp: now + 3600 })))
  const pem = account.private_key.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, '')
  const binary = atob(pem)
  const der = Uint8Array.from(binary, (char) => char.charCodeAt(0))
  const key = await crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign'])
  const payload = `${header}.${claims}`
  const signature = base64url(new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key,
    new TextEncoder().encode(payload))))
  const response = await fetch('https://oauth2.googleapis.com/token', { method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${payload}.${signature}` }), signal: AbortSignal.timeout(10_000) })
  if (!response.ok) throw new Error(`OAuth ${response.status}`)
  const result = await response.json()
  if (typeof result.access_token !== 'string') throw new Error('OAuth token missing')
  return result.access_token
}

Deno.serve(async (request) => {
  if (request.method !== 'POST') return reply({ error: 'Method not allowed' }, 405)
  const expected = Deno.env.get('ADMIN_SPIKE_PUSH_SECRET')
  if (!expected || request.headers.get('x-admin-spike-secret') !== expected)
    return reply({ error: 'Unauthorized' }, 401)
  const rawAccount = Deno.env.get('FIREBASE_SERVICE_ACCOUNT_JSON')
  const url = Deno.env.get('SUPABASE_URL')
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!rawAccount || !url || !serviceKey) return reply({ error: 'Push not configured' }, 503)
  try {
    const account = JSON.parse(rawAccount)
    if (account.project_id !== 'walkinguniverseenterprise' || !account.client_email || !account.private_key)
      throw new Error('Firebase project mismatch')
    const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
    const { data, error } = await db.rpc('claim_admin_spike_push_deliveries', { p_limit: 20 })
    if (error) throw error
    if (!data?.length) return reply({ sent: 0 })
    const token = await accessToken(account)
    let sent = 0
    for (const row of data) {
      let ok = false, invalidToken = false, errorCode = 'send_failed'
      try {
        const response = await fetch(`https://fcm.googleapis.com/v1/projects/${account.project_id}/messages:send`, {
          method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({ message: { token: row.device_token,
            data: { event_id: row.alert_id, type: row.event_type === 'margin' ? 'margin' : 'spike' },
            android: { priority: 'HIGH', ttl: '300s' } } }), signal: AbortSignal.timeout(10_000),
        })
        ok = response.ok
        if (!ok) {
          const errorBody = await response.json().catch(() => ({}))
          errorCode = String(errorBody?.error?.details?.[0]?.errorCode ?? response.status).slice(0, 80)
          invalidToken = errorCode === 'UNREGISTERED'
        }
      } catch (cause) { errorCode = cause instanceof Error ? cause.name : 'network_error' }
      const { error: finishError } = await db.rpc('finish_admin_spike_push_delivery', {
        p_delivery_id: row.delivery_id, p_sent: ok, p_error_code: errorCode, p_invalid_token: invalidToken,
      })
      if (finishError) throw finishError
      if (ok) sent++
    }
    return reply({ sent, attempted: data.length })
  } catch (cause) {
    console.error('Admin push failed:', cause instanceof Error ? cause.message : 'unknown')
    return reply({ error: 'Push unavailable' }, 503)
  }
})
