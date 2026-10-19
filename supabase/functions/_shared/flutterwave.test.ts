import { describe, expect, it, vi } from 'vitest'
import { createDynamicAccount, verifiedBankTransfer, verifyFlutterwaveReference, verifyFlutterwaveTransaction } from './flutterwave'

describe('Flutterwave temporary accounts', () => {
  it('requests a single-use NGN account with a 120-second lifetime', async () => {
    const fetcher = vi.fn(async () => ({ ok: true, json: async () => ({ status: 'success', data: {
      account_number: '1234567890', bank_name: 'Test Bank', expiry_date: '2026-10-19 08:30:00',
    } }) })) as unknown as typeof fetch
    const result = await createDynamicAccount({ email: 'customer@example.com', amountNgn: 2500,
      reference: 'booking-123456', secretKey: 'test-secret', fetcher })
    expect(result.accountNumber).toBe('1234567890')
    const request = fetcher as unknown as ReturnType<typeof vi.fn>
    expect(JSON.parse(request.mock.calls[0][1].body)).toMatchObject({ amount: 2500, currency: 'NGN', expires: '120', is_permanent: false })
  })

  it('rejects an invalid account response before showing payment details', async () => {
    const fetcher = vi.fn(async () => ({ ok: true, json: async () => ({ status: 'success', data: { account_number: 'bad' } }) })) as unknown as typeof fetch
    await expect(createDynamicAccount({ email: 'customer@example.com', amountNgn: 2500, reference: 'booking-123456',
      secretKey: 'test-secret', fetcher })).rejects.toThrow('invalid temporary account')
  })

  it('verifies provider transaction data through the server', async () => {
    const fetcher = vi.fn(async () => ({ ok: true, json: async () => ({ status: 'success', data: {
      id: 123, tx_ref: 'booking-123456', status: 'successful', currency: 'NGN', amount: 2500,
    } }) })) as unknown as typeof fetch
    expect(await verifyFlutterwaveTransaction(123, 'test-secret', fetcher)).toMatchObject({ tx_ref: 'booking-123456' })
  })

  it('accepts only the matching successful NGN bank transfer', () => {
    const tx = { id: 123, tx_ref: 'booking-123456', status: 'successful', currency: 'NGN', amount: 2500, payment_type: 'bank_transfer' }
    expect(verifiedBankTransfer(tx, 'booking-123456', 2500)).toBe(true)
    expect(verifiedBankTransfer({ ...tx, amount: 250 }, 'booking-123456', 2500)).toBe(false)
    expect(verifiedBankTransfer({ ...tx, tx_ref: 'another-booking' }, 'booking-123456', 2500)).toBe(false)
    expect(verifiedBankTransfer({ ...tx, payment_type: 'card' }, 'booking-123456', 2500)).toBe(false)
  })

  it('returns no transaction when reference verification is not ready', async () => {
    const fetcher = vi.fn(async () => ({ ok: false })) as unknown as typeof fetch
    expect(await verifyFlutterwaveReference('booking-123456', 'test-secret', fetcher)).toBeNull()
  })
})
