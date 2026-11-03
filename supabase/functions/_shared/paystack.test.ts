import { describe, expect, it, vi } from 'vitest'
import { createPaystackAccount, paymentMatches, verifyPaystackPayment } from './paystack'

describe('Paystack bank transfer payment', () => {
  it('creates a temporary account for the requested amount and expiry', async () => {
    const expiry = new Date(Date.now() + 15 * 60_000).toISOString()
    const fetcher = vi.fn(async (_url: string, init: RequestInit) => {
      const body = JSON.parse(String(init.body))
      expect(body).toMatchObject({ amount: 400000, reference: 'KP-123456789', bank_transfer: { account_expires_at: expiry } })
      return Response.json({ status: true, data: { reference: body.reference, account_number: '1234567890', bank: { name: 'Test Bank' }, account_expires_at: expiry } })
    }) as unknown as typeof fetch
    expect(await createPaystackAccount({ email: 'customer@example.com', amountNgn: 4000, reference: 'KP-123456789', secret: 'sk_test_x', expiresAt: expiry }, fetcher))
      .toMatchObject({ accountNumber: '1234567890', bankName: 'Test Bank', providerExpiry: expiry })
    expect(fetcher).toHaveBeenCalledOnce()
  })
  it('rejects malformed provider accounts', async () => {
    const expiry = new Date(Date.now() + 15 * 60_000).toISOString()
    const fetcher = vi.fn(async () => Response.json({ status: true, data: { reference: 'KP-123456789', account_number: 'bad', bank: { name: 'Test Bank' }, account_expires_at: expiry } })) as unknown as typeof fetch
    await expect(createPaystackAccount({ email: 'customer@example.com', amountNgn: 4000, reference: 'KP-123456789', secret: 'sk_test_x', expiresAt: expiry }, fetcher)).rejects.toThrow('invalid temporary account')
  })
  it('only accepts verified exact NGN bank transfers', async () => {
    const fetcher = vi.fn(async () => Response.json({ status: true, data: { id: 52, reference: 'KP-123456789', status: 'success', currency: 'NGN', channel: 'bank_transfer', amount: 400000 } })) as unknown as typeof fetch
    const payment = await verifyPaystackPayment('KP-123456789', 'sk_test_x', fetcher)
    expect(paymentMatches(payment, 'KP-123456789', 4000)).toBe(true)
    expect(paymentMatches(payment, 'KP-123456789', 4001)).toBe(false)
    expect(paymentMatches({ ...payment, channel: 'card' }, 'KP-123456789', 4000)).toBe(false)
  })
})
