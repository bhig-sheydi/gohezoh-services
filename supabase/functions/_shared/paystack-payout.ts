type Fetcher = typeof fetch
const api = 'https://api.paystack.co'
const headers = (secret: string) => ({ Authorization: `Bearer ${secret}`, 'Content-Type': 'application/json' })

export class PaystackApiError extends Error {
  constructor(message: string, readonly status: number) { super(message); this.name = 'PaystackApiError' }
}

// Paystack charges the merchant balance for the transfer amount plus these NGN
// charges. The recipient's bank receives `netNgn`; the withdrawer's earnings
// must be reserved for `totalDebitNgn` before the transfer is initiated.
export function paystackTransferCharges(netNgn: number) {
  if (!Number.isSafeInteger(netNgn) || netNgn < 50 || netNgn > 10_000_000)
    throw new Error('Paystack transfer amount must be between ₦50 and ₦10,000,000')
  const transferFeeNgn = netNgn <= 5_000 ? 10 : netNgn <= 50_000 ? 25 : 50
  const stampDutyNgn = netNgn >= 10_000 ? 50 : 0
  return { netNgn, transferFeeNgn, stampDutyNgn, totalDebitNgn: netNgn + transferFeeNgn + stampDutyNgn }
}

// Return the largest amount that can arrive in the bank after all charges are
// covered by the supplied earnings balance. Check each fee band separately:
// the charge jumps at ₦5,001, ₦10,000 and ₦50,001.
export function maxPaystackNetFromBalance(balanceNgn: number): number {
  if (!Number.isFinite(balanceNgn) || balanceNgn < 60) return 0
  const whole = Math.floor(balanceNgn)
  const bands = [
    { min: 50, max: 5_000, charge: 10 },
    { min: 5_001, max: 9_999, charge: 25 },
    { min: 10_000, max: 50_000, charge: 75 },
    { min: 50_001, max: 10_000_000, charge: 100 },
  ]
  let net = 0
  for (const band of bands) {
    const candidate = Math.min(band.max, whole - band.charge)
    if (candidate >= band.min) net = Math.max(net, candidate)
  }
  return net
}
async function call(path: string, secret: string, init: RequestInit = {}, fetcher: Fetcher = fetch): Promise<unknown> {
  if (!secret) throw new Error('Paystack payout is not configured')
  const response = await fetcher(`${api}${path}`, { ...init, headers: headers(secret), signal: AbortSignal.timeout(10000) })
  let body: { status?: boolean; message?: string; data?: unknown }
  try { body = await response.json() } catch { throw new PaystackApiError('Unreadable Paystack response', response.status) }
  if (!response.ok || body.status !== true) throw new PaystackApiError(body.message || 'Paystack request failed', response.status)
  return body.data
}
export type Bank = { code: string; name: string }
export async function availableBalanceNgn(secret: string, fetcher: Fetcher = fetch) {
  const response = await fetcher(`${api}/balance`, { headers: headers(secret), signal: AbortSignal.timeout(8000) })
  const body = await response.json() as { status?: boolean; data?: Array<{ currency?: string; balance?: number }> }
  if (!response.ok || body.status !== true || !Array.isArray(body.data)) throw new Error('Paystack balance is unavailable')
  const naira = body.data.find((row) => row.currency === 'NGN')
  const balance = Number(naira?.balance)
  if (!naira || !Number.isSafeInteger(balance) || balance < 0) throw new Error('Paystack NGN balance is unavailable')
  return balance / 100
}
export async function listBanks(secret: string, fetcher: Fetcher = fetch): Promise<Bank[]> {
  const banks = new Map<string, Bank>()
  for (let page = 1; page <= 10; page++) {
    const data = await call(`/bank?country=nigeria&perPage=100&page=${page}`, secret, {}, fetcher)
    if (!Array.isArray(data)) throw new Error('Paystack returned no bank list')
    for (const item of data) {
      const row = item as Record<string, unknown>
      const code = String(row.code ?? '')
      if (/^\d{3,8}$/.test(code) && typeof row.name === 'string' && row.name) banks.set(code, { code, name: row.name })
    }
    if (data.length < 100) break
  }
  if (!banks.size) throw new Error('Paystack returned no supported Nigerian banks')
  return [...banks.values()].sort((a, b) => a.name.localeCompare(b.name))
}
export async function resolveAccount(bankCode: string, accountNumber: string, secret: string, fetcher: Fetcher = fetch) {
  if (!/^\d{3,8}$/.test(bankCode) || !/^\d{10}$/.test(accountNumber)) throw new Error('Invalid Nigerian bank account')
  const data = await call(`/bank/resolve?account_number=${accountNumber}&bank_code=${bankCode}`, secret, {}, fetcher) as Record<string, unknown>
  if (String(data.account_number ?? '') !== accountNumber || !String(data.account_name ?? '').trim())
    throw new Error('Bank account verification did not match')
  return { accountNumber, accountName: String(data.account_name).trim() }
}
export async function createRecipient(bankCode: string, accountNumber: string, accountName: string, secret: string, fetcher: Fetcher = fetch) {
  const data = await call('/transferrecipient', secret, { method: 'POST', body: JSON.stringify({
    type: 'nuban', name: accountName, account_number: accountNumber, bank_code: bankCode, currency: 'NGN',
  }) }, fetcher) as Record<string, unknown>
  const details = data.details as Record<string, unknown> | undefined
  if (!/^RCP_[A-Za-z0-9]+$/.test(String(data.recipient_code ?? '')) || details?.account_number !== accountNumber || details?.bank_code !== bankCode)
    throw new Error('Paystack recipient does not match verified bank account')
  return String(data.recipient_code)
}
export type Transfer = { id: number; reference: string; status: string; amountNgn: number; currency: string;
  bankCode: string; accountNumber: string; feeChargedNgn: number | null }
function parseTransfer(value: unknown): Transfer {
  const row = value as Record<string, unknown>
  const recipient = row?.recipient as Record<string, unknown> | undefined
  const details = recipient?.details as Record<string, unknown> | undefined
  const transfer = { id: Number(row?.id), reference: String(row?.reference ?? ''), status: String(row?.status ?? '').toLowerCase(),
    amountNgn: Number(row?.amount) / 100, currency: String(row?.currency ?? ''), bankCode: String(details?.bank_code ?? ''),
    accountNumber: String(details?.account_number ?? ''),
    feeChargedNgn: Number.isSafeInteger(row?.fee_charged) && Number(row.fee_charged) >= 0
      ? Number(row.fee_charged) / 100 : null }
  if (!Number.isSafeInteger(transfer.id) || transfer.id <= 0 || !transfer.reference || !Number.isSafeInteger(transfer.amountNgn)
    || transfer.amountNgn <= 0 || transfer.currency !== 'NGN') throw new Error('Invalid Paystack transfer')
  return transfer
}
// Paystack's documented `fee_charged` can be zero in test mode and does not
// reliably include the separately billed stamp duty. A mismatch is an audit
// event; it must never increase the amount already accepted by the withdrawer.
export function warnPaystackFeeMismatch(transfer: Transfer, quotedFeeNgn: number): void {
  if (transfer.status !== 'success' || transfer.feeChargedNgn === null || transfer.feeChargedNgn === 0) return
  if (transfer.feeChargedNgn !== quotedFeeNgn)
    console.warn('Paystack transfer fee differs from withdrawal quote; reconcile the difference', {
      reference: transfer.reference, quotedFeeNgn, reportedFeeNgn: transfer.feeChargedNgn,
    })
}
export async function initiateTransfer(recipient: string, amountNgn: number, reference: string, secret: string, fetcher: Fetcher = fetch) {
  if (!/^RCP_[A-Za-z0-9]+$/.test(recipient) || !Number.isSafeInteger(amountNgn) || amountNgn < 50 || amountNgn > 10_000_000
    || !/^[a-z0-9_-]{16,50}$/.test(reference)) throw new Error('Invalid transfer request')
  const data = await call('/transfer', secret, { method: 'POST', body: JSON.stringify({
    source: 'balance', amount: amountNgn * 100, recipient, reference, currency: 'NGN', reason: 'Kwik-Parsel earnings',
  }) }, fetcher) as Record<string, unknown>
  if (data.reference !== reference || Number(data.amount) !== amountNgn * 100 || data.currency !== 'NGN')
    throw new Error('Paystack transfer response did not match the request')
  if (data.status === 'otp') throw new Error('Paystack transfer needs merchant OTP approval')
  return { id: Number(data.id), reference, status: String(data.status) }
}
export async function verifyTransfer(reference: string, secret: string, fetcher: Fetcher = fetch) {
  if (!/^[a-z0-9_-]{16,50}$/.test(reference)) throw new Error('Invalid transfer reference')
  return parseTransfer(await call(`/transfer/verify/${encodeURIComponent(reference)}`, secret, {}, fetcher))
}
export function transferMatches(transfer: Transfer, expected: { reference: string; amount_ngn: number; bank_code: string; account_number: string; provider_transfer_id?: number | null }) {
  return transfer.reference === expected.reference && transfer.amountNgn === Number(expected.amount_ngn)
    && transfer.currency === 'NGN' && transfer.bankCode === expected.bank_code && transfer.accountNumber === expected.account_number
    && (!expected.provider_transfer_id || transfer.id === Number(expected.provider_transfer_id))
}
