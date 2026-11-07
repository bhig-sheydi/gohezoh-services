import { describe, expect, it, vi } from 'vitest'
import { availableBalanceNgn, createRecipient, initiateTransfer, maxPaystackNetFromBalance, paystackTransferCharges, transferMatches, verifyTransfer, warnPaystackFeeMismatch } from './paystack-payout'

describe('Paystack payouts', () => {
  it.each([
    [50, 10, 0, 60], [5_000, 10, 0, 5_010], [5_001, 25, 0, 5_026],
    [9_999, 25, 0, 10_024], [10_000, 25, 50, 10_075],
    [50_000, 25, 50, 50_075], [50_001, 50, 50, 50_101],
  ])('quotes exact Paystack and stamp charges for ₦%i sent', (net, fee, stamp, gross) => {
    expect(paystackTransferCharges(net)).toEqual({ netNgn: net, transferFeeNgn: fee,
      stampDutyNgn: stamp, totalDebitNgn: gross })
  })
  it.each([
    [59, 0], [60, 50], [5_010, 5_000], [5_024, 5_000], [5_025, 5_000],
    [5_026, 5_001], [10_024, 9_999], [10_074, 9_999], [10_075, 10_000],
    [50_075, 50_000], [50_100, 50_000], [50_101, 50_001],
  ])('does not overdraw ₦%i when finding the maximum net amount', (gross, net) => {
    expect(maxPaystackNetFromBalance(gross)).toBe(net)
    if (net) expect(paystackTransferCharges(net).totalDebitNgn).toBeLessThanOrEqual(gross)
  })
  it('rejects subminimum and above-limit transfers', () => {
    expect(() => paystackTransferCharges(49)).toThrow()
    expect(() => paystackTransferCharges(10_000_001)).toThrow()
    expect(() => paystackTransferCharges(100.5)).toThrow()
  })
  it('flags an actual Paystack fee that differs from the quoted transfer fee without changing the debit', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const transfer = { id: 1, reference: 'kwp-test-1234567890', status: 'success', amountNgn: 1_000,
      currency: 'NGN', bankCode: '044', accountNumber: '0123456789', feeChargedNgn: 25 }
    warnPaystackFeeMismatch(transfer, 10)
    expect(warn).toHaveBeenCalledWith(expect.stringContaining('reconcile'),
      { reference: transfer.reference, quotedFeeNgn: 10, reportedFeeNgn: 25 })
    warn.mockClear()
    warnPaystackFeeMismatch({ ...transfer, feeChargedNgn: 0 }, 10)
    expect(warn).not.toHaveBeenCalled()
    warn.mockRestore()
  })
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
      return Response.json({ status: true, data: { id: 42, reference, amount: 500000, fee_charged: 1000,
        currency: 'NGN', status: 'success', recipient: { details: { bank_code: '044', account_number: '0123456789' } } } })
    }) as unknown as typeof fetch
    const recipient = await createRecipient('044', '0123456789', 'Ada Lagos', 'sk_test_x', fetcher)
    const initiated = await initiateTransfer(recipient, 5000, reference, 'sk_test_x', fetcher)
    expect(initiated.status).toBe('pending')
    const verified = await verifyTransfer(reference, 'sk_test_x', fetcher)
    expect(verified.feeChargedNgn).toBe(10)
    expect(transferMatches(verified, { reference, amount_ngn: 5000, bank_code: '044', account_number: '0123456789', provider_transfer_id: 42 })).toBe(true)
    expect(transferMatches(verified, { reference, amount_ngn: 5000, bank_code: '044', account_number: '9876543210' })).toBe(false)
  })
})
