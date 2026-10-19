type Fetcher = typeof fetch

export type DynamicAccount = {
  reference: string
  accountNumber: string
  bankName: string
  providerExpiry: string
}

type CreateAccountInput = {
  email: string
  amountNgn: number
  reference: string
  secretKey: string
  fetcher?: Fetcher
}

// This only requests a sandbox/live account. Callers must separately persist a
// payment hold and verify successful transfers before dispatching a rider.
export async function createDynamicAccount({ email, amountNgn, reference, secretKey, fetcher = fetch }: CreateAccountInput): Promise<DynamicAccount> {
  if (!secretKey || !email || !/^[a-zA-Z0-9-]{6,42}$/.test(reference)) throw new Error('Flutterwave payment configuration is incomplete')
  if (!Number.isSafeInteger(amountNgn) || amountNgn < 1000) throw new Error('The payable amount must be at least NGN 1,000 in whole naira')
  const response = await fetcher('https://api.flutterwave.com/v3/virtual-account-numbers', {
    method: 'POST',
    headers: { Authorization: `Bearer ${secretKey}`, 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify({ email, amount: amountNgn, currency: 'NGN', tx_ref: reference, is_permanent: false, expires: '120' }),
    signal: AbortSignal.timeout(8000),
  })
  if (!response.ok) throw new Error('Flutterwave could not create a temporary account')
  const payload = await response.json() as { status?: string; data?: Record<string, unknown> }
  const data = payload.data
  if (payload.status !== 'success' || !data || !/^\d{10}$/.test(String(data.account_number ?? ''))
    || typeof data.bank_name !== 'string' || !data.bank_name.trim() || typeof data.expiry_date !== 'string') {
    throw new Error('Flutterwave returned an invalid temporary account')
  }
  return { reference, accountNumber: data.account_number as string, bankName: data.bank_name,
    providerExpiry: data.expiry_date }
}

export async function verifyFlutterwaveTransaction(id: number, secretKey: string, fetcher: Fetcher = fetch) {
  if (!Number.isSafeInteger(id) || id <= 0 || !secretKey) throw new Error('Invalid Flutterwave verification request')
  const response = await fetcher(`https://api.flutterwave.com/v3/transactions/${id}/verify`, {
    headers: { Authorization: `Bearer ${secretKey}`, Accept: 'application/json' }, signal: AbortSignal.timeout(8000),
  })
  if (!response.ok) throw new Error('Flutterwave transaction verification failed')
  const payload = await response.json() as { status?: string; data?: Record<string, unknown> }
  if (payload.status !== 'success' || !payload.data) throw new Error('Flutterwave transaction verification failed')
  return payload.data
}

export async function verifyFlutterwaveReference(reference: string, secretKey: string, fetcher: Fetcher = fetch) {
  if (!/^[a-zA-Z0-9-]{6,42}$/.test(reference) || !secretKey) throw new Error('Invalid Flutterwave verification request')
  const response = await fetcher(`https://api.flutterwave.com/v3/transactions/verify_by_reference?tx_ref=${encodeURIComponent(reference)}`, {
    headers: { Authorization: `Bearer ${secretKey}`, Accept: 'application/json' }, signal: AbortSignal.timeout(8000),
  })
  if (!response.ok) return null
  const payload = await response.json() as { status?: string; data?: Record<string, unknown> }
  return payload.status === 'success' ? payload.data ?? null : null
}

export function verifiedBankTransfer(data: Record<string, unknown>, reference: string, amountNgn: number) {
  return data.tx_ref === reference && data.status === 'successful' && data.currency === 'NGN'
    && data.payment_type === 'bank_transfer' && Number(data.amount) === amountNgn
    && Number.isSafeInteger(Number(data.id)) && Number(data.id) > 0
}
