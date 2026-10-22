import { useCallback, useEffect, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import './company-operations-staff.css'

type Staff = { id: string; full_name: string; can_bid: boolean; can_manage_riders: boolean; can_withdraw: boolean;
  password_revoked_at: string | null; revoked_at: string | null; company_operations_staff_devices?: Array<{ kind: string; label: string | null }> }
type Alert = { staff_id: string; message: string; created_at: string }
type Props = { supabase: SupabaseClient; partnerId: string; onError: (message: string) => void; onNotice: (message: string) => void }
const linkFor = (id: string) => `${window.location.origin}/company-staff#staff=${id}`

export default function CompanyOperationsStaffPanel({ supabase, partnerId, onError, onNotice }: Props) {
  const [staff, setStaff] = useState<Staff[]>([])
  const [alerts, setAlerts] = useState<Alert[]>([])
  const [busy, setBusy] = useState(false)
  const [secret, setSecret] = useState<{ name: string; password: string; link: string } | null>(null)
  const [open, setOpen] = useState(false)
  const request = useCallback(async (body: Record<string, unknown>) => {
    const { data, error } = await supabase.functions.invoke('company-staff-access', { body: { ...body, partnerId } })
    if (error) {
      if (error.context instanceof Response) {
        try { const detail = await error.context.clone().json() as { error?: string }; throw new Error(detail.error || error.message) }
        catch (cause) { if (cause instanceof Error && cause.message !== error.message) throw cause }
      }
      throw error
    }
    return data as Record<string, unknown>
  }, [partnerId, supabase])
  const refresh = useCallback(async () => {
    try { const result = await request({ action: 'list' }); setStaff((result.staff ?? []) as Staff[]); setAlerts((result.alerts ?? []) as Alert[]) }
    catch (cause) { onError(cause instanceof Error ? cause.message : 'Could not load operations staff') }
  }, [onError, request])
  useEffect(() => { const timer = window.setTimeout(() => { void refresh() }, 0); return () => window.clearTimeout(timer) }, [refresh])
  useEffect(() => { const timer = window.setInterval(() => { if (document.visibilityState === 'visible') void refresh() }, 30_000); return () => window.clearInterval(timer) }, [refresh])
  async function create(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); if (busy) return
    const formElement = event.currentTarget; const form = new FormData(formElement)
    setBusy(true); onError(''); setSecret(null)
    try {
      const result = await request({ action: 'create', fullName: String(form.get('name') ?? '').trim(),
        password: String(form.get('password') ?? '').trim() || undefined, canBid: form.has('bid'),
        canManageRiders: form.has('riders'), canWithdraw: form.has('withdraw') })
      setSecret({ name: String(form.get('name')), password: String(result.password), link: linkFor(String(result.staffId)) })
      formElement.reset(); setOpen(false); onNotice('Operations staff account created. Share its link and password privately.')
      await refresh()
    } catch (cause) { onError(cause instanceof Error ? cause.message : 'Could not create operations staff') }
    finally { setBusy(false) }
  }
  async function update(person: Staff, action: 'permissions' | 'reset' | 'remove', permissions?: Record<string, boolean | string>) {
    if (busy) return
    if (action === 'remove' && !window.confirm(`Remove ${person.full_name}? Their access will stop immediately.`)) return
    setBusy(true); onError(''); setSecret(null)
    try {
      const result = await request({ action, staffId: person.id, ...permissions })
      if (action === 'reset') setSecret({ name: person.full_name, password: String(result.password), link: linkFor(person.id) })
      onNotice(action === 'remove' ? `${person.full_name} removed.` : action === 'reset' ? 'New password ready. Both registered devices were cleared.' : 'Permissions saved. Existing staff sessions were signed out.')
      await refresh()
    } catch (cause) { onError(cause instanceof Error ? cause.message : 'Could not update staff access') }
    finally { setBusy(false) }
  }
  return <section className="form-card company-operations-staff-panel" aria-label="Operations staff">
    <div className="dashboard-heading"><div><p className="eyebrow">COMPANY ACCESS</p><h2>Operations staff</h2></div><button className="secondary-button" type="button" onClick={() => void refresh()}>Refresh</button></div>
    {alerts.map((alert) => <p className="company-staff-alert" role="alert" key={`${alert.staff_id}:${alert.created_at}`}>{alert.message}</p>)}
    <button className="secondary-button" type="button" onClick={() => setOpen((current) => !current)}>{open ? 'Cancel' : 'Add operations staff'}</button>
    {open && <form className="company-staff-form" onSubmit={(event) => void create(event)}>
      <label className="field"><span>Full name</span><input name="name" required minLength={3} maxLength={120} /></label>
      <label className="field"><span>Custom password (optional)</span><input name="password" type="text" minLength={12} maxLength={80} placeholder="Or generate a memorable password" /></label>
      <fieldset className="company-staff-permissions"><legend>Allowed actions</legend><label><input type="checkbox" name="bid" /> Place bids</label><label><input type="checkbox" name="riders" /> Manage riders</label><label><input type="checkbox" name="withdraw" /> Withdraw earnings</label></fieldset>
      <button className="primary-button" disabled={busy}>Create staff access</button>
    </form>}
    {secret && <div className="company-staff-secret" role="status"><strong>{secret.name}</strong><label className="field"><span>Private sign-in link</span><input readOnly value={secret.link} onFocus={(event) => event.currentTarget.select()} /></label><label className="field"><span>Password — shown once</span><input readOnly value={secret.password} onFocus={(event) => event.currentTarget.select()} /></label></div>}
    <div className="company-staff-grid">{staff.filter((person) => !person.revoked_at).map((person) => <StaffCard key={`${person.id}:${person.can_bid}:${person.can_manage_riders}:${person.can_withdraw}`} person={person} busy={busy} update={update} />)}</div>
  </section>
}
function StaffCard({ person, busy, update }: { person: Staff; busy: boolean; update: (person: Staff, action: 'permissions' | 'reset' | 'remove', permissions?: Record<string, boolean | string>) => Promise<void> }) {
  const [bid, setBid] = useState(person.can_bid); const [riders, setRiders] = useState(person.can_manage_riders); const [withdraw, setWithdraw] = useState(person.can_withdraw)
  const [password, setPassword] = useState('')
  return <article className="company-staff-card"><h3>{person.full_name}</h3>{person.password_revoked_at && <p role="alert">Password revoked after suspicious attempts. Set a new one.</p>}
    <p>Phone: {person.company_operations_staff_devices?.find((d) => d.kind === 'phone')?.label || 'Not registered'}<br />Laptop: {person.company_operations_staff_devices?.find((d) => d.kind === 'desktop')?.label || 'Not registered'}</p>
    <fieldset className="company-staff-permissions" disabled={busy}><legend>Permissions</legend><label><input type="checkbox" checked={bid} onChange={(event) => setBid(event.target.checked)} /> Place bids</label><label><input type="checkbox" checked={riders} onChange={(event) => setRiders(event.target.checked)} /> Manage riders</label><label><input type="checkbox" checked={withdraw} onChange={(event) => setWithdraw(event.target.checked)} /> Withdraw earnings</label></fieldset>
    <label className="field"><span>New custom password (optional)</span><input type="text" minLength={12} maxLength={80} value={password} onChange={(event) => setPassword(event.target.value)} placeholder="Or generate a memorable password" /></label>
    <div className="company-staff-actions"><button className="primary-button" disabled={busy || bid === person.can_bid && riders === person.can_manage_riders && withdraw === person.can_withdraw} onClick={() => void update(person, 'permissions', { canBid: bid, canManageRiders: riders, canWithdraw: withdraw })}>Save permissions</button><button className="secondary-button" disabled={busy} onClick={() => void update(person, 'reset', { password })}>Reset password & devices</button><button className="secondary-button finance-cancel" disabled={busy} onClick={() => void update(person, 'remove')}>Remove staff</button></div>
  </article>
}
