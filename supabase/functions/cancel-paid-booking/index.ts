import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

type Refund = { id?: number; reference?: string; transaction?: number; amount?: number; currency?: string; status?: string }
type Envelope = { status?: boolean; message?: string; data?: Refund | Refund[] }
const allowed = new Set(['pending', 'processing', 'needs-attention', 'processed', 'failed'])

async function paystack(path: string, secret: string, init?: RequestInit): Promise<Envelope> {
  const response = await fetch(`https://api.paystack.co${path}`, {
    ...init, headers: { Authorization: `Bearer ${secret}`, 'Content-Type': 'application/json' }, signal: AbortSignal.timeout(10000),
  })
  const body = await response.json() as Envelope
  if (!response.ok || !body.status) throw new Error(body.message || 'Refund provider unavailable')
  return body
}

Deno.serve(async (request) => {
  if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 })
  const token = request.headers.get('Authorization')?.replace(/^Bearer /i, '') ?? ''
  const secret = Deno.env.get('PAYSTACK_SECRET_KEY') ?? ''
  const url = Deno.env.get('SUPABASE_URL') ?? ''
  const anon = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
  const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
  if (!secret || !url || !anon || !service) return Response.json({ error: 'Cancellation is unavailable' }, { status: 503 })
  let jobId = ''
  try { jobId = String((await request.json()).job_id ?? '') } catch { return Response.json({ error: 'Invalid request' }, { status: 400 }) }
  if (!/^[0-9a-f]{8}-[0-9a-f-]{27,}$/i.test(jobId)) return Response.json({ error: 'Invalid job' }, { status: 400 })
  const userClient = createClient(url, anon, { global: { headers: { Authorization: `Bearer ${token}` } }, auth: { persistSession: false } })
  const { data: userData, error: userError } = await userClient.auth.getUser(token)
  if (userError || !userData.user) return Response.json({ error: 'Sign in to cancel your booking' }, { status: 401 })
  const { data: claim, error: claimError } = await userClient.rpc('request_paid_bike_cancellation', { p_job_id: jobId })
  if (claimError) return Response.json({ error: claimError.message }, { status: 400 })
  const admin = createClient(url, service, { auth: { persistSession: false } })
  const { data: record, error: lookupError } = await admin.from('paid_booking_cancellations')
    .select('refund_reference,payment_reference,provider_transaction_id,refund_amount_ngn,status')
    .eq('job_id', jobId).single()
  if (lookupError || !record || record.refund_reference !== claim.refund_reference) return Response.json({ error: 'Cancellation unavailable' }, { status: 503 })
  if (record.status === 'processed') return Response.json({ status: record.status, refund_amount_ngn: record.refund_amount_ngn })
  try {
    let refund: Refund | undefined
    try {
      const created = await paystack('/refund', secret, { method: 'POST', body: JSON.stringify({
        transaction: record.payment_reference, amount: Math.round(Number(record.refund_amount_ngn) * 100),
        currency: 'NGN', reference: record.refund_reference,
        customer_note: 'Booking cancelled before pickup; NGN 1000 booking charge retained.',
      }) })
      refund = Array.isArray(created.data) ? created.data[0] : created.data
    } catch {
      // The request may have succeeded before the connection failed. Look up
      // this fixed reference before reporting a provider error or retrying.
      const existing = await paystack(`/refund?reference=${encodeURIComponent(record.refund_reference)}`, secret)
      refund = Array.isArray(existing.data) ? existing.data[0] : undefined
    }
    if (!refund || refund.reference !== record.refund_reference
      || Number(refund.transaction) !== Number(record.provider_transaction_id)
      || Number(refund.amount) !== Math.round(Number(record.refund_amount_ngn) * 100)
      || refund.currency !== 'NGN' || !allowed.has(String(refund.status))) throw new Error('Refund provider response did not match the booking')
    const status = refund.status === 'needs-attention' ? 'needs_attention' : refund.status
    const { error: finishError } = await admin.rpc('finish_paid_bike_refund', {
      p_reference: record.refund_reference, p_status: status, p_provider_refund_id: refund.id ?? null,
    })
    if (finishError) throw finishError
    return Response.json({ status, refund_amount_ngn: record.refund_amount_ngn, retained_ngn: 1000 })
  } catch (error) {
    console.error('Paid booking refund initiation failed', error)
    return Response.json({ error: 'Booking cancelled. Refund confirmation is pending; please retry or contact support.' }, { status: 503 })
  }
})
