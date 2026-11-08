import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
const SECRET = /^[A-Za-z0-9_-]{43}$/
const headers = { 'Cache-Control': 'no-store', 'Content-Type': 'application/json' }

function response(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), { status, headers })
}

Deno.serve(async (request) => {
  if (request.method !== 'POST') return response({ error: 'Method not allowed' }, 405)
  const length = Number(request.headers.get('content-length'))
  if (Number.isFinite(length) && length > 4096)
    return response({ error: 'Invalid request' }, 400)
  let payload: Record<string, unknown>
  try {
    const raw = await request.text()
    if (raw.length > 4096) return response({ error: 'Invalid request' }, 400)
    payload = JSON.parse(raw)
    if (!payload || Array.isArray(payload) || typeof payload !== 'object')
      return response({ error: 'Invalid request' }, 400)
  } catch {
    return response({ error: 'Invalid request' }, 400)
  }
  const deviceId = payload.device_id
  const secret = payload.device_secret
  const ackIds = payload.ack_ids ?? []
  if (typeof deviceId !== 'string' || !UUID.test(deviceId) ||
      typeof secret !== 'string' || !SECRET.test(secret) ||
      !Array.isArray(ackIds) || ackIds.length > 20 ||
      ackIds.some((id) => typeof id !== 'string' || !UUID.test(id)))
    return response({ error: 'Invalid request' }, 400)

  const url = Deno.env.get('SUPABASE_URL')
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!url || !serviceKey) return response({ error: 'Alarm service unavailable' }, 503)
  try {
    const db = createClient(url, serviceKey,
      { auth: { persistSession: false, autoRefreshToken: false } })
    const { data, error } = await db.rpc('admin_poll_alarm_device', {
      p_device_id: deviceId, p_secret: secret, p_ack_ids: ackIds,
    })
    if (error) throw error
    if (data?.error === 'unauthorized') return response({ error: 'Unauthorized' }, 401)
    if (data?.error === 'revoked') return response({ error: 'Phone alarm access revoked' }, 403)
    if (data?.error === 'rate_limited') return response({ error: 'Retry later' }, 429)
    if (!data || !Array.isArray(data.alerts) || typeof data.checked_at !== 'string')
      throw new Error('Invalid alarm response')
    return response(data, 200)
  } catch (error) {
    console.error('Admin alarm poll failed:', error instanceof Error ? error.message : 'unknown')
    return response({ error: 'Alarm service unavailable' }, 503)
  }
})
