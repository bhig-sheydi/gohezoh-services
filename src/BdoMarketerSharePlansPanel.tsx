import { useCallback, useEffect, useState, type FormEvent } from 'react'
import type { getSupabaseClient } from './lib/supabase'
type Client = ReturnType<typeof getSupabaseClient>
type Person = { user_id: string; full_name: string | null; email: string | null }
type Plan = { id: string; bdo_user_id: string; version: number; contribution_rate: number; terms: Record<string, unknown>; effective_from: string; effective_until: string | null }

export function BdoMarketerSharePlansPanel({ supabase, canManage, onError, onNotice }: { supabase: Client; canManage: boolean; onError: (message: string) => void; onNotice: (message: string) => void }) {
  const [bdos, setBdos] = useState<Person[]>([])
  const [plans, setPlans] = useState<Plan[]>([])
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const load = useCallback(async () => {
    setLoading(true)
    const [roles, saved] = await Promise.all([
      supabase.from('user_roles').select('user_id').eq('role', 'bdo'),
      supabase.from('bdo_marketer_share_plans').select('id,bdo_user_id,version,contribution_rate,terms,effective_from,effective_until').order('created_at', { ascending: false }).limit(200),
    ])
    if (roles.error || saved.error) { onError((roles.error ?? saved.error)?.message ?? 'Could not load BDO marketer-share plans.'); setLoading(false); return }
    const ids = [...new Set((roles.data ?? []).map((row) => row.user_id))]
    const profileResult = ids.length ? await supabase.from('profiles').select('user_id,full_name,email').in('user_id', ids) : { data: [], error: null }
    if (profileResult.error) onError(profileResult.error.message)
    else setBdos((profileResult.data ?? []) as Person[])
    setPlans((saved.data ?? []) as Plan[])
    setLoading(false)
  }, [onError, supabase])
  useEffect(() => { const timer = window.setTimeout(() => { void load() }, 0); return () => window.clearTimeout(timer) }, [load])

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!canManage || saving) return
    const formElement = event.currentTarget
    const form = new FormData(formElement)
    const rate = Number(form.get('rate'))
    const agreement = String(form.get('agreement_reference') ?? '').trim()
    const reason = String(form.get('approval_reason') ?? '').trim()
    const services = form.getAll('eligible_service_codes').map(String)
    if (rate < 0 || rate > 100 || !agreement || !reason || !services.length) { onError('Enter a valid rate, signed agreement, approval reason and eligible services.'); return }
    setSaving(true)
    const result = await supabase.rpc('approve_bdo_marketer_share_plan', {
      p_bdo_user_id: String(form.get('bdo_user_id')), p_contribution_rate: rate / 100,
      p_terms: { agreement_reference: agreement, eligible_service_codes: services },
      p_effective_from: String(form.get('effective_from')), p_reason: reason,
    })
    if (result.error) onError(result.error.message)
    else { onNotice('Supervising BDO share plan approved.'); formElement.reset(); await load() }
    setSaving(false)
  }

  const displayName = (id: string) => { const p = bdos.find((person) => person.user_id === id); return p?.full_name || p?.email || id }
  return <section className="form-card commission-plans" aria-label="BDO marketer share plan management">
    <div className="commission-plans-heading"><div><p className="eyebrow">BDO NETWORK SHARE</p><h2>Approved supervising BDO plans</h2><p className="finance-form-note">This rate applies to the accepted quote’s recorded contribution, prorated across the BDO’s actual eligible receipts. It is separate from direct-BDO and marketer rates.</p></div><button type="button" className="secondary-button" onClick={() => void load()} disabled={loading}>Refresh plans</button></div>
    {canManage && <form className="finance-form" onSubmit={(event) => void submit(event)}><h3>Approve a BDO share plan</h3><div className="finance-field-grid">
      <label className="field"><span>Supervising BDO</span><select name="bdo_user_id" required defaultValue=""><option value="" disabled>Select approved BDO</option>{bdos.map((person) => <option key={person.user_id} value={person.user_id}>{person.full_name || person.email || person.user_id}</option>)}</select></label>
      <label className="field"><span>Rate of contribution (%)</span><input name="rate" type="number" min="0" max="100" step="0.01" required /></label>
      <label className="field"><span>Effective from</span><input name="effective_from" type="date" min={new Date().toISOString().slice(0, 10)} defaultValue={new Date().toISOString().slice(0, 10)} required /></label>
      <label className="field"><span>Signed agreement reference</span><input name="agreement_reference" maxLength={120} required /></label>
    </div><fieldset className="commission-service-list"><legend>Eligible service categories</legend><label><input type="checkbox" name="eligible_service_codes" value="SRV-0001" /> Local delivery</label><label><input type="checkbox" name="eligible_service_codes" value="SRV-0002" /> Interstate delivery</label></fieldset>
      <label className="field"><span>Approval reason</span><textarea name="approval_reason" rows={2} maxLength={500} required /></label><button className="secondary-button" disabled={saving}>{saving ? 'Saving plan...' : 'Approve BDO share plan'}</button>
    </form>}
    {loading ? <p className="finance-empty">Loading BDO share plans...</p> : plans.length === 0 ? <p className="finance-empty">No approved BDO share plans recorded.</p> : <div className="commission-plan-list">{plans.map((plan) => <article className="commission-plan-row" key={plan.id}><div><strong>{displayName(plan.bdo_user_id)} · v{plan.version}</strong><p>{(Number(plan.contribution_rate) * 100).toFixed(2)}% of eligible contribution</p><small>Agreement {String(plan.terms.agreement_reference ?? 'not recorded')} · Effective {plan.effective_from}{plan.effective_until ? ` to ${plan.effective_until}` : ' onward'}</small></div><span className={`finance-status ${plan.effective_until ? 'finance-status-cancelled' : 'finance-status-paid'}`}>{plan.effective_until ? 'superseded' : 'current'}</span></article>)}</div>}
  </section>
}
