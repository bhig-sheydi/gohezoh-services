import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { firebaseAccessToken, parseFirebaseServiceAccount, sendFcmSpike,
  type SpikeDelivery } from '../_shared/fcm-spike.ts'

let cachedAccess: { token: string; expiresAt: number } | null = null

Deno.serve(async (request) => {
  if (request.method !== 'POST') return Response.json({ error: 'Method not allowed' }, { status: 405 })
  const workerSecret = Deno.env.get('ADMIN_SPIKE_WORKER_SECRET')
  if (!workerSecret || request.headers.get('x-admin-spike-secret') !== workerSecret)
    return Response.json({ error: 'Unauthorized' }, { status: 401 })
  const url = Deno.env.get('SUPABASE_URL')
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  const rawFirebase = Deno.env.get('FCM_SERVICE_ACCOUNT_JSON')
  if (!url || !serviceKey || !rawFirebase)
    return Response.json({ error: 'Phone push is not configured' }, { status: 503 })

  try {
    const account = parseFirebaseServiceAccount(rawFirebase)
    if (!cachedAccess || cachedAccess.expiresAt <= Date.now())
      cachedAccess = await firebaseAccessToken(account)
    const db = createClient(url, serviceKey,
      { auth: { persistSession: false, autoRefreshToken: false } })
    const { data, error } = await db.rpc('claim_admin_spike_push_deliveries', { p_limit: 20 })
    if (error) throw new Error(`Claim failed: ${error.message}`)
    const deliveries = (data ?? []) as SpikeDelivery[]
    let sent = 0
    let failed = 0
    for (let offset = 0; offset < deliveries.length; offset += 5) {
      await Promise.all(deliveries.slice(offset, offset + 5).map(async (delivery) => {
        let result: { sent: boolean; code: string; invalidToken: boolean }
        try { result = await sendFcmSpike(account, cachedAccess!.token, delivery) }
        catch { result = { sent: false, code: 'network_error', invalidToken: false } }
        const { error: finishError } = await db.rpc('finish_admin_spike_push_delivery', {
          p_delivery_id: delivery.delivery_id,
          p_sent: result.sent,
          p_error_code: result.sent ? null : result.code,
          p_invalid_token: result.invalidToken,
        })
        if (finishError) throw new Error(`Delivery completion failed: ${finishError.message}`)
        if (result.sent) sent++
        else failed++
      }))
    }
    return Response.json({ claimed: deliveries.length, sent, failed })
  } catch (error) {
    console.error('Admin spike push worker failed:', error instanceof Error ? error.message : 'unknown')
    return Response.json({ error: 'Phone push worker failed' }, { status: 500 })
  }
})
