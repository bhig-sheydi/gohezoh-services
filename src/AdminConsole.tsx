import { useCallback, useEffect, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'

type Application = {
  id: string; user_id: string; email: string; full_name: string | null;
  requested_role: string; organization_name: string | null; status: string;
  email_confirmed: boolean; created_at: string
}
type StaffAccess = { user_id: string; email: string; full_name: string | null; role: string; organization_name: string | null }
type Partner = { id: string; partner_name: string }

export default function AdminConsole({ supabase, onError, onNotice }: {
  supabase: SupabaseClient; onError: (message: string) => void; onNotice: (message: string) => void
}) {
  const [applications, setApplications] = useState<Application[]>([])
  const [staff, setStaff] = useState<StaffAccess[]>([])
  const [partners, setPartners] = useState<Partner[]>([])
  const [partnerSelection, setPartnerSelection] = useState<Record<string, string>>({})
  const [busy, setBusy] = useState('')
  const [loading, setLoading] = useState(true)

  const load = useCallback(async () => {
    setLoading(true)
    const [applicationResult, staffResult, partnerResult] = await Promise.all([
      supabase.rpc('list_staff_applications'),
      supabase.rpc('list_staff_access'),
      supabase.from('logistics_partners').select('id,partner_name').eq('status', 'active').order('partner_name'),
    ])
    if (applicationResult.error) onError(applicationResult.error.message)
    if (staffResult.error) onError(staffResult.error.message)
    if (partnerResult.error) onError(partnerResult.error.message)
    setApplications((applicationResult.data ?? []) as Application[])
    setStaff((staffResult.data ?? []) as StaffAccess[])
    setPartners((partnerResult.data ?? []) as Partner[])
    setLoading(false)
  }, [supabase, onError])

  useEffect(() => { const timer = window.setTimeout(() => { void load() }, 0); return () => window.clearTimeout(timer) }, [load])

  async function review(application: Application, approve: boolean) {
    const partnerId = application.requested_role === 'partner' ? partnerSelection[application.id] || null : null
    if (approve && application.requested_role === 'partner' && !partnerId) { onError('Select the partner company before approval.'); return }
    setBusy(application.id); onError('')
    const { error } = await supabase.rpc('review_staff_application', {
      p_application_id: application.id, p_approve: approve, p_partner_id: partnerId,
    })
    if (error) onError(error.message)
    else { onNotice(approve ? 'Access approved.' : 'Application rejected.'); await load() }
    setBusy('')
  }

  async function revoke(access: StaffAccess) {
    if (!window.confirm(`Revoke ${access.role} access for ${access.email}?`)) return
    setBusy(`${access.user_id}:${access.role}`); onError('')
    const { error } = await supabase.rpc('revoke_staff_access', { p_user_id: access.user_id, p_role: access.role })
    if (error) onError(error.message)
    else { onNotice('Access revoked immediately.'); await load() }
    setBusy('')
  }

  return <main className="dashboard admin-page">
    <div className="dashboard-heading"><div><p className="eyebrow">GOHEZOH SUPER ADMIN</p><h1>Access control</h1><p className="section-intro">Approve verified staff and partners, link partners to their company, and revoke access when needed.</p></div><button className="secondary-button" onClick={() => void load()} disabled={loading}>Refresh</button></div>
    <section className="form-card"><h2>Access requests</h2>{loading ? <p>Loading requests...</p> : applications.length === 0 ? <p>No requests yet.</p> : <div className="admin-list">{applications.map((application) => <article className="admin-row" key={application.id}><div><strong>{application.full_name || application.email}</strong><p>{application.email} · {application.requested_role.replaceAll('_', ' ')}{application.organization_name ? ` · ${application.organization_name}` : ''}</p><small>{application.email_confirmed ? 'Email confirmed' : 'Email not confirmed'} · {application.status}</small></div>{application.status === 'pending' && <div className="admin-actions">{application.requested_role === 'partner' && <select aria-label={`Partner company for ${application.email}`} value={partnerSelection[application.id] ?? ''} onChange={(event) => setPartnerSelection((current) => ({ ...current, [application.id]: event.target.value }))}><option value="">Select partner company</option>{partners.map((partner) => <option value={partner.id} key={partner.id}>{partner.partner_name}</option>)}</select>}<button className="primary-button" disabled={busy === application.id || !application.email_confirmed} onClick={() => void review(application, true)}>Approve</button><button className="secondary-button" disabled={busy === application.id} onClick={() => void review(application, false)}>Reject</button></div>}</article>)}</div>}</section>
    <section className="form-card"><h2>Active staff access</h2>{staff.length === 0 ? <p>No approved staff yet.</p> : <div className="admin-list">{staff.map((access) => <article className="admin-row" key={`${access.user_id}:${access.role}`}><div><strong>{access.full_name || access.email}</strong><p>{access.email} · {access.role.replaceAll('_', ' ')}{access.organization_name ? ` · ${access.organization_name}` : ''}</p></div><button className="secondary-button" disabled={busy === `${access.user_id}:${access.role}`} onClick={() => void revoke(access)}>Revoke access</button></article>)}</div>}</section>
  </main>
}
