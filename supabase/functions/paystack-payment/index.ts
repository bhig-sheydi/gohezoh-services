import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { createPaystackAccount, paymentMatches, verifyPaystackPayment } from '../_shared/paystack.ts'
import { isUuid } from '../_shared/uuid.ts'

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' }
const json = (value: unknown, status = 200) => Response.json(value, { status, headers: cors })

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  const secret = Deno.env.get('PAYSTACK_SECRET_KEY') ?? ''
  if (!secret) return json({ error: 'Paystack payment is not configured' }, 503)
  const url = Deno.env.get('SUPABASE_URL') ?? ''
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
  const admin = createClient(url, serviceKey, { auth: { persistSession: false } })
  const authorization = request.headers.get('Authorization')
  if (!authorization?.startsWith('Bearer ')) return json({ error: 'Sign in to pay' }, 401)
  const client = createClient(url, anonKey, { global: { headers: { Authorization: authorization } }, auth: { persistSession: false } })
  const { data: { user }, error: authError } = await client.auth.getUser()
  if (authError || !user?.email) return json({ error: 'Sign in with a verified email to pay' }, 401)
  let body: { action?: string; requestId?: string; bidId?: string }
  try { body = await request.json() } catch { return json({ error: 'Invalid payment request' }, 400) }
  if (!isUuid(body.requestId)) return json({ error: 'Invalid delivery request' }, 400)
  const requestId = body.requestId as string
  try {
    if (body.action === 'start') {
      if (!isUuid(body.bidId)) return json({ error: 'Choose a company offer' }, 400)
      const { error } = await client.rpc('select_customer_partner_bid', { p_request_id: requestId, p_bid_id: body.bidId })
      if (error) {
        const { data: existing } = await client.rpc('get_my_flutterwave_hold', { p_request_id: requestId })
        if (!existing || existing.bid_id !== body.bidId || ['expired', 'review'].includes(existing.status))
          return json({ error: error.message }, 400)
      }
    } else if (body.action !== 'status' && body.action !== 'check') return json({ error: 'Invalid payment action' }, 400)
    const { data: hold, error: holdError } = await client.rpc('get_my_flutterwave_hold', { p_request_id: requestId })
    if (holdError) return json({ error: holdError.message }, 403)
    if (!hold) return json({ status: 'management' })
    const { data: source, error: sourceError } = await admin.from('customer_payment_holds').select('provider').eq('request_id', requestId).maybeSingle()
    if (sourceError || source?.provider !== 'paystack') return json({ error: 'This booking belongs to the previous payment provider' }, 409)
    if (['paid', 'review'].includes(hold.status) || (hold.status === 'expired' && body.action !== 'check')) return json(hold)
    if (hold.status === 'initializing' && body.action !== 'check') {
      const { data: claimed, error: claimError } = await admin.rpc('claim_flutterwave_account_creation', { p_request_id: requestId, p_reference: hold.reference })
      if (claimError) throw claimError
      if (claimed) {
        const account = await createPaystackAccount({ email: user.email, amountNgn: Number(hold.amount_ngn),
          reference: hold.reference, expiresAt: new Date(Date.now() + 15 * 60_000).toISOString(), secret })
        const { error: activationError } = await admin.rpc('activate_paystack_hold', { p_request_id: requestId,
          p_reference: hold.reference, p_account_number: account.accountNumber, p_bank_name: account.bankName,
          p_provider_expires_at: account.providerExpiry, p_test_mode: secret.startsWith('sk_test_') })
        if (activationError) throw activationError
      }
    }
    if (body.action === 'check' && ['pending', 'expired'].includes(hold.status)) {
      const { data: claimed, error: claimError } = await admin.rpc('claim_flutterwave_provider_check', { p_request_id: requestId, p_reference: hold.reference })
      if (claimError) throw claimError
      if (claimed) {
        const payment = await verifyPaystackPayment(hold.reference, secret)
        if (paymentMatches(payment, hold.reference, Number(hold.amount_ngn))) {
          const { error } = await admin.rpc('settle_paystack_hold', { p_reference: hold.reference,
            p_transaction_id: Number(payment.id), p_amount_ngn: Number(payment.amount) / 100, p_currency: 'NGN' })
          if (error) throw error
        }
      }
    }
    const { data: latest, error: latestError } = await client.rpc('get_my_flutterwave_hold', { p_request_id: requestId })
    if (latestError) throw latestError
    return json(latest)
  } catch (error) {
    console.error('Paystack payment action failed', error)
    return json({ error: 'Payment is temporarily unavailable. Please check status before retrying.' }, 503)
  }
})
