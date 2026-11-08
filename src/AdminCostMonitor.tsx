import { useCallback, useEffect, useRef, useState } from 'react'
import type { FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'

type CostSource = 'google_route_matrix' | 'paystack_payment' | 'sms_delivery' | 'supabase' | 'other'
type CostMode = 'normal' | 'economy'
type MarginStatus = 'unknown' | 'healthy' | 'attention' | 'over_budget'
type CostSettings = {
  supabase_plan: 'free' | 'pro' | 'team' | 'enterprise'
  supabase_monthly_usd: number
  google_route_sku: 'essentials' | 'pro' | 'enterprise'
  google_free_monthly_elements: number
  google_usd_per_1000: number
  usd_to_ngn: number | null
  paystack_percent: number
  paystack_flat_ngn: number
  paystack_flat_waiver_below_ngn: number
  paystack_fee_cap_ngn: number
  sms_ngn_per_message: number | null
}
const supabaseRates = [
  { service: 'Database disk', free: '0.5 GB / project', paid: '8 GB / project', overage: '$0.125 / GB-month' },
  { service: 'Uncached egress', free: '5 GB', paid: '250 GB', overage: '$0.09 / GB' },
  { service: 'Cached egress', free: '5 GB', paid: '250 GB', overage: '$0.03 / GB' },
  { service: 'Monthly active users', free: '50,000', paid: '100,000', overage: '$0.00325 / user' },
  { service: 'File storage', free: '1 GB', paid: '100 GB', overage: '$0.0213 / GB-month' },
  { service: 'Edge invocations', free: '500,000', paid: '2 million', overage: '$2 / million' },
  { service: 'Realtime messages', free: '2 million', paid: '5 million', overage: '$2.50 / million' },
  { service: 'Peak realtime connections', free: '200', paid: '500', overage: '$10 / 1,000' },
  { service: 'Log ingest', free: '1 GB', paid: '20 GB', overage: '$0.50 / GB' },
] as const

type CostSnapshot = {
  checked_at: string
  period_start: string
  period_end: string
  completed_paid_jobs: number
  completed_revenue_ngn: number
  cancelled_retained_revenue_ngn: number
  collected_revenue_ngn: number
  partner_payable_ngn: number
  other_direct_cost_ngn: number
  customer_referral_ngn: number
  partner_referral_ngn: number
  registration_referral_reserve_ngn: number
  available_for_operations_ngn: number
  target_profit_ngn: number
  operating_budget_ngn: number
  recorded_costs_ngn: number
  known_cost_lower_bound_ngn: number
  estimated_operating_cost_ngn: number | null
  remaining_operating_budget_ngn: number | null
  google_elements_today: number
  google_elements_daily_limit: number
  google_billable_elements_today?: number
  estimated_tracked_cost_ngn?: number
  google_other_api_estimate_ngn?: number | null
  google_other_api_counts_today?: Record<string, number>
  estimated_margin_percent?: number | null
  margin_warning?: string | null
  cost_settings?: CostSettings
  modeled_costs: {
    google_route_matrix_ngn: number | null
    google_other_apis_ngn?: number | null
    sms_ngn: number | null
    paystack_ngn: number | null
    supabase_ngn: number | null
    total_known_ngn: number
  }
  margin_status: MarginStatus
  mode: CostMode
  warnings: string[]
  data_gaps: string[]
}

const sources: { value: CostSource; label: string }[] = [
  { value: 'google_route_matrix', label: 'Google Routes' },
  { value: 'paystack_payment', label: 'Paystack' },
  { value: 'sms_delivery', label: 'SMS' },
  { value: 'supabase', label: 'Supabase' },
  { value: 'other', label: 'Other' },
]

function isCostSnapshot(value: unknown): value is CostSnapshot {
  if (!value || typeof value !== 'object') return false
  const row = value as Partial<CostSnapshot>
  const numbers = [row.completed_paid_jobs, row.completed_revenue_ngn, row.cancelled_retained_revenue_ngn,
    row.collected_revenue_ngn, row.partner_payable_ngn, row.other_direct_cost_ngn,
    row.customer_referral_ngn, row.partner_referral_ngn,
    row.registration_referral_reserve_ngn, row.available_for_operations_ngn, row.target_profit_ngn,
    row.operating_budget_ngn, row.recorded_costs_ngn, row.known_cost_lower_bound_ngn,
    row.google_elements_today, row.google_elements_daily_limit]
  return typeof row.checked_at === 'string' && typeof row.period_start === 'string' &&
    typeof row.period_end === 'string' && numbers.every((number) => typeof number === 'number' && Number.isFinite(number)) &&
    (row.mode === 'normal' || row.mode === 'economy') &&
    (row.margin_status === 'unknown' || row.margin_status === 'healthy' ||
      row.margin_status === 'attention' || row.margin_status === 'over_budget') &&
    Array.isArray(row.warnings) && row.warnings.every((item) => typeof item === 'string') &&
    Array.isArray(row.data_gaps) && row.data_gaps.every((item) => typeof item === 'string') &&
    !!row.modeled_costs && typeof row.modeled_costs.total_known_ngn === 'number'
}

function money(value: number | null | undefined) {
  return typeof value === 'number' && Number.isFinite(value)
    ? new Intl.NumberFormat('en-NG', { style: 'currency', currency: 'NGN', maximumFractionDigits: 2 }).format(value)
    : 'Not yet known'
}

function number(value: number) {
  return new Intl.NumberFormat('en-NG', { maximumFractionDigits: 0 }).format(value)
}

function time(value: string) {
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? 'Time unavailable' : new Intl.DateTimeFormat('en-NG', {
    timeZone: 'Africa/Lagos', dateStyle: 'medium', timeStyle: 'short',
  }).format(date)
}

function todayUtc() { return new Date().toISOString().slice(0, 10) }

export default function AdminCostMonitor({ supabase, refreshKey }: { supabase: SupabaseClient; refreshKey: number }) {
  const [snapshot, setSnapshot] = useState<CostSnapshot | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [modeBusy, setModeBusy] = useState(false)
  const [entryBusy, setEntryBusy] = useState(false)
  const [entryNotice, setEntryNotice] = useState('')
  const [source, setSource] = useState<CostSource>('google_route_matrix')
  const [amount, setAmount] = useState('')
  const [costDay, setCostDay] = useState(todayUtc)
  const [reference, setReference] = useState('')
  const [note, setNote] = useState('')
  const [checkedNow, setCheckedNow] = useState(0)
  const [settings, setSettings] = useState<CostSettings | null>(null)
  const [settingsBusy, setSettingsBusy] = useState(false)
  const [settingsNotice, setSettingsNotice] = useState('')
  const [fxBusy, setFxBusy] = useState(false)
  const [databaseBytes, setDatabaseBytes] = useState<number | null>(null)
  const fxAutoAttempted = useRef(false)
  const requestInFlight = useRef(false)

  const load = useCallback(async () => {
    if (requestInFlight.current || document.visibilityState === 'hidden') return
    requestInFlight.current = true
    try {
      const { data, error: rpcError } = await supabase.rpc('admin_cost_monitor')
      if (rpcError) throw rpcError
      if (!isCostSnapshot(data)) throw new Error('The spending report was incomplete.')
      setSnapshot(data)
      if (data.cost_settings) setSettings(data.cost_settings)
      const { data: usage } = await supabase.rpc('admin_supabase_project_usage_snapshot')
      if (usage && typeof usage.database_bytes === 'number' && Number.isFinite(usage.database_bytes)) setDatabaseBytes(usage.database_bytes)
      setError('')
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'The spending report is unavailable.')
    } finally {
      requestInFlight.current = false
      setLoading(false)
      setCheckedNow(Date.now())
    }
  }, [supabase])

  useEffect(() => {
    const initial = window.setTimeout(() => void load(), 0)
    const timer = window.setInterval(() => void load(), 300_000)
    const onVisibilityChange = () => { if (document.visibilityState === 'visible') void load() }
    document.addEventListener('visibilitychange', onVisibilityChange)
    return () => {
      window.clearTimeout(initial)
      window.clearInterval(timer)
      document.removeEventListener('visibilitychange', onVisibilityChange)
    }
  }, [load, refreshKey])

  async function changeMode() {
    if (!snapshot || modeBusy) return
    const nextMode: CostMode = snapshot.mode === 'normal' ? 'economy' : 'normal'
    setModeBusy(true)
    setError('')
    try {
      const { data, error: rpcError } = await supabase.rpc('set_admin_cost_mode', { p_mode: nextMode })
      if (rpcError) throw rpcError
      if (!data || data.mode !== nextMode) throw new Error('The mode change was not confirmed.')
      setSnapshot((current) => current && ({ ...current, mode: nextMode }))
      await load()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not change matching mode.')
    } finally {
      setModeBusy(false)
    }
  }

  async function recordCharge(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const parsedAmount = Number(amount)
    if (!Number.isFinite(parsedAmount) || parsedAmount <= 0 || !costDay || !reference.trim()) {
      setEntryNotice('Enter a positive amount, charge date and provider reference.')
      return
    }
    setEntryBusy(true)
    setEntryNotice('')
    try {
      const { error: rpcError } = await supabase.rpc('record_admin_operating_cost', {
        p_source: source, p_amount_ngn: parsedAmount, p_cost_day: costDay,
        p_reference: reference.trim(), p_note: note.trim() || null,
      })
      if (rpcError) throw rpcError
      setAmount('')
      setReference('')
      setNote('')
      setEntryNotice('Provider charge recorded. Refreshing the report.')
      await load()
    } catch (cause) {
      setEntryNotice(cause instanceof Error ? cause.message : 'Could not record this charge.')
    } finally {
      setEntryBusy(false)
    }
  }

  async function saveSettings(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!settings || settingsBusy) return
    setSettingsBusy(true)
    setSettingsNotice('')
    try {
      const { error: rpcError } = await supabase.rpc('set_admin_cost_rate_settings', { p_settings: settings })
      if (rpcError) throw rpcError
      setSettingsNotice('Cost assumptions saved. Estimates refreshed.')
      await load()
    } catch (cause) {
      setSettingsNotice(cause instanceof Error ? cause.message : 'Could not save cost assumptions.')
    } finally { setSettingsBusy(false) }
  }

  const refreshExchangeRate = useCallback(async () => {
    if (!settings || fxBusy) return
    setFxBusy(true)
    setSettingsNotice('')
    try {
      const response = await fetch('https://open.er-api.com/v6/latest/USD', { signal: AbortSignal.timeout(8000) })
      if (!response.ok) throw new Error('Exchange-rate service is unavailable.')
      const data = await response.json() as { result?: string; base_code?: string; rates?: { NGN?: number }; time_last_update_unix?: number }
      const rate = data.rates?.NGN
      if (data.result !== 'success' || data.base_code !== 'USD' || typeof rate !== 'number'
        || !Number.isFinite(rate) || rate < 100 || rate > 100_000
        || !data.time_last_update_unix || Math.abs(Date.now() - data.time_last_update_unix * 1000) > 4 * 86_400_000) {
        throw new Error('The exchange-rate service returned an invalid or stale rate.')
      }
      const { error: rpcError } = await supabase.rpc('set_admin_cost_rate_settings', { p_settings: { ...settings, usd_to_ngn: rate } })
      if (rpcError) throw rpcError
      try { window.localStorage.setItem('kwik-fx-auto-day', todayUtc()) } catch { /* Private browsing may block storage. */ }
      setSettingsNotice(`USD to NGN updated to ₦${rate.toFixed(2)} from the daily exchange-rate feed. This may differ from your card provider's rate.`)
      await load()
    } catch (cause) { setSettingsNotice(cause instanceof Error ? cause.message : 'Could not refresh the exchange rate.') }
    finally { setFxBusy(false) }
  }, [settings, fxBusy, supabase, load])

  useEffect(() => {
    if (!settings || fxAutoAttempted.current || import.meta.env.MODE === 'test') return
    fxAutoAttempted.current = true
    try { if (window.localStorage.getItem('kwik-fx-auto-day') === todayUtc()) return } catch { /* Try once anyway. */ }
    const timer = window.setTimeout(() => { void refreshExchangeRate() }, 0)
    return () => window.clearTimeout(timer)
  }, [settings, refreshExchangeRate])

  const stale = snapshot ? checkedNow - new Date(snapshot.checked_at).getTime() > 900_000 : false
  const statusLabel = snapshot?.margin_status === 'over_budget' ? 'Known costs exceed the allowance'
    : snapshot?.margin_status === 'attention' ? 'Known costs need attention'
      : snapshot?.margin_status === 'healthy' ? 'Within the measured allowance' : 'Cost picture incomplete'
  const diskIncludedGb = settings?.supabase_plan === 'free' ? 0.5 : settings?.supabase_plan === 'enterprise' ? null : 8
  const diskOverageRunRateUsd = databaseBytes !== null && diskIncludedGb !== null && settings && settings.supabase_plan !== 'free'
    ? Math.max(0, databaseBytes / 1_000_000_000 - diskIncludedGb) * 0.125 : null

  return <div className="cost-monitor" aria-labelledby="cost-monitor-title">
    <div className="cost-monitor-heading">
      <div><h3 id="cost-monitor-title">Spending and margin</h3><p>Collected rides and provider costs for the current UTC day. This is an operating view, not a bank balance.</p></div>
      {snapshot && <span className={`cost-monitor-status cost-monitor-status-${snapshot.margin_status}`} role="status">{statusLabel}</span>}
    </div>
    {error && <p className="traffic-monitor-error" role="alert">Spending monitor: {error} {snapshot ? 'Showing the last successful report.' : ''}</p>}
    {stale && <p className="traffic-monitor-error" role="alert">Spending figures are more than 15 minutes old. Refresh before making a decision.</p>}
    {loading && !snapshot ? <p className="traffic-monitor-empty">Checking spending...</p> : !snapshot ? <p className="traffic-monitor-empty">Spending figures are unavailable.</p> : <>
      <p className="cost-monitor-period">{time(snapshot.period_start)} to {time(snapshot.period_end)} | checked {time(snapshot.checked_at)}</p>
      <div className="cost-monitor-highlights">
        <div><span>Allowance for operating costs</span><strong>{money(snapshot.operating_budget_ngn)}</strong><small>After company, referral and 5% profit provisions</small></div>
        <div><span>Provider charges recorded</span><strong>{money(snapshot.recorded_costs_ngn)}</strong><small>Known spend only; unrecorded bills may raise the total</small></div>
        <div><span>Estimated room left</span><strong>{money(snapshot.remaining_operating_budget_ngn)}</strong><small>{snapshot.remaining_operating_budget_ngn === null ? 'Cannot confirm the 5% margin yet' : 'Estimate; reconcile with provider invoices'}</small></div>
      </div>
      {snapshot.cost_settings && <p className="cost-monitor-quota">Estimated tracked provider costs today: <strong>{money(snapshot.estimated_tracked_cost_ngn)}</strong>. This is a partial forecast, not an invoice or confirmed profit. {snapshot.cost_settings.usd_to_ngn === null && 'Set USD to NGN below to include billable Google and paid Supabase costs. '}SMS usage, Supabase overages and untracked Google requests are not included.</p>}
      {snapshot.margin_warning && <div className="cost-monitor-warnings" role="alert"><strong>Profit margin warning</strong><p>{snapshot.margin_warning}</p><p>Review provider usage and recorded invoices before deciding to reduce optional routing work.</p></div>}
      <div className="cost-monitor-action">
        <div><strong>{snapshot.mode === 'economy' ? 'Savings mode is on' : 'Normal matching is on'}</strong><p>Savings mode checks fewer optional road routes for new jobs. Matching may take longer. GPS, paid deliveries, payments, refunds and tracking continue.</p></div>
        <button type="button" className="secondary-button" aria-pressed={snapshot.mode === 'economy'} disabled={modeBusy || stale} onClick={() => void changeMode()}>{modeBusy ? 'Saving...' : snapshot.mode === 'economy' ? 'Resume normal matching' : 'Reduce optional routing work'}</button>
      </div>
      <p className="cost-monitor-quota">Google Route Matrix: <strong>{number(snapshot.google_elements_today)} elements reserved today</strong>. The {number(snapshot.cost_settings?.google_free_monthly_elements ?? 10000)}-element free allowance resets monthly. After that, optional road checks use today's earned operating budget; the 5% profit target remains protected. Provider quotas can still limit requests.</p>
      {snapshot.warnings.length > 0 && <div className="cost-monitor-warnings" role="alert"><strong>Needs attention</strong><ul>{snapshot.warnings.map((warning, index) => <li key={`${index}:${warning}`}>{warning}</li>)}</ul></div>}
      {snapshot.data_gaps.length > 0 && <details className="cost-monitor-gaps"><summary>Cost data not connected yet</summary><p>Provider bills are not imported automatically. The amount above includes only charges entered here; it is not today's total bill.</p><ul>{snapshot.data_gaps.map((gap, index) => <li key={`${index}:${gap}`}>{gap}</li>)}</ul></details>}
      <details className="cost-monitor-details"><summary>How this allowance is calculated</summary>
        <p>Only collected charges from completed paid rides and retained cancellation fees count here. Unpaid bookings do not fund operating costs. A provider charge may fall on a different day from its delivery, so this daily view is an attention signal rather than exact per-job profit.</p>
        <dl>
          <div><dt>Completed paid rides</dt><dd>{number(snapshot.completed_paid_jobs)} | {money(snapshot.completed_revenue_ngn)}</dd></div>
          <div><dt>Retained cancellation fees</dt><dd>{money(snapshot.cancelled_retained_revenue_ngn)}</dd></div>
          <div><dt>Collected customer charges</dt><dd>{money(snapshot.collected_revenue_ngn)}</dd></div>
          <div><dt>Owed to logistics companies</dt><dd>{money(snapshot.partner_payable_ngn)}</dd></div>
          <div><dt>Other direct job costs</dt><dd>{money(snapshot.other_direct_cost_ngn)}</dd></div>
          <div><dt>Customer referral provision</dt><dd>{money(snapshot.customer_referral_ngn)}</dd></div>
          <div><dt>Partner referral provision</dt><dd>{money(snapshot.partner_referral_ngn)}</dd></div>
          <div><dt>Independent rider registration reserve</dt><dd>{money(snapshot.registration_referral_reserve_ngn)}</dd></div>
          <div><dt>Left before operating costs and profit</dt><dd>{money(snapshot.available_for_operations_ngn)}</dd></div>
          <div><dt>5% target profit provision</dt><dd>{money(snapshot.target_profit_ngn)}</dd></div>
          <div><dt>Operating cost allowance</dt><dd>{money(snapshot.operating_budget_ngn)}</dd></div>
        </dl>
        <p>The independent rider registration reserve is a conservative allowance for a future program, not a payout already earned. Actual company and referral payouts may settle later than the ride. Avoid entering a provider charge already included in other direct job costs.</p>
        <h4>Cost evidence</h4>
        <dl>
          <div><dt>Provider charges entered</dt><dd>{money(snapshot.recorded_costs_ngn)}</dd></div>
          <div><dt>Google route estimate</dt><dd>{money(snapshot.modeled_costs.google_route_matrix_ngn)}</dd></div>
          <div><dt>Other Google API estimate</dt><dd>{money(snapshot.modeled_costs.google_other_apis_ngn)}</dd></div>
          <div><dt>Paystack payment-fee estimate</dt><dd>{money(snapshot.modeled_costs.paystack_ngn)}</dd></div>
          <div><dt>Supabase daily base-plan estimate</dt><dd>{money(snapshot.modeled_costs.supabase_ngn)}</dd></div>
          <div><dt>Known cost lower bound</dt><dd>{money(snapshot.known_cost_lower_bound_ngn)}</dd></div>
        </dl>
        <p>Estimates use the settings below and activity recorded by this app. Route Matrix reservations may exceed billable usage. Compute Routes counts saved road prices; browser Maps, Places and Geocoding counts are app-reported and may miss failed or unauthenticated requests. Google discounts above the first volume tier and usage from other projects are not modeled. Supabase overages and SMS usage are not yet measured. Entered charges are invoices or fees; do not add estimates to them as if they were separate bills.</p>
      </details>
      {settings && <details className="cost-monitor-details"><summary>Configure cost estimates</summary>
        <p>Choose your Supabase plan and the Google Routes SKU used by the app. Supabase sets its base subscription price from the plan. Google bills by request type; this app currently sends Essentials route checks. USD costs need an exchange rate. Compare forecasts with invoices.</p>
        <form className="cost-monitor-form" onSubmit={(event) => void saveSettings(event)}>
          <label>Supabase plan<select value={settings.supabase_plan} onChange={(event) => { const plan = event.target.value as CostSettings['supabase_plan']; setSettings({ ...settings, supabase_plan: plan, supabase_monthly_usd: plan === 'free' ? 0 : plan === 'pro' ? 25 : plan === 'team' ? 599 : 0 }) }}><option value="free">Free</option><option value="pro">Pro</option><option value="team">Team</option><option value="enterprise">Enterprise</option></select></label>
          {settings.supabase_plan === 'enterprise' && <label>Enterprise contract USD/month<input type="number" min="0" step="0.01" value={settings.supabase_monthly_usd} onChange={(event) => setSettings({ ...settings, supabase_monthly_usd: Number(event.target.value) })} /></label>}
          <label>Google Routes SKU<select value={settings.google_route_sku} onChange={(event) => { const sku = event.target.value as CostSettings['google_route_sku']; setSettings({ ...settings, google_route_sku: sku, google_free_monthly_elements: sku === 'enterprise' ? 1000 : sku === 'pro' ? 5000 : 10000, google_usd_per_1000: sku === 'enterprise' ? 15 : sku === 'pro' ? 10 : 5 }) }}><option value="essentials">Essentials</option><option value="pro">Pro</option><option value="enterprise">Enterprise</option></select></label>
          <label>Google free elements/month<input type="number" min="0" step="1" value={settings.google_free_monthly_elements} onChange={(event) => setSettings({ ...settings, google_free_monthly_elements: Number(event.target.value) })} /></label>
          <label>Google USD / 1,000 elements<input type="number" min="0" step="0.0001" value={settings.google_usd_per_1000} onChange={(event) => setSettings({ ...settings, google_usd_per_1000: Number(event.target.value) })} /></label>
          <label>USD to NGN<input type="number" min="0.0001" step="0.0001" placeholder="Set current rate" value={settings.usd_to_ngn ?? ''} onChange={(event) => setSettings({ ...settings, usd_to_ngn: event.target.value ? Number(event.target.value) : null })} /></label>
          <button type="button" className="secondary-button" disabled={fxBusy || settingsBusy} onClick={() => void refreshExchangeRate()}>{fxBusy ? 'Updating rate...' : 'Update USD/NGN rate'}</button>
          <label>Paystack local fee %<input type="number" min="0" max="100" step="0.0001" value={settings.paystack_percent} onChange={(event) => setSettings({ ...settings, paystack_percent: Number(event.target.value) })} /></label>
          <label>Paystack flat fee NGN<input type="number" min="0" step="0.01" value={settings.paystack_flat_ngn} onChange={(event) => setSettings({ ...settings, paystack_flat_ngn: Number(event.target.value) })} /></label>
          <label>Flat-fee waiver below NGN<input type="number" min="0" step="0.01" value={settings.paystack_flat_waiver_below_ngn} onChange={(event) => setSettings({ ...settings, paystack_flat_waiver_below_ngn: Number(event.target.value) })} /></label>
          <label>Paystack fee cap NGN<input type="number" min="0" step="0.01" value={settings.paystack_fee_cap_ngn} onChange={(event) => setSettings({ ...settings, paystack_fee_cap_ngn: Number(event.target.value) })} /></label>
          <label>SMS NGN/message<input type="number" min="0" step="0.01" placeholder="Provider rate" value={settings.sms_ngn_per_message ?? ''} onChange={(event) => setSettings({ ...settings, sms_ngn_per_message: event.target.value ? Number(event.target.value) : null })} /></label>
          <button type="submit" className="secondary-button" disabled={settingsBusy}>{settingsBusy ? 'Saving...' : 'Save cost assumptions'}</button>
        </form>
        {settingsNotice && <p role="status">{settingsNotice}</p>}
        <p>Exchange-rate data by <a href="https://www.exchangerate-api.com" target="_blank" rel="noreferrer">Exchange Rate API</a>; updated daily. It is an estimate, not your bank's settlement rate.</p>
        <div className="cost-plan-rates">
          <strong>Supabase {settings.supabase_plan} plan: {settings.supabase_plan === 'enterprise' ? 'contract pricing' : `$${settings.supabase_monthly_usd}/month base`}</strong>
          {databaseBytes !== null && <p>Current project database: {(databaseBytes / 1_000_000_000).toFixed(2)} GB. {settings.supabase_plan === 'enterprise' ? 'Compare with your contract.' : `Included size: ${settings.supabase_plan === 'free' ? '0.5' : '8'} GB per project.`} {settings.supabase_plan === 'free' && databaseBytes > 500_000_000 ? 'Above the Free allowance; Supabase may restrict service rather than charge an overage. ' : ''}{diskOverageRunRateUsd !== null && `Database-size overage at this instant: $${diskOverageRunRateUsd.toFixed(2)}/month run rate. `}Supabase bills using its own cycle measurements; this snapshot is not an invoice.</p>}
          <div className="cost-rate-table-wrap"><table><thead><tr><th>Supabase service</th><th>Included</th><th>After included usage</th></tr></thead><tbody>{supabaseRates.map((item) => <tr key={item.service}><td>{item.service}</td><td>{settings.supabase_plan === 'enterprise' ? 'Contract' : settings.supabase_plan === 'free' ? item.free : item.paid}</td><td>{settings.supabase_plan === 'enterprise' ? 'Contract' : settings.supabase_plan === 'free' ? 'No paid overage; service limits may apply' : item.overage}</td></tr>)}</tbody></table></div>
          <p>Usage is billed across your Supabase organization and billing cycle. The app cannot read authoritative egress, Auth, Edge, Realtime, storage or invoice totals from the database. This table shows published rates, not charges already incurred. Compute and optional add-ons cost extra; the base subscription is not a complete invoice.</p>
          <a href="https://supabase.com/dashboard/org/_/usage" target="_blank" rel="noreferrer">Open Supabase organization usage</a>
        </div>
      </details>}
      <details className="cost-monitor-details"><summary>Record a provider charge</summary>
        <p>Use an invoice or provider transaction reference once. This improves the day's cost picture; it does not move money.</p>
        <form className="cost-monitor-form" onSubmit={(event) => void recordCharge(event)}>
          <label>Provider<select value={source} onChange={(event) => setSource(event.target.value as CostSource)}>{sources.map((item) => <option key={item.value} value={item.value}>{item.label}</option>)}</select></label>
          <label>Amount (NGN)<input type="number" min="0.01" step="0.01" required value={amount} onChange={(event) => setAmount(event.target.value)} /></label>
          <label>Charge day (UTC)<input type="date" required value={costDay} onChange={(event) => setCostDay(event.target.value)} /></label>
          <label>Provider reference<input required maxLength={160} value={reference} onChange={(event) => setReference(event.target.value)} /></label>
          <label className="cost-monitor-note">Note (optional)<input maxLength={300} value={note} onChange={(event) => setNote(event.target.value)} /></label>
          <button type="submit" className="secondary-button" disabled={entryBusy}>{entryBusy ? 'Recording...' : 'Record charge'}</button>
        </form>
        {entryNotice && <p className="cost-monitor-entry-notice" role="status">{entryNotice}</p>}
      </details>
    </>}
  </div>
}
