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
type RiderReview = { id: string; full_name: string; nin: string; nin_document_path: string | null; licence_document_path: string; photo_path: string | null; status: string; logistics_partners: { partner_name: string } | null }

export default function AdminConsole({ supabase, onError, onNotice }: {
  supabase: SupabaseClient; onError: (message: string) => void; onNotice: (message: string) => void
}) {
  const [applications, setApplications] = useState<Application[]>([])
  const [staff, setStaff] = useState<StaffAccess[]>([])
  const [riderReviews, setRiderReviews] = useState<RiderReview[]>([])
  const [preview, setPreview] = useState<PreviewDocument | null>(null)
  const [reasons, setReasons] = useState<Record<string, string>>({})
  const [rejecting, setRejecting] = useState<string | null>(null)
  const [busy, setBusy] = useState('')
  const [loading, setLoading] = useState(true)

  const load = useCallback(async () => {
    setLoading(true)
    const [applicationResult, staffResult, documentResult, riderResult] = await Promise.all([
      supabase.rpc('list_staff_applications'),
      supabase.rpc('list_staff_access'),
      supabase.from('staff_applications').select('id,partner_document_type,partner_document_path,rejection_reason'),
      supabase.from('company_riders').select('id,full_name,nin,nin_document_path,licence_document_path,photo_path,status,logistics_partners(partner_name)').eq('status','pending').order('created_at',{ ascending: true }),
    ])
    if (applicationResult.error) onError(applicationResult.error.message)
    if (staffResult.error) onError(staffResult.error.message)
    if (documentResult.error) onError(documentResult.error.message)
    if (riderResult.error) onError(riderResult.error.message)
    const documents = new Map((documentResult.data ?? []).map((item) => [item.id, item]))
    const rows = ((applicationResult.data ?? []) as Application[]).map((application) => ({ ...application, ...documents.get(application.id) }))
    setApplications(rows)
    setStaff((staffResult.data ?? []) as StaffAccess[])
    setRiderReviews((riderResult.data ?? []) as unknown as RiderReview[])
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

  async function reviewRider(rider: RiderReview, approve: boolean) {
    const reason = approve ? null : window.prompt('Reason for rejecting this rider:')?.trim()
    if (!approve && (!reason || reason.length < 3)) { onError('Enter a rejection reason.'); return }
    setBusy(rider.id); onError('')
    const { error } = await supabase.rpc('review_company_rider', { p_rider_id: rider.id, p_approve: approve, p_reason: reason })
    if (error) onError(error.message)
    else { onNotice(approve ? 'Rider approved. The company can now issue a password.' : 'Rider rejected.'); await load() }
    setBusy('')
  }

  return <main className="dashboard admin-page">
    <div className="dashboard-heading"><div><p className="eyebrow">KWIK-PARSEL SUPER ADMIN</p><h1>Access control</h1><p className="section-intro">Approve verified staff and partners, link partners to their company, and revoke access when needed.</p></div><button className="secondary-button" onClick={() => void load()} disabled={loading}>Refresh</button></div>
    <AdminQuotePricingPanel supabase={supabase} onError={onError} onNotice={onNotice} />
    <CoverageAdminPanel supabase={supabase} onError={onError} onNotice={onNotice} />
    <section className="form-card"><h2>Riders awaiting approval</h2>{riderReviews.length === 0 ? <p>No rider submissions need review.</p> : <div className="admin-list">{riderReviews.map((rider) => <article className="admin-row" key={rider.id}><div><strong>{rider.full_name}</strong><p>{rider.logistics_partners?.partner_name} · NIN ending {rider.nin.slice(-4)}</p><div className="company-review-actions">{rider.nin_document_path && <button type="button" className="secondary-button" onClick={() => setPreview({ bucket: 'rider-evidence', path: rider.nin_document_path!, title: `${rider.full_name} NIN document` })}>View NIN</button>}<button type="button" className="secondary-button" onClick={() => setPreview({ bucket: 'rider-evidence', path: rider.licence_document_path, title: `${rider.full_name} licence` })}>View licence</button></div></div><div className="company-review-actions"><button type="button" className="primary-button" disabled={busy === rider.id} onClick={() => void reviewRider(rider, true)}>Approve</button><button type="button" className="secondary-button" disabled={busy === rider.id} onClick={() => void reviewRider(rider, false)}>Reject</button></div></article>)}</div>}</section>
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
