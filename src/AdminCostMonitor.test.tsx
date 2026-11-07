import { afterEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { SupabaseClient } from '@supabase/supabase-js'
import AdminCostMonitor from './AdminCostMonitor'

const snapshot = {
  checked_at: new Date().toISOString(), period_start: '2026-11-07T00:00:00Z', period_end: '2026-11-08T00:00:00Z',
  completed_paid_jobs: 1, completed_revenue_ngn: 2100, cancelled_retained_revenue_ngn: 0,
  collected_revenue_ngn: 2100, partner_payable_ngn: 1575, other_direct_cost_ngn: 20,
  customer_referral_ngn: 52.5, partner_referral_ngn: 39.38,
  registration_referral_reserve_ngn: 52.5,
  available_for_operations_ngn: 360.62, target_profit_ngn: 105, operating_budget_ngn: 255.62,
  recorded_costs_ngn: 100, known_cost_lower_bound_ngn: 100,
  estimated_operating_cost_ngn: null, remaining_operating_budget_ngn: null,
  google_elements_today: 25, google_elements_daily_limit: 5000,
  modeled_costs: { google_route_matrix_ngn: null, sms_ngn: null, paystack_ngn: null,
    supabase_ngn: null, total_known_ngn: 0 },
  margin_status: 'unknown', mode: 'normal', warnings: [],
  estimated_tracked_cost_ngn: 31.5,
  cost_settings: { supabase_plan: 'free', supabase_monthly_usd: 0,
    google_route_sku: 'essentials', google_free_monthly_elements: 10000,
    google_usd_per_1000: 5, usd_to_ngn: null, paystack_percent: 1.5,
    paystack_flat_ngn: 100, paystack_flat_waiver_below_ngn: 2500,
    paystack_fee_cap_ngn: 2000, sms_ngn_per_message: null },
  data_gaps: ['Paystack fees are not connected or recorded.', 'Supabase charges are not connected or recorded.'],
}

function client(value: unknown = snapshot) {
  let current = value
  const rpc = vi.fn(async (name: string, params?: { p_mode?: string }) => {
    if (name === 'admin_cost_monitor') return { data: current, error: null }
    if (name === 'admin_supabase_project_usage_snapshot') return { data: { database_bytes: 9_000_000_000 }, error: null }
    if (name === 'set_admin_cost_mode') {
      current = { ...(current as object), mode: params?.p_mode }
      return { data: { mode: params?.p_mode, changed_at: new Date().toISOString() }, error: null }
    }
    if (name === 'record_admin_operating_cost') return { data: { id: 'cost-1' }, error: null }
    if (name === 'set_admin_cost_rate_settings') return { data: params, error: null }
    return { data: null, error: null }
  })
  return { supabase: { rpc } as unknown as SupabaseClient, rpc }
}

describe('super-admin spending monitor', () => {
  afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals() })

  it('shows unknown provider costs as unknown and the Google ceiling as a separate backstop', async () => {
    const { supabase } = client()
    render(<AdminCostMonitor supabase={supabase} refreshKey={0} />)
    expect(await screen.findByText('Cost picture incomplete')).toBeInTheDocument()
    expect(screen.getByText('Allowance for operating costs')).toBeInTheDocument()
    expect(screen.getAllByText('Not yet known').length).toBeGreaterThanOrEqual(2)
    expect(screen.getByText(/25 of 5,000 default/).closest('p')).toHaveTextContent('separate emergency ceiling')
    expect(screen.getByText('Cost data not connected yet')).toBeInTheDocument()
    await userEvent.click(screen.getByText('Cost data not connected yet'))
    expect(screen.getByText(/Paystack fees are not connected/)).toBeVisible()
    await userEvent.click(screen.getByText('How this allowance is calculated'))
    const lowerBound = screen.getByText('Known cost lower bound').closest('div')
    expect(lowerBound).not.toBeNull()
    expect(within(lowerBound!).getByText(/100\.00/)).toBeInTheDocument()
    expect(screen.getByText(/Route Matrix reservations may exceed billable usage/)).toBeInTheDocument()
  })

  it('turns on reversible savings mode only after the server confirms it', async () => {
    const { supabase, rpc } = client()
    render(<AdminCostMonitor supabase={supabase} refreshKey={0} />)
    const button = await screen.findByRole('button', { name: 'Reduce optional routing work' })
    expect(button).toHaveAttribute('aria-pressed', 'false')
    await userEvent.click(button)
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('set_admin_cost_mode', { p_mode: 'economy' }))
    expect(await screen.findByRole('button', { name: 'Resume normal matching' })).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByText(/GPS, paid deliveries, payments, refunds and tracking continue/)).toBeInTheDocument()
  })

  it('records a provider charge with a reference and does not treat it as a transfer', async () => {
    const { supabase, rpc } = client()
    render(<AdminCostMonitor supabase={supabase} refreshKey={0} />)
    await screen.findByText('Cost picture incomplete')
    await userEvent.click(screen.getByText('Record a provider charge'))
    await userEvent.selectOptions(screen.getByLabelText('Provider'), 'paystack_payment')
    await userEvent.type(screen.getByLabelText('Amount (NGN)'), '35.50')
    await userEvent.type(screen.getByLabelText('Provider reference'), 'psk-invoice-100')
    await userEvent.click(screen.getByRole('button', { name: 'Record charge' }))
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('record_admin_operating_cost', expect.objectContaining({
      p_source: 'paystack_payment', p_amount_ngn: 35.5, p_reference: 'psk-invoice-100',
    })))
    expect(await screen.findByText(/Provider charge recorded/)).toBeInTheDocument()
  })

  it('saves plan-aware cost assumptions for the super admin', async () => {
    const { supabase, rpc } = client()
    render(<AdminCostMonitor supabase={supabase} refreshKey={0} />)
    await screen.findByText('Cost picture incomplete')
    await userEvent.click(screen.getByText('Configure cost estimates'))
    expect(screen.queryByLabelText('Supabase base USD/month')).not.toBeInTheDocument()
    await userEvent.selectOptions(screen.getByLabelText('Supabase plan'), 'pro')
    expect(screen.getByText('Supabase pro plan: $25/month base')).toBeInTheDocument()
    expect(screen.getByText('$0.09 / GB')).toBeInTheDocument()
    expect(screen.getByText(/Database-size overage at this instant: \$0\.13\/month run rate/)).toBeInTheDocument()
    await userEvent.type(screen.getByLabelText('USD to NGN'), '1500')
    await userEvent.click(screen.getByRole('button', { name: 'Save cost assumptions' }))
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('set_admin_cost_rate_settings', expect.objectContaining({
      p_settings: expect.objectContaining({ supabase_plan: 'pro', supabase_monthly_usd: 25, usd_to_ngn: 1500 }),
    })))
  })

  it('refreshes the indicative exchange rate and shows a red margin warning', async () => {
    const { supabase, rpc } = client({ ...snapshot, margin_warning: 'Measured and modeled costs leave an estimated margin of 9.50%.' })
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: true, json: async () => ({
      result: 'success', base_code: 'USD', rates: { NGN: 1350 }, time_last_update_unix: Math.floor(Date.now() / 1000),
    }) })))
    render(<AdminCostMonitor supabase={supabase} refreshKey={0} />)
    expect(await screen.findByText('Profit margin warning')).toBeInTheDocument()
    await userEvent.click(screen.getByText('Configure cost estimates'))
    await userEvent.click(screen.getByRole('button', { name: 'Update USD/NGN rate' }))
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('set_admin_cost_rate_settings', expect.objectContaining({
      p_settings: expect.objectContaining({ usd_to_ngn: 1350 }),
    })))
  })

  it('reports an unavailable snapshot without showing a false healthy margin', async () => {
    const { supabase } = client(null)
    render(<AdminCostMonitor supabase={supabase} refreshKey={0} />)
    expect(await screen.findByText(/The spending report was incomplete/)).toBeInTheDocument()
    expect(screen.getByText('Spending figures are unavailable.')).toBeInTheDocument()
    expect(screen.queryByText('Within the measured allowance')).not.toBeInTheDocument()
  })
})
