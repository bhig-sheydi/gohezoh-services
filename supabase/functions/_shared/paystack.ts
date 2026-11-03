type Fetcher = typeof fetch
const api = 'https://api.paystack.co'
const headers = (secret: string) => ({ Authorization: `Bearer ${secret}`, 'Content-Type': 'application/json' })

async function request(path: string, secret: string, init: RequestInit, fetcher: Fetcher) {
  if (!secret) throw new Error('Paystack is not configured')
  const response = await fetcher(`${api}${path}`, { ...init, headers: headers(secret), signal: AbortSignal.timeout(10000) })
  const body = await response.json() as { status?: boolean; message?: string; data?: Record<string, unknown> }
  if (!response.ok || body.status !== true || !body.data) throw new Error(body.message || 'Paystack request failed')
  return body.data
}

export async function createPaystackAccount(input: { email: string; amountNgn: number; reference: string; secret: string; expiresAt: string }, fetcher: Fetcher = fetch) {
  if (!input.email || !/^[A-Za-z0-9-]{6,80}$/.test(input.reference) || !Number.isSafeInteger(input.amountNgn) || input.amountNgn < 1000)
    throw new Error('Invalid temporary account request')
  const expires = Date.parse(input.expiresAt)
  if (!Number.isFinite(expires) || expires <= Date.now()) throw new Error('Payment window has expired')
  const data = await request('/charge', input.secret, { method: 'POST', body: JSON.stringify({
    email: input.email, amount: input.amountNgn * 100, reference: input.reference,
    bank_transfer: { account_expires_at: input.expiresAt },
  }) }, fetcher)
  const details = data as { status?: string; reference?: string; display_text?: string;
    account_name?: string; account_number?: string; account_expires_at?: string; bank?: { name?: string; account_number?: string } }
  const accountNumber = String(details.account_number ?? details.bank?.account_number ?? '')
  const bankName = String(details.bank?.name ?? '')
  if (details.reference !== input.reference || !/^\d{10}$/.test(accountNumber) || !bankName
    || !details.account_expires_at || !Number.isFinite(Date.parse(details.account_expires_at)))
    throw new Error('Paystack returned an invalid temporary account')
  return { accountNumber, bankName, providerExpiry: details.account_expires_at }
}

export async function verifyPaystackPayment(reference: string, secret: string, fetcher: Fetcher = fetch) {
  if (!/^[A-Za-z0-9-]{6,80}$/.test(reference)) throw new Error('Invalid payment reference')
  return request(`/transaction/verify/${encodeURIComponent(reference)}`, secret, {}, fetcher)
}

export function paymentMatches(data: Record<string, unknown>, reference: string, amountNgn: number) {
  return data.reference === reference && data.status === 'success' && data.currency === 'NGN'
    && data.channel === 'bank_transfer' && Number(data.amount) === amountNgn * 100
    && Number.isSafeInteger(Number(data.id)) && Number(data.id) > 0
}
