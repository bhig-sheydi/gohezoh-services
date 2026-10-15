import { useCallback, useEffect, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import AdminQuotePricingPanel from './AdminQuotePricingPanel'
import CoverageAdminPanel from './CoverageAdminPanel'
import PartnerVehicleRegistration from './PartnerVehicleRegistration'
import DocumentPreview, { type PreviewDocument } from './DocumentPreview'

type Application = {
  id: string; user_id: string; email: string; full_name: string | null;
  requested_role: string; organization_name: string | null; status: string;
  email_confirmed: boolean; created_at: string; partner_document_type?: string | null; partner_document_path?: string | null; invited_partner_id?: string | null; invited_partner_name?: string | null; partner_prospect_id?: string | null; rejection_reason?: string | null
}
type StaffAccess = { user_id: string; email: string; full_name: string | null; role: string; organization_name: string | null }

export default function AdminConsole({ supabase, onError, onNotice }: {
  supabase: SupabaseClient; onError: (message: string) => void; onNotice: (message: string) => void
}) {
  const [applications, setApplications] = useState<Application[]>([])
  const [staff, setStaff] = useState<StaffAccess[]>([])
  const [preview, setPreview] = useState<PreviewDocument | null>(null)
  const [reasons, setReasons] = useState<Record<string, string>>({})
  const [rejecting, setRejecting] = useState<string | null>(null)
  const [busy, setBusy] = useState('')
  const [loading, setLoading] = useState(true)

  const load = useCallback(async () => {
    setLoading(true)
    const [applicationResult, staffResult, documentResult] = await Promise.all([
      supabase.rpc('list_staff_applications'),
      supabase.rpc('list_staff_access'),
      supabase.from('staff_applications').select('id,partner_document_type,partner_document_path,rejection_reason'),
    ])
    if (applicationResult.error) onError(applicationResult.error.message)
    if (staffResult.error) onError(staffResult.error.message)
    if (documentResult.error) onError(documentResult.error.message)
    const documents = new Map((documentResult.data ?? []).map((item) => [item.id, item]))
    const rows = ((applicationResult.data ?? []) as Application[]).map((application) => ({ ...application, ...documents.get(application.id) }))
    setApplications(rows)
    setStaff((staffResult.data ?? []) as StaffAccess[])
    setLoading(false)
  }, [supabase, onError])

  useEffect(() => { const timer = window.setTimeout(() => { void load() }, 0); return () => window.clearTimeout(timer) }, [load])

  async function review(application: Application, approve: boolean) {
    const reason = reasons[application.id]?.trim() ?? ''
    if (!approve && reason.length < 3) { onError('Enter a rejection reason.'); return }
    setBusy(application.id); onError('')
    const { error } = await supabase.rpc('review_staff_application', {
      p_application_id: application.id, p_approve: approve, p_partner_id: null, ...(!approve ? { p_rejection_reason: reason } : {}),
    })
    if (error) onError(error.message)
    else { setRejecting(null); onNotice(approve ? 'Access approved.' : 'Application rejected. The reason is visible to the applicant.'); await load() }
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
    <div className="dashboard-heading"><div><p className="eyebrow">KWIK-PARSEL SUPER ADMIN</p><h1>Access control</h1><p className="section-intro">Approve verified staff and partners, link partners to their company, and revoke access when needed.</p></div><button className="secondary-button" onClick={() => void load()} disabled={loading}>Refresh</button></div>
    <AdminQuotePricingPanel supabase={supabase} onError={onError} onNotice={onNotice} />
    <CoverageAdminPanel supabase={supabase} onError={onError} onNotice={onNotice} />
    <section className="form-card"><h2>Access requests</h2>{loading ? <p>Loading requests...</p> : applications.length === 0 ? <p>No requests yet.</p> : <div className="admin-list">{applications.map((application) => <article className="company-review-card" key={application.id} aria-label={application.organization_name || application.full_name || application.email}>
      <header><h3>{application.organization_name || application.full_name || application.email}</h3><span>{application.status}</span></header>
      <p>{application.full_name || application.email} - {application.email}</p>
      <small>{application.requested_role.replaceAll('_', ' ')} - {application.email_confirmed ? 'Email confirmed' : 'Email not confirmed'}</small>
      {application.invited_partner_name && <p>Joining {application.invited_partner_name}</p>}
      {application.rejection_reason && <p className="application-rejection"><strong>Rejection reason:</strong> {application.rejection_reason}</p>}
      {application.requested_role === 'partner' && <section><h4>Business verification</h4>{application.partner_document_path ? <button className="secondary-button" type="button" onClick={() => setPreview({ bucket: 'partner-verification', path: application.partner_document_path!, title: `${application.organization_name || application.full_name || 'Partner'} - ${application.partner_document_type?.toUpperCase() || 'Verification'} document` })}>View document</button> : <p>NIN or CAC document missing</p>}</section>}
      {application.requested_role === 'partner' && !application.invited_partner_id && <PartnerVehicleRegistration supabase={supabase} applicationId={application.id} readOnly onError={onError} />}
      {application.status === 'pending' && <div className="company-review-actions"><button className="primary-button" disabled={busy === application.id || !application.email_confirmed || (application.requested_role === 'partner' && !application.partner_document_path)} onClick={() => void review(application, true)}>Approve</button><button className="secondary-button" disabled={busy === application.id} onClick={() => setRejecting(application.id)}>Reject</button>
        {rejecting === application.id && <form className="rejection-form" onSubmit={(event) => { event.preventDefault(); void review(application, false) }}><label className="field"><span>Reason for rejection</span><textarea required minLength={3} maxLength={2000} value={reasons[application.id] ?? ''} onChange={(event) => setReasons((current) => ({ ...current, [application.id]: event.target.value }))} /></label><p>This reason will be shown to the applicant.</p><button className="secondary-button" type="button" disabled={busy === application.id} onClick={() => setRejecting(null)}>Cancel rejection</button><button className="primary-button" disabled={busy === application.id}>Confirm rejection</button></form>}
      </div>}
    </article>)}</div>}</section>
    {preview && <DocumentPreview key={preview.path} supabase={supabase} document={preview} onClose={() => setPreview(null)} />}
    <section className="form-card"><h2>Active staff access</h2>{staff.length === 0 ? <p>No approved staff yet.</p> : <div className="admin-list">{staff.map((access) => <article className="admin-row" key={`${access.user_id}:${access.role}`}><div><strong>{access.full_name || access.email}</strong><p>{access.email} · {access.role.replaceAll('_', ' ')}{access.organization_name ? ` · ${access.organization_name}` : ''}</p></div><button className="secondary-button" disabled={busy === `${access.user_id}:${access.role}`} onClick={() => void revoke(access)}>Revoke access</button></article>)}</div>}</section>
  </main>
}
