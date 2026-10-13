import { useCallback, useEffect, useMemo, useState, type FormEvent } from 'react'
import type { getSupabaseClient } from './lib/supabase'
type Client = ReturnType<typeof getSupabaseClient>
type Entry = { entry_id: string; commission_type: 'direct_bdo' | 'marketer' | 'bdo_network_share'; recipient_user_id: string; recipient_name: string | null; recipient_email: string; job_number: string; amount_ngn: number; status: string; receipt_reference: string | null; payout_reference: string | null; reviewer_id: string | null; created_at: string; recovery_review_status: string; recovery_reviewer_id: string | null; offset_applied_ngn: number; recovery_eligible: boolean }
const labels: Record<Entry['commission_type'], string> = { direct_bdo: 'Direct BDO', marketer: 'Marketer', bdo_network_share: 'BDO network share' }
const money = (amount: number) => `NGN ${amount.toLocaleString('en-NG')}`

export function CommissionPayoutPanel({ supabase, userId, canReview, canPay, onError, onNotice }: {
  supabase: Client; userId: string; canReview: boolean; canPay: boolean; onError: (message: string) => void; onNotice: (message: string) => void
}) {
  const [entries, setEntries] = useState<Entry[]>([])
  const [selected, setSelected] = useState<string[]>([])
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const load = useCallback(async () => {
    setLoading(true)
    const result = await supabase.rpc('list_commission_work_queue')
    if (result.error) onError(result.error.message)
    else { setEntries((result.data ?? []) as Entry[]); setSelected([]) }
    setLoading(false)
  }, [onError, supabase])
  useEffect(() => { const timer = window.setTimeout(() => { void load() }, 0); return () => window.clearTimeout(timer) }, [load])
  const selectionEntries = entries.filter((entry) => selected.includes(entry.entry_id))
  const selectedTotal = selectionEntries.reduce((sum, entry) => sum + Number(entry.amount_ngn), 0)
  const selectionKey = selectionEntries.length ? `${selectionEntries[0].commission_type}:${selectionEntries[0].recipient_user_id}` : ''
  const recoveryOffset = selectionEntries.length ? Math.min(selectedTotal, entries.filter((entry) => entry.recovery_eligible && entry.status === 'adjusted' && Number(entry.amount_ngn) < 0
    && entry.recovery_review_status === 'approved' && entry.recovery_reviewer_id !== userId
    && entry.commission_type === selectionEntries[0].commission_type && entry.recipient_user_id === selectionEntries[0].recipient_user_id)
    .reduce((sum, entry) => sum + Math.max(0, Math.abs(Number(entry.amount_ngn)) - Number(entry.offset_applied_ngn || 0)), 0)) : 0
  const netPayout = selectedTotal - recoveryOffset
  const selectableEntries = useMemo(() => entries.filter((entry) => entry.status === 'approved' && Number(entry.amount_ngn) > 0 && entry.reviewer_id !== userId), [entries, userId])

  async function review(entry: Entry, approve: boolean) {
    if (!canReview || saving) return
    const reason = window.prompt(approve ? 'Reason for approving this commission:' : 'Reason for declining this commission:')
    if (!reason?.trim()) return
    setSaving(true)
    const result = await supabase.rpc('review_commission_entry', { p_commission_type: entry.commission_type, p_entry_id: entry.entry_id, p_approve: approve, p_reason: reason.trim() })
    if (result.error) onError(result.error.message)
    else { onNotice(approve ? 'Commission approved for payout.' : 'Commission declined and recorded.'); await load() }
    setSaving(false)
  }

  async function reviewRecovery(entry: Entry, approve: boolean) {
    if (!canReview || saving) return
    const reason = window.prompt(approve ? 'Reason for approving this future commission offset:' : 'Reason for declining this recovery offset:')
    if (!reason?.trim()) return
    setSaving(true)
    const result = await supabase.rpc('review_commission_recovery', { p_commission_type: entry.commission_type, p_entry_id: entry.entry_id, p_approve: approve, p_reason: reason.trim() })
    if (result.error) onError(result.error.message)
    else { onNotice(approve ? 'Future commission offset approved.' : 'Recovery offset declined and recorded.'); await load() }
    setSaving(false)
  }

  function toggle(entry: Entry) {
    if (selected.includes(entry.entry_id)) { setSelected((rows) => rows.filter((id) => id !== entry.entry_id)); return }
    if (selectionKey && selectionKey !== `${entry.commission_type}:${entry.recipient_user_id}`) return
    setSelected((rows) => [...rows, entry.entry_id])
  }

  async function recordPayout(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!canPay || !selected.length || saving || !selectionEntries.length) return
    const formElement = event.currentTarget
    const reference = String(new FormData(formElement).get('transfer_reference') ?? '').trim()
    if (selectionEntries.some((entry) => entry.reviewer_id === userId)) { onError('The reviewer cannot record this payout.'); return }
    setSaving(true)
    const result = await supabase.rpc('record_commission_payout', { p_commission_type: selectionEntries[0].commission_type, p_entry_ids: selected, p_transfer_reference: reference })
    if (result.error) onError(result.error.message)
    else { onNotice(netPayout > 0 ? `${money(netPayout)} payout recorded after a ${money(recoveryOffset)} offset.` : `${money(recoveryOffset)} offset applied; no bank transfer was due.`); formElement.reset(); await load() }
    setSaving(false)
  }

  return <section className="form-card commission-plans" aria-label="Commission review and payout">
    <div className="commission-plans-heading"><div><p className="eyebrow">COMMISSION CONTROL</p><h2>Review and payout queue</h2><p className="finance-form-note">Management/Admin reviews commissions and approves recovery offsets. Finance records actual transfers. Future offsets require a separate reviewer.</p></div><button type="button" className="secondary-button" onClick={() => void load()} disabled={loading}>Refresh queue</button></div>
    {loading ? <p className="finance-empty">Loading commission queue...</p> : entries.length === 0 ? <p className="finance-empty">No commission entries have been calculated.</p> : <div className="finance-record-list">{entries.map((entry) => {
      const canSelect = selectableEntries.some((candidate) => candidate.entry_id === entry.entry_id)
      const incompatible = Boolean(selectionKey && selectionKey !== `${entry.commission_type}:${entry.recipient_user_id}`)
      const isRecovery = entry.recovery_eligible && entry.status === 'adjusted' && Number(entry.amount_ngn) < 0
      return <article className="commission-plan-row" key={`${entry.commission_type}:${entry.entry_id}`}>
        <div>{canSelect && canPay && <label><input type="checkbox" aria-label={`Select ${labels[entry.commission_type]} commission for job ${entry.job_number}`} checked={selected.includes(entry.entry_id)} disabled={incompatible || saving} onChange={() => toggle(entry)} /> Select for payout</label>}
          <strong>{labels[entry.commission_type]} / Job {entry.job_number}</strong><p>{entry.recipient_name || entry.recipient_email} / {money(Number(entry.amount_ngn))} / {entry.status.replaceAll('_', ' ')}</p><small>{entry.receipt_reference ? `Receipt ${entry.receipt_reference} / ` : ''}{new Date(entry.created_at).toLocaleDateString('en-NG')}{entry.payout_reference ? ` / Transfer ${entry.payout_reference}` : ''}{isRecovery ? ` / Offset applied ${money(Number(entry.offset_applied_ngn || 0))} / recovery ${entry.recovery_review_status}` : ''}</small></div>
        {canReview && ['calculated', 'under_review'].includes(entry.status) && <div className="field-row"><button className="secondary-button" disabled={saving} onClick={() => void review(entry, true)}>Approve</button><button className="secondary-button finance-cancel" disabled={saving} onClick={() => void review(entry, false)}>Decline</button></div>}
        {canReview && isRecovery && entry.recovery_review_status !== 'approved' && <div className="field-row"><button className="secondary-button" disabled={saving} onClick={() => void reviewRecovery(entry, true)}>Approve offset</button><button className="secondary-button finance-cancel" disabled={saving} onClick={() => void reviewRecovery(entry, false)}>Decline recovery</button></div>}
      </article>
    })}</div>}
    {canPay && selected.length > 0 && <form className="finance-form" onSubmit={(event) => void recordPayout(event)}><h3>{netPayout > 0 ? 'Record payout and offset' : 'Apply approved commission offset'}</h3><p className="finance-form-note">{selectionEntries.length} approved entries / Gross {money(selectedTotal)} / Offset {money(recoveryOffset)} / {netPayout > 0 ? `Cash transfer ${money(netPayout)}` : 'No cash transfer due'} / {labels[selectionEntries[0]!.commission_type]}</p>{netPayout > 0 && <label className="field"><span>Actual transfer reference</span><input name="transfer_reference" required minLength={3} maxLength={160} /></label>}<button className="secondary-button" disabled={saving}>{saving ? 'Recording...' : netPayout > 0 ? 'Record payout as paid' : 'Record offset settlement'}</button></form>}
  </section>
}
