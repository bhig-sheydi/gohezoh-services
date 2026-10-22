import { describe, expect, it, vi } from 'vitest'
import { createNigerianTransfer, findNigerianTransferByReference, listNigerianBanks, resolveNigerianAccount, transferMatchesReservation } from './flutterwave-payout'

const reply = (data: unknown, status = 200) => new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json' } })

describe('Flutterwave payout helpers', () => {
  it('loads supported banks and verifies the exact account number and name', async () => {
    const fetcher = vi.fn().mockResolvedValueOnce(reply({ status: 'success', data: [
      { code: '100004', name: 'OPay' }, { code: '044', name: 'Access Bank' }, { code: 'invalid', name: 'Bad Bank' },
    ] })).mockResolvedValueOnce(reply({ status: 'success', data: { account_number: '0690000034', account_name: 'Acme Logistics Ltd' } }))
    expect(await listNigerianBanks('test-secret', fetcher)).toEqual([{ code: '044', name: 'Access Bank' }, { code: '100004', name: 'OPay' }])
    expect(await resolveNigerianAccount('044', '0690000034', 'test-secret', fetcher)).toEqual({
      bankCode: '044', accountNumber: '0690000034', accountName: 'Acme Logistics Ltd',
    })
    expect(JSON.parse(fetcher.mock.calls[1][1].body)).toEqual({ account_bank: '044', account_number: '0690000034' })
  })

  it('rejects a mismatched account and provider errors', async () => {
    const mismatch = vi.fn().mockResolvedValue(reply({ status: 'success', data: { account_number: '0690000032', account_name: 'Someone Else' } }))
    await expect(resolveNigerianAccount('044', '0690000034', 'test-secret', mismatch)).rejects.toThrow(/did not match/)
    const failed = vi.fn().mockResolvedValue(reply({ status: 'error', message: 'Account invalid', data: null }, 400))
    await expect(resolveNigerianAccount('044', '0690000034', 'test-secret', failed)).rejects.toThrow('Account invalid')
    expect(failed).toHaveBeenCalledTimes(1)
  })

  it('initiates one exact NGN transfer and rejects altered recipient details', async () => {
    const input = { bankCode: '044', accountNumber: '0690000034', accountName: 'Acme Logistics Ltd', amountNgn: 7500,
      reference: 'KP-W-12345678-1234-1234-1234-123456789012', secret: 'test-secret' }
    const data = { id: 42, bank_code: '044', account_number: '0690000034', amount: 7500, currency: 'NGN', status: 'NEW', reference: input.reference }
    const fetcher = vi.fn().mockResolvedValueOnce(reply({ status: 'success', data }))
      .mockResolvedValueOnce(reply({ status: 'success', data: { ...data, account_number: '0000000000' } }))
    const first = await createNigerianTransfer(input, fetcher)
    expect(first.status).toBe('NEW')
    expect(JSON.parse(fetcher.mock.calls[0][1].body)).toMatchObject({ amount: 7500, currency: 'NGN', account_bank: '044', account_number: '0690000034', reference: input.reference })
    await expect(createNigerianTransfer(input, fetcher)).rejects.toThrow(/did not match/)
  })

  it('looks up an uncertain transfer by reference without initiating another', async () => {
    const reference = 'KP-W-12345678-1234-1234-1234-123456789012'
    const fetcher = vi.fn().mockResolvedValue(reply({ status: 'success', data: [{ id: 42, reference,
      account_number: '0690000034', bank_code: '044', amount: 7500, currency: 'NGN', status: 'SUCCESSFUL' }] }))
    expect((await findNigerianTransferByReference(reference, 'test-secret', fetcher))?.status).toBe('SUCCESSFUL')
    expect(fetcher.mock.calls[0][1].method).toBeUndefined()
  })

  it('accepts a provider suffix only with matching ID, amount and destination', () => {
    const reference = 'KWP-PAYOUT-12345678123412341234123456789012'
    const expected = { reference, provider_transfer_id: 42, amount_ngn: 7500, bank_code: '044', account_number: '0690000034' }
    const transfer = { id: 42, reference: `${reference}_PMCKDU_1`, status: 'SUCCESSFUL', amountNgn: 7500,
      currency: 'NGN', bankCode: '044', accountNumber: '0690000034', requiresApproval: false }
    expect(transferMatchesReservation(transfer, expected)).toBe(true)
    expect(transferMatchesReservation({ ...transfer, id: 43 }, expected)).toBe(false)
    expect(transferMatchesReservation({ ...transfer, amountNgn: 7600 }, expected)).toBe(false)
    expect(transferMatchesReservation({ ...transfer, accountNumber: '0690000035' }, expected)).toBe(false)
    expect(transferMatchesReservation({ ...transfer, reference: `${reference}evil` }, expected)).toBe(false)
  })
})
