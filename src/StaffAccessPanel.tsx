import { useCallback, useEffect, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'

type Application = { id: string; requested_role: string; status: string; created_at: string }

export default function StaffAccessPanel({ supabase, userId, onError, onNotice }: {
  supabase: SupabaseClient; userId: string; onError: (message: string) => void; onNotice: (message: string) => void
}) {
  const [applications, setApplications] = useState<Application[]>([])
  const [busy, setBusy] = useState(false)
  const load = useCallback(async () => {
    const { data, error } = await supabase.from('staff_applications').select('id,requested_role,status,created_at').eq('user_id', userId).order('created_at', { ascending: false })
    if (error) onError(error.message)
    else setApplications((data ?? []) as Application[])
  }, [supabase, userId, onError])
  useEffect(() => { const timer = window.setTimeout(() => { void load() }, 0); return () => window.clearTimeout(timer) }, [load])

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const form = new FormData(event.currentTarget)
    setBusy(true); onError('')
    const { error } = await supabase.rpc('request_staff_access', {
      p_role: String(form.get('role')),
      p_organization_name: String(form.get('organization_name') ?? '').trim() || null,
    })
    if (error) onError(error.message)
    else { onNotice('Your request is awaiting Super Admin approval.'); await load() }
    setBusy(false)
  }

  const latest = applications[0]
  return <section className="form-card narrow"><p className="eyebrow">ACCOUNT ACCESS</p><h1>{latest?.status === 'pending' ? 'Staff access pending' : 'Request staff access'}</h1>
    {latest?.status === 'pending' ? <p className="section-intro">Your {latest.requested_role.replaceAll('_', ' ')} request is awaiting Super Admin review. Your email must be confirmed before approval.</p> : <p className="section-intro">Choose the category you need. A Super Admin must approve it before you can use that workspace.</p>}
    {applications.length > 0 && <div className="admin-list">{applications.map((application) => <p key={application.id}>{application.requested_role.replaceAll('_', ' ')}: {application.status}</p>)}</div>}
    {!latest || ['rejected','revoked'].includes(latest.status) ? <form className="form-grid" onSubmit={submit}><label className="field"><span>Requested category</span><select name="role" required><option value="operations">Operations</option><option value="warehouse">Warehouse</option><option value="finance">Finance</option><option value="bdo">Business Development</option><option value="partner">Logistics Partner</option><option value="management">Management</option></select></label><label className="field"><span>Organization or partner name</span><input name="organization_name" /></label><button className="primary-button" disabled={busy}>{busy ? 'Submitting...' : 'Request access'}</button></form> : null}
    <button className="secondary-button" onClick={() => void load()}>Refresh status</button>
  </section>
}
