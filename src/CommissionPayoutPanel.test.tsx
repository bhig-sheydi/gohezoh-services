import { describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { CommissionPayoutPanel } from './CommissionPayoutPanel'

describe('commission review and payout', () => {
  it('records an actual transfer for selected approved entries', async () => {
    const entry = { entry_id: 'entry-1', commission_type: 'direct_bdo', recipient_user_id: 'bdo-1', recipient_name: 'BDO One', recipient_email: 'bdo@example.test', job_number: 'JOB-1', amount_ngn: 600, status: 'approved', receipt_reference: 'RCPT-1', payout_reference: null, reviewer_id: 'manager-1', created_at: '2026-10-13T00:00:00Z' }
    const rpc = vi.fn(async (name: string) => {
      if (name === 'list_commission_work_queue') return { data: [entry], error: null }
      if (name === 'record_commission_payout') return { data: 'batch-1', error: null }
      return { data: null, error: null }
    })
    const supabase = { rpc } as unknown as Parameters<typeof CommissionPayoutPanel>[0]['supabase']
    const user = userEvent.setup()
    render(<CommissionPayoutPanel supabase={supabase} userId="finance-1" canReview={false} canPay onError={vi.fn()} onNotice={vi.fn()} />)

    await screen.findByText('Direct BDO / Job JOB-1')
    await user.click(screen.getByLabelText('Select Direct BDO commission for job JOB-1'))
    await user.type(screen.getByLabelText('Actual transfer reference'), 'BANK-TRANSFER-01')
    await user.click(screen.getByRole('button', { name: 'Record payout as paid' }))

    await waitFor(() => expect(rpc).toHaveBeenCalledWith('record_commission_payout', {
      p_commission_type: 'direct_bdo', p_entry_ids: ['entry-1'], p_transfer_reference: 'BANK-TRANSFER-01',
    }))
    expect(screen.getByText('Direct BDO / Job JOB-1')).toBeInTheDocument()
  })

  it('does not offer payout selection to the person who approved the commission', async () => {
    const rpc = vi.fn(async () => ({ data: [{ entry_id: 'entry-2', commission_type: 'marketer', recipient_user_id: 'mk-1', recipient_name: null, recipient_email: 'marketer@example.test', job_number: 'JOB-2', amount_ngn: 1000, status: 'approved', receipt_reference: null, payout_reference: null, reviewer_id: 'finance-1', created_at: '2026-10-13T00:00:00Z' }], error: null }))
    const supabase = { rpc } as unknown as Parameters<typeof CommissionPayoutPanel>[0]['supabase']
    render(<CommissionPayoutPanel supabase={supabase} userId="finance-1" canReview={false} canPay onError={vi.fn()} onNotice={vi.fn()} />)
    await screen.findByText('Marketer / Job JOB-2')
    expect(screen.queryByLabelText('Select Marketer commission for job JOB-2')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Record payout as paid' })).not.toBeInTheDocument()
  })

  it('requires a reason when management approves an offset for a previously paid commission', async () => {
    const recovery = { entry_id: 'recovery-1', commission_type: 'marketer', recipient_user_id: 'mk-1', recipient_name: 'Marketer One', recipient_email: 'marketer@example.test', job_number: 'JOB-3', amount_ngn: -500, status: 'adjusted', receipt_reference: 'RCPT-3', payout_reference: null, reviewer_id: null, created_at: '2026-10-13T00:00:00Z', recovery_review_status: 'pending', recovery_reviewer_id: null, offset_applied_ngn: 0, recovery_eligible: true }
    const rpc = vi.fn(async () => ({ data: [recovery], error: null }))
    const supabase = { rpc } as unknown as Parameters<typeof CommissionPayoutPanel>[0]['supabase']
    const prompt = vi.spyOn(window, 'prompt').mockReturnValue('Verified paid reversal')
    const user = userEvent.setup()
    render(<CommissionPayoutPanel supabase={supabase} userId="manager-1" canReview canPay={false} onError={vi.fn()} onNotice={vi.fn()} />)

    await user.click(await screen.findByRole('button', { name: 'Approve offset' }))

    await waitFor(() => expect(rpc).toHaveBeenCalledWith('review_commission_recovery', {
      p_commission_type: 'marketer', p_entry_id: 'recovery-1', p_approve: true, p_reason: 'Verified paid reversal',
    }))
    expect(prompt).toHaveBeenCalled()
    prompt.mockRestore()
  })
})
