import { useCallback, useEffect, useState, type FormEvent } from 'react'
import type { getSupabaseClient } from './lib/supabase'

type Client = ReturnType<typeof getSupabaseClient>
type StaffProfile = { user_id: string; full_name: string | null; email: string | null }
type Plan = {
  id: string; bdo_id: string; version: number; basis: string; rate: number | null
  fixed_amount_ngn: number | null; terms: Record<string, unknown>; effective_from: string
  effective_until: string | null; created_at: string
}

const SUPPORTED_BASES = ['collected_revenue', 'contribution', 'fixed_transaction'] as const

export function CommissionPlansPanel({ supabase, canManage, onError, onNotice }: {
  supabase: Client
  canManage: boolean
  onError: (message: string) => void
  onNotice: (message: string) => void
}) {
  const [staff, setStaff] = useState<StaffProfile[]>([])
  const [plans, setPlans] = useState<Plan[]>([])
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)

  const load = useCallback(async () => {
    setLoading(true)
    const [roleResult, plansResult] = await Promise.all([
      supabase.from('user_roles').select('user_id').eq('role', 'bdo'),
      supabase.from('commission_plans').select('id,bdo_id,version,basis,rate,fixed_amount_ngn,terms,effective_from,effective_until,created_at').order('created_at', { ascending: false }).limit(200),
    ])
    const roleError = roleResult.error
    if (roleError || plansResult.error) {
      onError((roleError ?? plansResult.error)?.message ?? 'Could not load commission plans.')
      setStaff([])
      setPlans([])
      setLoading(false)
      return
    }
    const bdoIds = [...new Set((roleResult.data ?? []).map((row) => row.user_id))]
    const profileResult = bdoIds.length
      ? await supabase.from('profiles').select('user_id,full_name,email').in('user_id', bdoIds)
      : { data: [], error: null }
    if (profileResult.error) {
      onError(profileResult.error.message)
      setStaff([])
      setPlans([])
    } else {
      setStaff((profileResult.data ?? []) as StaffProfile[])
      setPlans((plansResult.data ?? []) as Plan[])
    }
    setLoading(false)
  }, [onError, supabase])

  useEffect(() => {
    const timer = window.setTimeout(() => { void load() }, 0)
    return () => window.clearTimeout(timer)
  }, [load])

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!canManage || saving) return
    const formElement = event.currentTarget
    const form = new FormData(formElement)
    const basis = String(form.get('basis'))
    const rateText = String(form.get('rate') ?? '').trim()
    const fixedText = String(form.get('fixed_amount_ngn') ?? '').trim()
    const serviceCodes = form.getAll('eligible_service_codes').map(String)
    const agreement = String(form.get('agreement_reference') ?? '').trim()
    const reason = String(form.get('approval_reason') ?? '').trim()
    if (!SUPPORTED_BASES.includes(basis as typeof SUPPORTED_BASES[number])) return
    if (!agreement || !reason || serviceCodes.length === 0) {
      onError('Enter the signed agreement reference, approval reason, and at least one eligible service.')
      return
    }
    if ((basis === 'collected_revenue' || basis === 'contribution') && (!rateText || Number(rateText) < 0 || Number(rateText) > 100)) {
      onError('Enter a percentage rate from 0 to 100 for this calculation basis.')
      return
    }
    if (basis === 'fixed_transaction' && (!fixedText || Number(fixedText) < 0)) {
      onError('Enter a non-negative fixed amount for each eligible transaction.')
      return
    }
    setSaving(true)
    onError('')
    const result = await supabase.rpc('approve_commission_plan', {
      p_bdo_id: String(form.get('bdo_id')),
      p_basis: basis,
      p_rate: basis === 'collected_revenue' || basis === 'contribution' ? Number(rateText) / 100 : null,
      p_fixed_amount_ngn: basis === 'fixed_transaction' ? Number(fixedText) : null,
      p_terms: { agreement_reference: agreement, eligible_service_codes: serviceCodes },
      p_effective_from: String(form.get('effective_from')),
      p_reason: reason,
    })
    if (result.error) onError(result.error.message)
    else {
      onNotice('Commission plan approved and saved with its effective date.')
      formElement.reset()
      await load()
    }
    setSaving(false)
  }

  const personName = (id: string) => {
    const person = staff.find((item) => item.user_id === id)
    return person?.full_name || person?.email || id
  }

  return <section className="form-card commission-plans" aria-label="Commission plan management">
    <div className="commission-plans-heading"><div><p className="eyebrow">BDO COMPENSATION</p><h2>Approved commission plans</h2><p className="finance-form-note">Plans require a signed agreement and explicit eligible services. Automatic accrual currently supports collected-revenue plans on completed NGN local or interstate quote deliveries only. Approval does not create a commission or payout by itself.</p></div><button type="button" className="secondary-button" onClick={() => void load()} disabled={loading}>Refresh plans</button></div>
    {canManage && <form className="finance-form" onSubmit={(event) => void submit(event)}>
      <h3>Approve a new plan</h3>
      <div className="finance-field-grid">
        <label className="field"><span>BDO</span><select name="bdo_id" required defaultValue=""><option value="" disabled>Select an approved BDO</option>{staff.map((person) => <option key={person.user_id} value={person.user_id}>{person.full_name || person.email || person.user_id}</option>)}</select></label>
        <label className="field"><span>Calculation basis</span><select name="basis" defaultValue="collected_revenue"><option value="collected_revenue">Collected customer revenue</option><option value="contribution">Recorded contribution</option><option value="fixed_transaction">Fixed amount per eligible transaction</option></select></label>
        <label className="field"><span>Rate (%)</span><input name="rate" type="number" min="0" max="100" step="0.01" placeholder="Required for percentage plans" /></label>
        <label className="field"><span>Fixed amount (NGN)</span><input name="fixed_amount_ngn" type="number" min="0" step="0.01" placeholder="Required for fixed plans" /></label>
        <label className="field"><span>Effective from</span><input name="effective_from" type="date" min={new Date().toISOString().slice(0, 10)} required defaultValue={new Date().toISOString().slice(0, 10)} /></label>
        <label className="field"><span>Signed agreement reference</span><input name="agreement_reference" required maxLength={120} /></label>
      </div>
      <fieldset className="commission-service-list"><legend>Eligible service categories</legend><label><input type="checkbox" name="eligible_service_codes" value="SRV-0001" /> Local delivery</label><label><input type="checkbox" name="eligible_service_codes" value="SRV-0002" /> Interstate delivery</label><p className="finance-form-note">Other service types stay excluded until their commission basis is explicitly configured.</p></fieldset>
      <label className="field"><span>Approval reason</span><textarea name="approval_reason" rows={2} required maxLength={500} /></label>
      <button className="secondary-button" disabled={saving || !canManage}>{saving ? 'Saving plan…' : 'Approve plan'}</button>
    </form>}
    {loading ? <p className="finance-empty">Loading commission plans…</p> : plans.length === 0 ? <p className="finance-empty">No approved plans recorded.</p> : <div className="commission-plan-list">{plans.map((plan) => <article key={plan.id} className="commission-plan-row"><div><strong>{personName(plan.bdo_id)} · v{plan.version}</strong><p>{plan.basis.replaceAll('_', ' ')}{plan.rate != null ? ` · ${(Number(plan.rate) * 100).toFixed(2)}%` : ''}{plan.fixed_amount_ngn != null ? ` · ₦${Number(plan.fixed_amount_ngn).toLocaleString('en-NG')}` : ''}</p><small>Agreement {String(plan.terms?.agreement_reference ?? 'not recorded')} · Effective {plan.effective_from}{plan.effective_until ? ` to ${plan.effective_until}` : ' onward'}</small><small>Eligible: {Array.isArray(plan.terms?.eligible_service_codes) ? (plan.terms.eligible_service_codes as string[]).join(', ') : 'services not specified'}</small></div><span className={`finance-status ${plan.effective_until ? 'finance-status-cancelled' : 'finance-status-paid'}`}>{plan.effective_until ? 'superseded' : 'current'}</span></article>)}</div>}
  </section>
}
