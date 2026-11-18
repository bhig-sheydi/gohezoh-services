import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { assessDojahRiderEvent, verifyDojahSignature, type DojahRiderEvent } from '../_shared/dojah.ts'

Deno.serve(async request => {
  if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 })
  const secret = Deno.env.get('DOJAH_WEBHOOK_SECRET') ?? ''
  const widgetId = Deno.env.get('DOJAH_RIDER_WIDGET_ID') ?? ''
  if (!secret || !widgetId) return new Response('Not configured', { status: 503 })
  const raw = await request.text()
  if (raw.length > 200_000) return new Response('Payload too large', { status: 413 })
  if (!await verifyDojahSignature(raw, request.headers.get('x-dojah-signature') ?? '', secret))
    return new Response('Invalid signature', { status: 401 })
  let event: DojahRiderEvent
  try { event = JSON.parse(raw) } catch { return new Response('Invalid event', { status: 400 }) }
  // Sandbox widget results must never activate riders in the live database.
  if (Deno.env.get('DOJAH_RIDER_LIVE_ENABLED') !== 'true')
    return Response.json({ received: true, activation: 'disabled' })
  const outcome = assessDojahRiderEvent(event, widgetId)
  if (outcome === 'pending' || event.widget_id !== widgetId || typeof event.reference_id !== 'string')
    return Response.json({ received: true })
  const admin = createClient(Deno.env.get('SUPABASE_URL') ?? '', Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    { auth: { persistSession: false } })
  const { error } = await admin.rpc('finish_independent_rider_verification', {
    p_reference: event.reference_id, p_passed: outcome === 'passed',
    p_reason: outcome === 'failed' ? 'NIN, face, or address verification did not pass' : null,
  })
  if (error) { console.error('Dojah rider verification update failed', error); return new Response('Retry later', { status: 503 }) }
  return Response.json({ received: true })
})
