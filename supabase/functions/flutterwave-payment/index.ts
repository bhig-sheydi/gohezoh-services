import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { createDynamicAccount, verifiedBankTransfer, verifyFlutterwaveReference, verifyFlutterwaveTransaction } from '../_shared/flutterwave.ts'
import { getNigerianTransfer, transferMatchesReservation } from '../_shared/flutterwave-payout.ts'

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS' }
const json = (body: unknown, status = 200) => Response.json(body, { status, headers: cors })
const uuid = (value: unknown) => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  const url = Deno.env.get('SUPABASE_URL') ?? ''
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
  const secret = Deno.env.get('FLUTTERWAVE_SECRET_KEY') ?? ''
  if (!secret) return json({ error: 'Flutterwave payment is not configured' }, 503)
  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })

  // Webhooks remain disabled until the same secret hash is configured in both
  // Flutterwave and Supabase. Client polling uses the verified API as backup.
  const webhookSignature = request.headers.get('verif-hash')
  if (webhookSignature !== null) {
    const expected = Deno.env.get('FLUTTERWAVE_WEBHOOK_SECRET_HASH')
    if (!expected || webhookSignature !== expected) return json({ error: 'Invalid webhook signature' }, 401)
    try {
      const event = await request.json() as { event?: string; data?: { id?: number; tx_ref?: string } }
      if (event.event === 'transfer.completed' && Number.isSafeInteger(event.data?.id)) {
        const transfer = await getNigerianTransfer(Number(event.data?.id), secret)
        const merchantReference = /^(KWP-PAYOUT-[a-f0-9]{32})(?:_|$)/i.exec(transfer.reference)?.[1]
        if (!merchantReference) return json({ received: true })
        const { data: withdrawal, error: lookupError } = await admin.from('partner_withdrawals')
          .select('id').eq('transfer_reference', merchantReference).maybeSingle()
        if (lookupError) throw lookupError
        if (!withdrawal) return json({ received: true })
        const { data: expected, error: expectedError } = await admin.rpc('get_partner_withdrawal_transfer_attempt', {
          p_withdrawal_id: withdrawal.id,
        })
        if (expectedError) throw expectedError
        if (!transferMatchesReservation(transfer, expected)) throw new Error('Transfer did not match reserved payout')
        if (transfer.status === 'SUCCESSFUL' || transfer.status === 'FAILED') {
          const { error: finishError } = await admin.rpc('finish_partner_withdrawal_transfer', {
            p_withdrawal_id: withdrawal.id, p_provider_transfer_id: transfer.id,
            p_reference: expected.reference, p_provider_reference: transfer.reference,
            p_status: transfer.status, p_amount_ngn: transfer.amountNgn, p_currency: transfer.currency,
            p_bank_code: transfer.bankCode, p_account_number: transfer.accountNumber,
          })
          if (finishError) throw finishError
        } else {
          const { error: recordError } = await admin.rpc('record_partner_withdrawal_transfer_attempt', {
            p_withdrawal_id: withdrawal.id, p_provider_transfer_id: transfer.id,
            p_status: 'queued', p_provider_reference: transfer.reference,
          })
          if (recordError) throw recordError
        }
        return json({ received: true })
      }
      if (event.event !== 'charge.completed' || !Number.isSafeInteger(event.data?.id)) return json({ received: true })
      const tx = await verifyFlutterwaveTransaction(Number(event.data?.id), secret)
      const reference = String(tx.tx_ref ?? '')
      const { data: hold } = await admin.from('customer_payment_holds').select('amount_ngn').eq('reference', reference).maybeSingle()
      if (!hold || !verifiedBankTransfer(tx, reference, Number(hold.amount_ngn))) return json({ received: true })
      const { error } = await admin.rpc('settle_flutterwave_hold', { p_reference: reference,
        p_transaction_id: Number(tx.id), p_amount_ngn: Number(tx.amount), p_currency: 'NGN' })
      if (error) throw error
      return json({ received: true })
    } catch (error) {
      console.error('Flutterwave webhook verification failed', error)
      return json({ error: 'Payment verification unavailable' }, 503)
    }
  }

  const authorization = request.headers.get('Authorization')
  if (!authorization?.startsWith('Bearer ')) return json({ error: 'Sign in to manage this payment' }, 401)
  const userClient = createClient(url, anonKey, { global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false } })
  const { data: { user }, error: authError } = await userClient.auth.getUser()
  if (authError || !user?.email) return json({ error: 'Sign in with a verified email to pay' }, 401)
  let body: { action?: string; requestId?: string; bidId?: string }
  try { body = await request.json() } catch { return json({ error: 'Invalid payment request' }, 400) }
  if (!uuid(body.requestId)) return json({ error: 'Invalid delivery request' }, 400)
  const requestId = body.requestId as string

  try {
    if (body.action === 'start') {
      if (!uuid(body.bidId)) return json({ error: 'Choose a company bid' }, 400)
      const { error: selectionError } = await userClient.rpc('select_customer_partner_bid', {
        p_request_id: requestId, p_bid_id: body.bidId })
      if (selectionError) {
        const { data: existing } = await userClient.rpc('get_my_flutterwave_hold', { p_request_id: requestId })
        if (!existing || existing.bid_id !== body.bidId || existing.status === 'expired' || existing.status === 'review') return json({ error: selectionError.message }, 400)
      }
    } else if (body.action !== 'status' && body.action !== 'check') return json({ error: 'Invalid payment action' }, 400)

    const { data: hold, error: holdError } = await userClient.rpc('get_my_flutterwave_hold', { p_request_id: requestId })
    if (holdError) return json({ error: holdError.message }, 403)
    if (!hold) return json({ status: 'management' })
    if ((body.action !== 'check' && hold.status === 'expired') || hold.status === 'review' || hold.status === 'paid') return json(hold)

    if ((body.action === 'start' || body.action === 'status') && hold.status === 'initializing') {
      const account = await createDynamicAccount({ email: user.email, amountNgn: Number(hold.amount_ngn),
        reference: String(hold.reference), secretKey: secret })
      const { error: activationError } = await admin.rpc('activate_flutterwave_hold', { p_request_id: requestId,
        p_reference: hold.reference, p_account_number: account.accountNumber, p_bank_name: account.bankName })
      if (activationError) throw activationError
    }
    if (body.action === 'check' && ['pending', 'expired'].includes(hold.status)) {
      const tx = await verifyFlutterwaveReference(String(hold.reference), secret)
      if (tx && verifiedBankTransfer(tx, String(hold.reference), Number(hold.amount_ngn))) {
        const { error: settlementError } = await admin.rpc('settle_flutterwave_hold', {
          p_reference: hold.reference, p_transaction_id: Number(tx.id),
          p_amount_ngn: Number(tx.amount), p_currency: 'NGN' })
        if (settlementError) throw settlementError
      }
    }
    const { data: latest, error: latestError } = await userClient.rpc('get_my_flutterwave_hold', { p_request_id: requestId })
    if (latestError) throw latestError
    return json(latest)
  } catch (error) {
    console.error('Flutterwave payment action failed', error)
    return json({ error: 'Payment is temporarily unavailable. Your account has not been confirmed; please try again.' }, 503)
  }
})
