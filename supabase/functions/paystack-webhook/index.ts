import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { paymentMatches, verifyPaystackPayment } from '../_shared/paystack.ts'
import { transferMatches, verifyTransfer } from '../_shared/paystack-payout.ts'

Deno.serve(async (request) => {
  if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 })
  const secret = Deno.env.get('PAYSTACK_SECRET_KEY') ?? ''
  if (!secret) return new Response('Not configured', { status: 503 })
  const raw = await request.text()
  const signature = request.headers.get('x-paystack-signature') ?? ''
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-512' }, false, ['verify'])
  if (!/^[a-f0-9]{128}$/i.test(signature)) return new Response('Invalid signature', { status: 401 })
  const signed = Uint8Array.from(signature.match(/../g)!, (pair) => Number.parseInt(pair, 16))
  if (!await crypto.subtle.verify('HMAC', key, signed, new TextEncoder().encode(raw))) return new Response('Invalid signature', { status: 401 })
  let event: { event?: string; data?: { reference?: string } }
  try { event = JSON.parse(raw) } catch { return new Response('Invalid event', { status: 400 }) }
  if (!['charge.success', 'transfer.success', 'transfer.failed', 'transfer.reversed'].includes(event.event ?? '') || !event.data?.reference)
    return Response.json({ received: true })
  try {
    const admin = createClient(Deno.env.get('SUPABASE_URL') ?? '', Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '', { auth: { persistSession: false } })
    if (event.event?.startsWith('transfer.')) {
      const reference = event.data.reference
      const transfer = await verifyTransfer(reference, secret)
      const status = transfer.status === 'success' ? 'SUCCESSFUL' : ['failed', 'reversed'].includes(transfer.status) ? 'FAILED' : null
      if (!status) return Response.json({ received: true })
      if (reference.startsWith('kwp-referral-')) {
        const { data: withdrawal, error: lookupError } = await admin.from('customer_referral_withdrawals').select('id').eq('transfer_reference', reference).maybeSingle()
        if (lookupError) throw lookupError
        if (!withdrawal) return Response.json({ received: true })
        const { data: expected, error: expectedError } = await admin.rpc('claim_referral_transfer', { p_id: withdrawal.id })
        if (expectedError) throw expectedError
        if (!transferMatches(transfer, { reference, amount_ngn: Number(expected.amount_ngn), bank_code: expected.bank_code,
          account_number: expected.account_number })) throw new Error('Referral transfer mismatch')
        const { error } = await admin.rpc('finish_referral_transfer', { p_id: withdrawal.id, p_provider_id: transfer.id,
          p_reference: reference, p_status: status === 'SUCCESSFUL' ? 'successful' : 'failed', p_amount_ngn: expected.amount_ngn,
          p_bank_code: expected.bank_code, p_account_number: expected.account_number })
        if (error) throw error
      } else if (reference.startsWith('kwp-payout-')) {
        const { data: withdrawal, error: lookupError } = await admin.from('partner_withdrawals').select('id,provider').eq('transfer_reference', reference.toUpperCase()).maybeSingle()
        if (lookupError) throw lookupError
        if (!withdrawal || withdrawal.provider !== 'paystack') return Response.json({ received: true })
        const { data: expected, error: expectedError } = await admin.rpc('get_partner_withdrawal_transfer_attempt', { p_withdrawal_id: withdrawal.id })
        if (expectedError) throw expectedError
        if (!transferMatches(transfer, { ...expected, reference })) throw new Error('Company transfer mismatch')
        const { error } = await admin.rpc('finish_partner_withdrawal_transfer', { p_withdrawal_id: withdrawal.id,
          p_provider_transfer_id: transfer.id, p_reference: expected.reference, p_provider_reference: reference,
          p_status: status, p_amount_ngn: transfer.amountNgn, p_currency: transfer.currency,
          p_bank_code: transfer.bankCode, p_account_number: transfer.accountNumber })
        if (error) throw error
      }
      return Response.json({ received: true })
    }
    const { data: hold, error } = await admin.from('customer_payment_holds').select('amount_ngn,provider').eq('reference', event.data.reference).maybeSingle()
    if (error) throw error
    if (!hold || hold.provider !== 'paystack') return Response.json({ received: true })
    const payment = await verifyPaystackPayment(event.data.reference, secret)
    if (!paymentMatches(payment, event.data.reference, Number(hold.amount_ngn))) return Response.json({ received: true })
    const { error: settleError } = await admin.rpc('settle_paystack_hold', { p_reference: event.data.reference,
      p_transaction_id: Number(payment.id), p_amount_ngn: Number(payment.amount) / 100, p_currency: 'NGN' })
    if (settleError) throw settleError
    return Response.json({ received: true })
  } catch (error) {
    console.error('Paystack webhook processing failed', error)
    return new Response('Verification unavailable', { status: 503 })
  }
})
