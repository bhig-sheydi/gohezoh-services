type Fetcher = typeof fetch

export class FlutterwaveApiError extends Error {
  constructor(message: string, readonly status: number) { super(message); this.name = 'FlutterwaveApiError' }
}

export type Bank = { code: string; name: string }
export type ResolvedAccount = { bankCode: string; accountNumber: string; accountName: string }
export type Transfer = { id: number; reference: string; status: string; amountNgn: number; currency: string; bankCode: string; accountNumber: string; requiresApproval: boolean }
export type ExpectedTransfer = { reference: string; provider_transfer_id?: number | null; amount_ngn: number;
  bank_code: string; account_number: string }

const api = 'https://api.flutterwave.com/v3'
const headers = (secret: string) => ({ Authorization: `Bearer ${secret}`, Accept: 'application/json', 'Content-Type': 'application/json' })
const bankCodeValid = (value: string) => /^\d{3,8}$/.test(value)
const accountValid = (value: string) => /^\d{10}$/.test(value)

async function readJson(response: Response): Promise<{ status?: string; data?: unknown; message?: string }> {
  let body: unknown
  try { body = await response.json() } catch { throw new Error('Flutterwave returned an unreadable response') }
  if (!body || typeof body !== 'object') throw new Error('Flutterwave returned an invalid response')
  const result = body as { status?: string; data?: unknown; message?: string }
  if (!response.ok || result.status !== 'success') throw new FlutterwaveApiError(result.message || 'Flutterwave request failed', response.status)
  return result
}

export async function listNigerianBanks(secret: string, fetcher: Fetcher = fetch): Promise<Bank[]> {
  if (!secret) throw new Error('Flutterwave payout is not configured')
  const response = await fetcher(`${api}/banks/NG`, { headers: headers(secret), signal: AbortSignal.timeout(8000) })
  const result = await readJson(response)
  if (!Array.isArray(result.data)) throw new Error('Flutterwave returned no bank list')
  const banks = result.data.flatMap((item): Bank[] => {
    if (!item || typeof item !== 'object') return []
    const row = item as Record<string, unknown>
    const code = String(row.code ?? '')
    const name = String(row.name ?? '').trim()
    return bankCodeValid(code) && name ? [{ code, name }] : []
  })
  if (!banks.length) throw new Error('Flutterwave returned no supported Nigerian banks')
  return banks.sort((a, b) => a.name.localeCompare(b.name))
}

export async function resolveNigerianAccount(bankCode: string, accountNumber: string, secret: string, fetcher: Fetcher = fetch): Promise<ResolvedAccount> {
  if (!bankCodeValid(bankCode) || !accountValid(accountNumber) || !secret) throw new Error('Choose a bank and enter a ten-digit account number')
  const response = await fetcher(`${api}/accounts/resolve`, { method: 'POST', headers: headers(secret),
    body: JSON.stringify({ account_bank: bankCode, account_number: accountNumber }), signal: AbortSignal.timeout(8000) })
  const result = await readJson(response)
  if (!result.data || typeof result.data !== 'object') throw new Error('Flutterwave could not verify this account')
  const data = result.data as Record<string, unknown>
  const resolvedNumber = String(data.account_number ?? '')
  const accountName = String(data.account_name ?? '').trim()
  if (resolvedNumber !== accountNumber || !accountName || accountName.length > 160) throw new Error('Bank account verification did not match the number entered')
  return { bankCode, accountNumber, accountName }
}

function parseTransfer(value: unknown): Transfer {
  if (!value || typeof value !== 'object') throw new Error('Flutterwave returned an invalid transfer')
  const row = value as Record<string, unknown>
  const id = Number(row.id)
  const amountNgn = Number(row.amount)
  const reference = String(row.reference ?? '')
  const status = String(row.status ?? '').toUpperCase()
  const currency = String(row.currency ?? '')
  const bankCode = String(row.bank_code ?? row.account_bank ?? '')
  const accountNumber = String(row.account_number ?? '')
  if (!Number.isSafeInteger(id) || id <= 0 || !Number.isSafeInteger(amountNgn) || amountNgn <= 0
    || !reference || !['NEW', 'PENDING', 'SUCCESSFUL', 'FAILED'].includes(status) || currency !== 'NGN'
    || !bankCodeValid(bankCode)) throw new Error('Flutterwave returned an invalid transfer')
  return { id, reference, status, amountNgn, currency, bankCode, accountNumber,
    requiresApproval: Number(row.requires_approval ?? 0) === 1 && Number(row.is_approved ?? 0) !== 1 }
}

export async function createNigerianTransfer(input: { bankCode: string; accountNumber: string; accountName: string; amountNgn: number; reference: string; secret: string }, fetcher: Fetcher = fetch): Promise<Transfer> {
  if (!bankCodeValid(input.bankCode) || !accountValid(input.accountNumber) || !input.accountName.trim()
    || !Number.isSafeInteger(input.amountNgn) || input.amountNgn <= 0 || !/^[A-Za-z0-9-]{8,80}$/.test(input.reference)
    || !input.secret) throw new Error('Invalid payout transfer details')
  const response = await fetcher(`${api}/transfers`, { method: 'POST', headers: headers(input.secret),
    body: JSON.stringify({ account_bank: input.bankCode, account_number: input.accountNumber,
      beneficiary_name: input.accountName, amount: input.amountNgn, currency: 'NGN', debit_currency: 'NGN',
      reference: input.reference, narration: 'Kwik-Parsel delivery earnings' }), signal: AbortSignal.timeout(10000) })
  const result = await readJson(response)
  const transfer = parseTransfer(result.data)
  if (transfer.amountNgn !== input.amountNgn || transfer.bankCode !== input.bankCode
    || transfer.accountNumber !== input.accountNumber
    || (transfer.reference !== input.reference && !transfer.reference.startsWith(`${input.reference}_`))) {
    throw new Error('Flutterwave transfer response did not match the requested payout')
  }
  return transfer
}

export async function getNigerianTransfer(id: number, secret: string, fetcher: Fetcher = fetch): Promise<Transfer> {
  if (!Number.isSafeInteger(id) || id <= 0 || !secret) throw new Error('Invalid transfer lookup')
  const response = await fetcher(`${api}/transfers/${id}`, { headers: headers(secret), signal: AbortSignal.timeout(8000) })
  return parseTransfer((await readJson(response)).data)
}

export async function findNigerianTransferByReference(reference: string, secret: string, fetcher: Fetcher = fetch): Promise<Transfer | null> {
  if (!/^[A-Za-z0-9-]{8,80}$/.test(reference) || !secret) throw new Error('Invalid transfer lookup')
  const response = await fetcher(`${api}/transfers?reference=${encodeURIComponent(reference)}`, { headers: headers(secret), signal: AbortSignal.timeout(8000) })
  const result = await readJson(response)
  const items = Array.isArray(result.data) ? result.data : []
  const exact = items.find((item) => item && typeof item === 'object' && (() => {
    const providerReference = String((item as Record<string, unknown>).reference ?? '')
    return providerReference === reference || providerReference.startsWith(`${reference}_`)
  })())
  return exact ? parseTransfer(exact) : null
}

export function transferMatchesReservation(transfer: Transfer, expected: ExpectedTransfer) {
  return transfer.currency === 'NGN' && transfer.amountNgn === Number(expected.amount_ngn)
    && transfer.bankCode === expected.bank_code && transfer.accountNumber === expected.account_number
    && (transfer.reference === expected.reference || transfer.reference.startsWith(`${expected.reference}_`))
    && (!expected.provider_transfer_id || transfer.id === Number(expected.provider_transfer_id))
}
