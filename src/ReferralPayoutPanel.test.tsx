import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import type { SupabaseClient } from '@supabase/supabase-js'
import ReferralPayoutPanel from './ReferralPayoutPanel'

describe('referral withdrawals', () => {
  it('shows charges and net bank amount before debiting earnings', async () => {
    const invoke = vi.fn(async (_name: string, args: { body: { action: string; amountNgn?: number } }) => {
      if (args.body.action === 'account') return { data: { available_ngn: 20000, account: { bank_name: 'Access Bank', account_name: 'Ada Okafor', account_last4: '1234' }, withdrawals: [] }, error: null }
      if (args.body.action === 'quote') return { data: { netAmountNgn: 19925, transferFeeNgn: 25, stampDutyNgn: 50, grossDebitNgn: 20000, remainderNgn: 0 }, error: null }
      if (args.body.action === 'withdraw') return { data: { withdrawalId: 'transfer-1', status: 'queued' }, error: null }
      return { data: null, error: null }
    })
    const onError = vi.fn(), onNotice = vi.fn()
    const supabase = { functions: { invoke } } as unknown as SupabaseClient
    const user = userEvent.setup()
    render(<ReferralPayoutPanel supabase={supabase} onError={onError} onNotice={onNotice} />)

    await user.click(await screen.findByRole('button', { name: 'Withdraw' }))
    expect(invoke).toHaveBeenCalledWith('paystack-referral-payout', { body: { action: 'quote', amountNgn: 20000 } })
    const breakdown = await screen.findByRole('region', { name: 'Withdrawal breakdown' })
    expect(within(breakdown).getByText('₦20,000.00')).toBeInTheDocument()
    expect(within(breakdown).getByText('−₦25.00')).toBeInTheDocument()
    expect(within(breakdown).getByText('−₦50.00')).toBeInTheDocument()
    expect(within(breakdown).getByText('₦19,925.00')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Confirm withdrawal' })).toBeDisabled()
    expect(invoke).not.toHaveBeenCalledWith('paystack-referral-payout', { body: expect.objectContaining({ action: 'withdraw' }) })
    await user.click(screen.getByRole('checkbox', { name: /I understand these charges/ }))
    await user.click(screen.getByRole('button', { name: 'Confirm withdrawal' }))
    await waitFor(() => expect(invoke).toHaveBeenCalledWith('paystack-referral-payout', { body: expect.objectContaining({ action: 'withdraw', amountNgn: 19925 }) }))
    expect(onNotice).toHaveBeenCalledWith('Withdrawal submitted.')
    expect(onError).not.toHaveBeenCalled()
  })

  it('does not allow confirmation when the fee quote is inconsistent', async () => {
    const invoke = vi.fn(async (_name: string, args: { body: { action: string } }) => args.body.action === 'account'
      ? { data: { available_ngn: 5000, account: { bank_name: 'Access Bank', account_name: 'Ada Okafor', account_last4: '1234' }, withdrawals: [] }, error: null }
      : { data: { netAmountNgn: 5000, transferFeeNgn: 10, stampDutyNgn: 0, grossDebitNgn: 5000, remainderNgn: 0 }, error: null })
    const onError = vi.fn()
    const user = userEvent.setup()
    render(<ReferralPayoutPanel supabase={{ functions: { invoke } } as unknown as SupabaseClient} onError={onError} onNotice={vi.fn()} />)
    await user.click(await screen.findByRole('button', { name: 'Withdraw' }))
    await waitFor(() => expect(onError).toHaveBeenCalledWith('Could not calculate the bank charges. Please try again.'))
    expect(screen.queryByRole('button', { name: 'Confirm withdrawal' })).not.toBeInTheDocument()
  })
})
