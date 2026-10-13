import { useCallback, useEffect, useState, type FormEvent } from 'react'
import type { getSupabaseClient } from './lib/supabase'

type Client = ReturnType<typeof getSupabaseClient>
type Person = { user_id: string; full_name: string | null; email: string | null }
type Plan = { id: string; marketer_user_id: string; version: number; rate: number; terms: Record<string, unknown>; effective_from: string; effective_until: string | null }

export function MarketerCommissionPlansPanel({ supabase, canManage, onError, onNotice }: {
  supabase: Client; canManage: boolean; onError: (message: string) => void; onNotice: (message: string) => void
}) {
  const [people, setPeople] = useState<Person[]>([])
  const [plans, setPlans] = useState<Plan[]>([])
  const [saving, setSaving] = useState(false)
  const [loading, setLoading] = useState(true)
  const load = useCallback(async () => {
    setLoading(true)
    const [roles, saved] = await Promise.all([
      supabase.from('user_roles').select('user_id').eq('role', 'marketer'),
      supabase.from('marketer_commission_plans').select('id,marketer_user_id,version,rate,terms,effective_from,effective_until').order('created_at', { ascending: false }).limit(200),
    ])
    if (roles.error || saved.error) { onError((roles.error ?? saved.error)?.message ?? 'Could not load marketer commission plans.'); setLoading(false); return }
    const ids = [...new Set((roles.data ?? []).map((row) => row.user_id))]
    const profiles = ids.length ? await supabase.from('profiles').select('user_id,full_name,email').in('user_id', ids) : { data: [], error: null }
    if (profiles.error) onError(profiles.error.message)
    else setPeople((profiles.data ?? []) as Person[])
    setPlans((saved.data ?? []) as Plan[])
    setLoading(false)
  }, [onError, supabase])

  useEffect(() => { const timer = window.setTimeout(() => { void load() }, 0); return () => window.clearTimeout(timer) }, [load])

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!canManage || saving) return
    const formElement = event.currentTarget
    const form = new FormData(formElement)
    const agreement = String(form.get('agreement_reference') ?? '').trim()
    const reason = String(form.get('approval_reason') ?? '').trim()
    const services = form.getAll('eligible_service_codes').map(String)
    const rate = Number(form.get('rate'))
    if (!agreement || !reason || !services.length || rate < 0 || rate > 100) { onError('Add a signed agreement, approval reason, eligible service and rate from 0 to 100%.'); return }
    setSaving(true)
    const result = await supabase.rpc('approve_marketer_commission_plan', {
      p_marketer_user_id: String(form.get('marketer_user_id')), p_rate: rate / 100,
      p_terms: { agreement_reference: agreement, eligible_service_codes: services },
      p_effective_from: String(form.get('effective_from')), p_reason: reason,
    })
    if (result.error) onError(result.error.message)
    else { onNotice('Marketer commission plan approved.'); formElement.reset(); await load() }
    setSaving(false)
  }

  const name = (id: string) => { const p = people.find((item) => item.user_id === id); return p?.full_name || p?.email || id }
  return <section className="form-card commission-plans" aria-label="Marketer commission plan management">
    <div className="commission-plans-heading"><div><p className="eyebrow">MARKETER COMPENSATION</p><h2>Approved marketer plans</h2><p className="finance-form-note">Marketer earnings require an active BDO relationship and a signed, service-specific plan. This plan is separate from the supervising BDO commission.</p></div><button type="button" className="secondary-button" onClick={() => void load()} disabled={loading}>Refresh plans</button></div>
    {canManage && <form className="finance-form" onSubmit={(event) => void submit(event)}>
      <h3>Approve a signed marketer plan</h3><div className="finance-field-grid">
        <label className="field"><span>Marketer</span><select name="marketer_user_id" required defaultValue=""><option value="" disabled>Select marketer</option>{people.map((p) => <option key={p.user_id} value={p.user_id}>{p.full_name || p.email || p.user_id}</option>)}</select></label>
        <label className="field"><span>Commission rate (%)</span><input name="rate" type="number" min="0" max="100" step="0.01" required /></label>
        <label className="field"><span>Effective from</span><input name="effective_from" type="date" min={new Date().toISOString().slice(0, 10)} defaultValue={new Date().toISOString().slice(0, 10)} required /></label>
        <label className="field"><span>Signed agreement reference</span><input name="agreement_reference" maxLength={120} required /></label>
      </div><fieldset className="commission-service-list"><legend>Eligible service categories</legend><label><input type="checkbox" name="eligible_service_codes" value="SRV-0001" /> Local delivery</label><label><input type="checkbox" name="eligible_service_codes" value="SRV-0002" /> Interstate delivery</label></fieldset>
      <label className="field"><span>Approval reason</span><textarea name="approval_reason" rows={2} maxLength={500} required /></label>
      <button className="secondary-button" disabled={saving}>{saving ? 'Saving plan...' : 'Approve marketer plan'}</button>
    </form>}
    {loading ? <p className="finance-empty">Loading marketer plans...</p> : plans.length === 0 ? <p className="finance-empty">No approved marketer plans recorded.</p> : <div className="commission-plan-list">{plans.map((plan) => <article className="commission-plan-row" key={plan.id}><div><strong>{name(plan.marketer_user_id)} · v{plan.version}</strong><p>{(Number(plan.rate) * 100).toFixed(2)}% of eligible receipts</p><small>Agreement {String(plan.terms.agreement_reference ?? 'not recorded')} · Effective {plan.effective_from}{plan.effective_until ? ` to ${plan.effective_until}` : ' onward'}</small></div><span className={`finance-status ${plan.effective_until ? 'finance-status-cancelled' : 'finance-status-paid'}`}>{plan.effective_until ? 'superseded' : 'current'}</span></article>)}</div>}
  </section>
}
