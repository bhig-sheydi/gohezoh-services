import { describe, expect, it, vi } from 'vitest'
import { availableBalanceNgn, createRecipient, initiateTransfer, transferMatches, verifyTransfer } from './paystack-payout'

describe('Paystack payouts', () => {
  it('reads the funded NGN balance in naira', async () => {
    const fetcher = vi.fn(async () => Response.json({ status: true, data: [{ currency: 'NGN', balance: 510000 }] })) as unknown as typeof fetch
    expect(await availableBalanceNgn('sk_test_x', fetcher)).toBe(5100)
  })
  it('sends kobo with a unique reference and verifies the exact beneficiary', async () => {
    const reference = 'kwp-payout-12345678901234567890'
    const fetcher = vi.fn(async (url: string, init: RequestInit) => {
      if (url.endsWith('/transferrecipient')) return Response.json({ status: true, data: { recipient_code: 'RCP_abc123', details: { account_number: '0123456789', bank_code: '044' } } })
      if (url.endsWith('/transfer')) {
        expect(JSON.parse(String(init.body))).toMatchObject({ amount: 500000, reference, recipient: 'RCP_abc123', source: 'balance' })
        return Response.json({ status: true, data: { id: 42, reference, amount: 500000, currency: 'NGN', status: 'pending' } })
      }
      return Response.json({ status: true, data: { id: 42, reference, amount: 500000, currency: 'NGN', status: 'success', recipient: { details: { bank_code: '044', account_number: '0123456789' } } } })
    }) as unknown as typeof fetch
    const recipient = await createRecipient('044', '0123456789', 'Ada Lagos', 'sk_test_x', fetcher)
    const initiated = await initiateTransfer(recipient, 5000, reference, 'sk_test_x', fetcher)
    expect(initiated.status).toBe('pending')
    const verified = await verifyTransfer(reference, 'sk_test_x', fetcher)
    expect(transferMatches(verified, { reference, amount_ngn: 5000, bank_code: '044', account_number: '0123456789', provider_transfer_id: 42 })).toBe(true)
    expect(transferMatches(verified, { reference, amount_ngn: 5000, bank_code: '044', account_number: '9876543210' })).toBe(false)
  })
})
