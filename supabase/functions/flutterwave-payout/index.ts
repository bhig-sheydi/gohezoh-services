import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { createNigerianTransfer, findNigerianTransferByReference, FlutterwaveApiError, getNigerianTransfer,
  listNigerianBanks, resolveNigerianAccount, transferMatchesReservation, type Bank } from '../_shared/flutterwave-payout.ts'

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS' }
const json = (body: unknown, status = 200) => Response.json(body, { status, headers: cors })
const uuid = (value: unknown): value is string => typeof value === 'string'
  && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)
const bankCode = (value: unknown): value is string => typeof value === 'string' && /^\d{3,8}$/.test(value)
const accountNumber = (value: unknown): value is string => typeof value === 'string' && /^\d{10}$/.test(value)
type Attempt = { status: string; withdrawal_id: string; reference: string; provider_transfer_id?: number | null;
  amount_ngn: number; currency: string; bank_code: string; account_number: string; account_name: string }
type Body = { action?: string; partnerId?: string; bankCode?: string; accountNumber?: string; accountName?: string;
  amountNgn?: number; idempotencyKey?: string; withdrawalId?: string }

let bankCache: { banks: Bank[]; expires: number } | null = null
async function banks(secret: string) {
  if (bankCache && bankCache.expires > Date.now()) return bankCache.banks
  const value = await listNigerianBanks(secret)
  bankCache = { banks: value, expires: Date.now() + 6 * 60 * 60 * 1000 }
  return value
}

async function reconcile(admin: ReturnType<typeof createClient>, withdrawalId: string, secret: string) {
  const { data: raw, error } = await admin.rpc('get_partner_withdrawal_transfer_attempt', { p_withdrawal_id: withdrawalId })
  if (error) throw error
  const attempt = raw as Attempt
  if (['successful', 'failed', 'manual'].includes(attempt.status)) return attempt.status
  let transfer: Transfer | null = null
  if (attempt.provider_transfer_id) transfer = await getNigerianTransfer(Number(attempt.provider_transfer_id), secret)
  else transfer = await findNigerianTransferByReference(attempt.reference, secret)
  if (!transfer) return attempt.status
  if (!transferMatchesReservation(transfer, attempt)) throw new Error('Flutterwave transfer does not match the reserved payout')
  if (transfer.status === 'SUCCESSFUL' || transfer.status === 'FAILED') {
    const { data, error: finishError } = await admin.rpc('finish_partner_withdrawal_transfer', {
      p_withdrawal_id: withdrawalId, p_provider_transfer_id: transfer.id,
      p_reference: attempt.reference, p_provider_reference: transfer.reference,
      p_status: transfer.status, p_amount_ngn: transfer.amountNgn,
      p_currency: transfer.currency, p_bank_code: transfer.bankCode, p_account_number: transfer.accountNumber,
    })
    if (finishError) throw finishError
    return String(data.status)
  }
  const { error: recordError } = await admin.rpc('record_partner_withdrawal_transfer_attempt', {
    p_withdrawal_id: withdrawalId, p_provider_transfer_id: transfer.id, p_status: 'queued',
    p_provider_reference: transfer.reference,
  })
  if (recordError) throw recordError
  return 'queued'
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  const url = Deno.env.get('SUPABASE_URL') ?? ''
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
  const secret = Deno.env.get('FLUTTERWAVE_SECRET_KEY') ?? ''
  const verificationSecret = Deno.env.get('FLUTTERWAVE_ACCOUNT_VERIFY_SECRET_KEY') || secret
  if (!url || !anonKey || !serviceKey || !secret) return json({ error: 'Automatic payouts are not configured' }, 503)
  const testMode = secret.startsWith('FLWSECK_TEST-')
  const verificationTestMode = verificationSecret.startsWith('FLWSECK_TEST-')
  const authorization = request.headers.get('Authorization')
  if (!authorization?.startsWith('Bearer ')) return json({ error: 'Sign in to manage company payouts' }, 401)
  const userClient = createClient(url, anonKey, { global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false } })
  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data: { user }, error: authError } = await userClient.auth.getUser()
  if (authError || !user) return json({ error: 'Sign in again to manage company payouts' }, 401)
  let body: Body
  try { body = await request.json() } catch { return json({ error: 'Invalid payout request' }, 400) }
  if (!uuid(body.partnerId)) return json({ error: 'Select your company' }, 400)
  const partnerId = body.partnerId
  const [{ data: membership, error: memberError }, { data: partner, error: partnerError }] = await Promise.all([
    admin.from('partner_users').select('partner_id').eq('partner_id', partnerId).eq('user_id', user.id)
      .eq('membership_role', 'manager').maybeSingle(),
    admin.from('logistics_partners').select('id,status').eq('id', partnerId).maybeSingle(),
  ])
  if (memberError || partnerError || !membership || partner?.status !== 'active')
    return json({ error: 'An active company manager is required' }, 403)

  try {
    if (body.action === 'banks') {
      const listed = await banks(verificationSecret)
      return json({ banks: verificationTestMode ? listed.filter((bank) => bank.code === '044') : listed,
        testMode, verificationTestMode })
    }
    if (body.action === 'account') {
      const { data, error } = await userClient.rpc('get_my_partner_payout_account', { p_partner_id: partnerId })
      if (error) throw error
      return json({ account: data?.verified ? {
        bankName: data.bank_name, accountName: data.account_name, accountLast4: data.account_last4,
        verifiedAt: data.verified_at,
      } : null, testMode, verificationTestMode })
    }
    if (body.action === 'resolve' || body.action === 'save-account') {
      if (!bankCode(body.bankCode) || !accountNumber(body.accountNumber))
        return json({ error: 'Choose a bank and enter a ten-digit account number' }, 400)
      const listed = (await banks(verificationSecret)).find((bank) => bank.code === body.bankCode)
      if (!listed) return json({ error: 'Choose a supported Nigerian bank' }, 400)
      const { error: limitError } = await admin.rpc('authorize_partner_bank_resolve', {
        p_partner_id: partnerId, p_actor_id: user.id,
      })
      if (limitError) return json({ error: limitError.message }, 429)
      const resolved = await resolveNigerianAccount(body.bankCode, body.accountNumber, verificationSecret)
      if (body.action === 'resolve') return json({ bankCode: listed.code, bankName: listed.name,
        accountNumber: resolved.accountNumber, accountName: resolved.accountName, testMode, verificationTestMode })
      if (typeof body.accountName !== 'string' || body.accountName.trim().toLocaleLowerCase() !== resolved.accountName.toLocaleLowerCase())
        return json({ error: 'The account name changed. Verify the bank details again.' }, 409)
      const { data, error } = await admin.rpc('save_verified_partner_payout_account', {
        p_partner_id: partnerId, p_actor_id: user.id, p_bank_code: listed.code,
        p_bank_name: listed.name, p_account_number: resolved.accountNumber, p_account_name: resolved.accountName,
      })
      if (error) throw error
      return json({ account: { bankName: data.bank_name, accountName: data.account_name,
        accountLast4: data.account_last4, verifiedAt: new Date().toISOString() }, testMode, verificationTestMode })
    }
    if (body.action === 'withdraw') {
      if (testMode && !verificationTestMode)
        return json({ error: 'Bank verification is available, but withdrawals are disabled until live transfers are configured.' }, 503)
      if (!testMode && Deno.env.get('FLUTTERWAVE_LIVE_PAYOUTS_ENABLED') !== 'true')
        return json({ error: 'Live withdrawals are not enabled yet. Contact support.' }, 503)
      if (!Number.isSafeInteger(body.amountNgn) || Number(body.amountNgn) <= 0 || !uuid(body.idempotencyKey))
        return json({ error: 'Enter a valid whole-naira withdrawal amount' }, 400)
      const { data: reserved, error: reserveError } = await userClient.rpc('request_partner_withdrawal', {
        p_partner_id: partnerId, p_amount_ngn: body.amountNgn, p_idempotency_key: body.idempotencyKey,
      })
      if (reserveError) return json({ error: reserveError.message }, 400)
      const withdrawalId = String(reserved.withdrawal_id)
      const { data: claim, error: claimError } = await admin.rpc('claim_partner_withdrawal_transfer', { p_withdrawal_id: withdrawalId })
      if (claimError) throw claimError
      if (claim.account_number) {
        let transferId: number | null = null
        let providerReference: string | null = null
        try {
          const transfer = await createNigerianTransfer({ bankCode: claim.bank_code, accountNumber: claim.account_number,
            accountName: claim.account_name, amountNgn: Number(claim.amount_ngn), reference: claim.reference, secret })
          transferId = transfer.id
          providerReference = transfer.reference
          const { error: recordError } = await admin.rpc('record_partner_withdrawal_transfer_attempt', {
            p_withdrawal_id: withdrawalId, p_provider_transfer_id: transfer.id, p_status: 'queued',
            p_provider_reference: transfer.reference,
          })
          if (recordError) throw recordError
        } catch (error) {
          console.error('Flutterwave payout initiation outcome is uncertain', error)
          const { error: unknownError } = await admin.rpc('record_partner_withdrawal_transfer_attempt', {
            p_withdrawal_id: withdrawalId, p_provider_transfer_id: transferId, p_status: 'unknown',
            p_provider_reference: providerReference,
          })
          if (unknownError) console.error('Could not record uncertain Flutterwave payout outcome', unknownError)
          return json({ withdrawalId, status: 'unknown', amountNgn: Number(reserved.amount_ngn), testMode })
        }
      }
      let status = String(claim.status)
      try { status = await reconcile(admin, withdrawalId, secret) } catch (error) {
        console.error('Flutterwave payout verification unavailable', error)
        status = claim.account_number ? 'queued' : status
      }
      return json({ withdrawalId, status, amountNgn: Number(reserved.amount_ngn), testMode })
    }
    if (body.action === 'status') {
      if (!uuid(body.withdrawalId)) return json({ error: 'Choose a withdrawal to check' }, 400)
      const { data: mine, error: listError } = await admin.from('partner_withdrawals').select('id,status,amount_ngn')
        .eq('id', body.withdrawalId).eq('partner_id', partnerId).maybeSingle()
      if (listError || !mine)
        return json({ error: 'Withdrawal not found for this company' }, 404)
      let status: string
      try { status = await reconcile(admin, body.withdrawalId, secret) }
      catch (error) { console.error('Flutterwave transfer status unavailable', error); status = mine.status ?? 'unknown' }
      return json({ withdrawalId: body.withdrawalId, status, amountNgn: Number(mine.amount_ngn), testMode })
    }
    return json({ error: 'Invalid payout action' }, 400)
  } catch (error) {
    console.error('Flutterwave payout action failed', error)
    if ((body.action === 'resolve' || body.action === 'save-account') && verificationTestMode && error instanceof FlutterwaveApiError && [400, 404, 422].includes(error.status))
      return json({ error: 'Flutterwave test mode accepts sample bank accounts only. Select Access Bank and use a test account number from 0690000031 to 0690000041. Real bank accounts can be verified in live mode.' }, 422)
    return json({ error: body.action === 'resolve' || body.action === 'save-account'
      ? 'Bank verification is unavailable. Check the details or try again later.'
      : 'Payout is temporarily unavailable. Check the current status before retrying.' }, 503)
  }
})
