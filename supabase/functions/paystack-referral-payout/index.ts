import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { availableBalanceNgn, createRecipient, initiateTransfer, listBanks, resolveAccount, transferMatches, verifyTransfer } from '../_shared/paystack-payout.ts'

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' }
const json = (value: unknown, status = 200) => Response.json(value, { status, headers: cors })
const uuid = (value: unknown) => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  const secret = Deno.env.get('PAYSTACK_SECRET_KEY') ?? ''
  if (!secret) return json({ error: 'Paystack payouts are not configured' }, 503)
  const url = Deno.env.get('SUPABASE_URL') ?? ''
  const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '', { auth: { persistSession: false } })
  const auth = request.headers.get('Authorization')
  if (!auth?.startsWith('Bearer ')) return json({ error: 'Sign in to withdraw' }, 401)
  const client = createClient(url, Deno.env.get('SUPABASE_ANON_KEY') ?? '', { global: { headers: { Authorization: auth } }, auth: { persistSession: false } })
  const { data: { user }, error: authError } = await client.auth.getUser()
  if (authError || !user) return json({ error: 'Sign in to withdraw' }, 401)
  let body: { action?: string; bankCode?: string; accountNumber?: string; accountName?: string; amountNgn?: number; idempotencyKey?: string; withdrawalId?: string }
  try { body = await request.json() } catch { return json({ error: 'Invalid request' }, 400) }
  try {
    if (body.action === 'banks') return json({ banks: await listBanks(secret), testMode: secret.startsWith('sk_test_') })
    if (body.action === 'account') {
      const { data, error } = await client.rpc('my_referral_payout_state')
      if (error) return json({ error: error.message }, 403)
      return json({ ...data, testMode: secret.startsWith('sk_test_') })
    }
    if (body.action === 'resolve' || body.action === 'save-account') {
      if (!/^\d{3,8}$/.test(body.bankCode ?? '') || !/^\d{10}$/.test(body.accountNumber ?? '')) return json({ error: 'Choose a bank and enter a ten-digit account number' }, 400)
      const { error: limitError } = await admin.rpc('authorize_referral_bank_check', { p_user: user.id })
      if (limitError) return json({ error: limitError.message }, 429)
      const bank = (await listBanks(secret)).find((row) => row.code === body.bankCode)
      if (!bank) return json({ error: 'Choose a supported Nigerian bank' }, 400)
      const resolved = await resolveAccount(body.bankCode!, body.accountNumber!, secret)
      if (body.action === 'resolve') return json({ bankCode: bank.code, bankName: bank.name, ...resolved })
      if (body.accountName?.trim().toLowerCase() !== resolved.accountName.toLowerCase()) return json({ error: 'Verify this account again' }, 409)
      const { error } = await admin.rpc('save_referral_payout_account', { p_user: user.id, p_bank_code: bank.code,
        p_bank_name: bank.name, p_account_number: resolved.accountNumber, p_account_name: resolved.accountName })
      if (error) return json({ error: error.message }, 400)
      return json({ account: { bankName: bank.name, accountName: resolved.accountName, accountLast4: resolved.accountNumber.slice(-4) } })
    }
    if (body.action === 'withdraw') {
      if (!secret.startsWith('sk_test_') && Deno.env.get('PAYSTACK_LIVE_PAYOUTS_ENABLED') !== 'true')
        return json({ error: 'Live withdrawals are not enabled yet' }, 503)
      if (!Number.isSafeInteger(body.amountNgn) || Number(body.amountNgn) <= 0 || !uuid(body.idempotencyKey))
        return json({ error: 'Invalid withdrawal amount' }, 400)
      const { data: existing, error: lookupError } = await admin.from('customer_referral_withdrawals').select('id')
        .eq('user_id', user.id).eq('idempotency_key', body.idempotencyKey).maybeSingle()
      if (lookupError) throw lookupError
      if (!existing && await availableBalanceNgn(secret) < Number(body.amountNgn))
        return json({ error: 'Withdrawal is waiting for funds to reach the Paystack payout balance' }, 409)
      const { data: reserved, error: reserveError } = await client.rpc('request_referral_withdrawal', {
        p_amount_ngn: body.amountNgn, p_idempotency_key: body.idempotencyKey })
      if (reserveError) return json({ error: reserveError.message }, 400)
      const id = reserved.withdrawal_id as string
      const { data: claim, error: claimError } = await admin.rpc('claim_referral_transfer', { p_id: id })
      if (claimError) throw claimError
      if (claim.status === 'reserved') {
        try {
          const recipient = await createRecipient(claim.bank_code, claim.account_number, claim.account_name, secret)
          const transfer = await initiateTransfer(recipient, Number(claim.amount_ngn), claim.reference, secret)
          const { error } = await admin.rpc('finish_referral_transfer', { p_id: id, p_provider_id: transfer.id,
            p_reference: claim.reference, p_status: 'queued', p_amount_ngn: claim.amount_ngn,
            p_bank_code: claim.bank_code, p_account_number: claim.account_number })
          if (error) throw error
        } catch (error) {
          console.error('Uncertain Paystack referral transfer initiation', error)
          const { error: unknownError } = await admin.rpc('finish_referral_transfer', { p_id: id, p_provider_id: null,
            p_reference: claim.reference, p_status: 'unknown', p_amount_ngn: claim.amount_ngn,
            p_bank_code: claim.bank_code, p_account_number: claim.account_number })
          if (unknownError) throw unknownError
        }
      }
      return json({ withdrawalId: id, status: claim.status === 'reserved' ? 'queued' : claim.status, testMode: secret.startsWith('sk_test_') })
    }
    if (body.action === 'status') {
      if (!uuid(body.withdrawalId)) return json({ error: 'Invalid withdrawal' }, 400)
      const { data: mine, error: listError } = await client.rpc('my_referral_payout_state')
      if (listError || !mine?.withdrawals?.some((row: { id: string }) => row.id === body.withdrawalId)) return json({ error: 'Withdrawal not found' }, 404)
      const { data: claim, error: claimError } = await admin.rpc('claim_referral_transfer', { p_id: body.withdrawalId })
      if (claimError) throw claimError
      if (['successful', 'failed', 'reserved'].includes(claim.status)) return json({ status: claim.status })
      const verified = await verifyTransfer(claim.reference, secret)
      if (!transferMatches(verified, { reference: claim.reference, amount_ngn: Number(claim.amount_ngn),
        bank_code: claim.bank_code, account_number: claim.account_number })) throw new Error('Paystack transfer mismatch')
      const terminal = verified.status === 'success' ? 'successful' : ['failed', 'reversed'].includes(verified.status) ? 'failed' : 'queued'
      const { error } = await admin.rpc('finish_referral_transfer', { p_id: body.withdrawalId, p_provider_id: verified.id,
        p_reference: claim.reference, p_status: terminal, p_amount_ngn: claim.amount_ngn,
        p_bank_code: claim.bank_code, p_account_number: claim.account_number })
      if (error) throw error
      return json({ status: terminal })
    }
    return json({ error: 'Invalid action' }, 400)
  } catch (error) {
    console.error('Paystack referral payout failed', error)
    return json({ error: 'Payout is temporarily unavailable. Check its status before retrying.' }, 503)
  }
})
