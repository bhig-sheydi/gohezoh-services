import { describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { CommissionPlansPanel } from './CommissionPlansPanel'

function makeClient(rpc = vi.fn(async () => ({ data: 'plan-1', error: null }))) {
  const from = vi.fn((table: string) => {
    const result = table === 'user_roles'
      ? { data: [{ user_id: 'bdo-1' }], error: null }
      : table === 'profiles'
        ? { data: [{ user_id: 'bdo-1', full_name: 'BDO One', email: 'bdo@example.test' }], error: null }
        : { data: [{ id: 'plan-1', bdo_id: 'bdo-1', version: 1, basis: 'collected_revenue', rate: 0.1, fixed_amount_ngn: null, terms: { agreement_reference: 'AGR-001', eligible_service_codes: ['SRV-0001'] }, effective_from: '2026-10-01', effective_until: null, created_at: '2026-10-01T00:00:00Z' }], error: null }
    const query = {
      select: vi.fn(() => query), eq: vi.fn(() => query), in: vi.fn(() => query),
      order: vi.fn(() => query), limit: vi.fn(() => query),
      then: (resolve: (value: unknown) => unknown) => Promise.resolve(result).then(resolve),
    }
    return query
  })
  return { from, rpc } as unknown as Parameters<typeof CommissionPlansPanel>[0]['supabase']
}

describe('commission plan management', () => {
  it('lists the approved plans and only allows managers to submit a signed, service-scoped plan', async () => {
    const rpc = vi.fn(async () => ({ data: 'new-plan', error: null }))
    const supabase = makeClient(rpc)
    const onNotice = vi.fn()
    render(<CommissionPlansPanel supabase={supabase} canManage onError={vi.fn()} onNotice={onNotice} />)

    expect(await screen.findByText('BDO One · v1')).toBeInTheDocument()
    fireEvent.change(screen.getByLabelText('BDO'), { target: { value: 'bdo-1' } })
    fireEvent.change(screen.getByLabelText('Rate (%)'), { target: { value: '10' } })
    fireEvent.change(screen.getByLabelText('Signed agreement reference'), { target: { value: 'AGR-002' } })
    fireEvent.change(screen.getByLabelText('Approval reason'), { target: { value: 'Signed plan reviewed by management' } })
    fireEvent.click(screen.getByLabelText('Local delivery'))
    fireEvent.submit(screen.getByRole('button', { name: 'Approve plan' }).closest('form')!)

    await waitFor(() => expect(rpc).toHaveBeenCalledWith('approve_commission_plan', {
      p_bdo_id: 'bdo-1', p_basis: 'collected_revenue', p_rate: 0.1, p_fixed_amount_ngn: null,
      p_terms: { agreement_reference: 'AGR-002', eligible_service_codes: ['SRV-0001'] },
      p_effective_from: expect.any(String), p_reason: 'Signed plan reviewed by management',
    }))
    expect(onNotice).toHaveBeenCalledWith('Commission plan approved and saved with its effective date.')
  })

  it('does not render plan approval controls for finance-only viewers', async () => {
    render(<CommissionPlansPanel supabase={makeClient()} canManage={false} onError={vi.fn()} onNotice={vi.fn()} />)
    expect(await screen.findByText('BDO One · v1')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Approve plan' })).not.toBeInTheDocument()
  })
})
