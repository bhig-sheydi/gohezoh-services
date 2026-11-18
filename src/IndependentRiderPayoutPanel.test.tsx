import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import type { SupabaseClient } from '@supabase/supabase-js'
import IndependentRiderPayoutPanel from './IndependentRiderPayoutPanel'

describe('independent rider withdrawals', () => {
  it('uses the rider balance, confirms charges, and submits the net transfer', async () => {
    const rpc = vi.fn(async (name: string) => ({ data: name === 'get_my_independent_rider_payables'
      ? [{ available_ngn: 7500, pending_delivery_ngn: 0, withdrawal_pending_ngn: 0, total_paid_ngn: 0 }]
      : [], error: null }))
    const invoke = vi.fn(async (_name: string, args: { body: { action: string } }) => ({ data: args.body.action === 'account'
      ? { account: { bankName: 'Access Bank', accountName: 'Ada Rider', accountLast4: '1234' }, testMode: true }
      : args.body.action === 'quote'
        ? { availableNgn: 7500, netAmountNgn: 7475, transferFeeNgn: 25, stampDutyNgn: 0, grossDebitNgn: 7500, remainderNgn: 0, testMode: true }
        : { withdrawalId: 'withdrawal-1', status: 'queued', testMode: true }, error: null }))
    const client = { rpc, functions: { invoke } } as unknown as SupabaseClient
    const user = userEvent.setup()
    render(<IndependentRiderPayoutPanel supabase={client} />)

    await user.click(await screen.findByRole('button', { name: 'Withdraw' }))
    expect(invoke).toHaveBeenCalledWith('paystack-rider-payout', { body: { action: 'quote' } })
    expect(screen.getByRole('button', { name: 'Confirm withdrawal' })).toBeDisabled()
    await user.click(screen.getByRole('checkbox', { name: /I understand these charges/ }))
    await user.click(screen.getByRole('button', { name: 'Confirm withdrawal' }))
    await waitFor(() => expect(invoke).toHaveBeenCalledWith('paystack-rider-payout', {
      body: expect.objectContaining({ action: 'withdraw', amountNgn: 7475, idempotencyKey: expect.any(String) }),
    }))
    expect(screen.getByRole('status')).toHaveTextContent('Withdrawal queued')
  })
})
