import { useCallback, useEffect, useMemo, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import './partner-vehicles.css'

type TeamMember = { partner_id: string; partner_name: string; user_id: string; email: string; full_name: string | null; membership_role: string; is_manager: boolean }
type Invitation = { invitation_id: string; partner_id: string; partner_name: string; invited_email: string; membership_role: string; status: string; expires_at: string; created_at: string }
type InviteResult = { invitation_id: string; invite_token: string; expires_at: string }
type RiderJob = { partner_id: string; job_id: string; job_number: string; status: string; assigned_rider_id: string | null }
type RiderCredential = { user_id: string; device_bound_at: string | null; device_label: string | null; password_revoked_at: string | null; revoked_at: string | null }
type CompanyRider = { id: string; full_name: string; status: string; rejection_reason: string | null; photo_path: string | null; source_vehicle_id: string | null; created_at: string; rider_credentials: RiderCredential | RiderCredential[] | null }
const credentialFor = (rider: CompanyRider) => Array.isArray(rider.rider_credentials) ? rider.rider_credentials[0] : rider.rider_credentials
const publicSiteUrl = 'https://gohezoh-services.vercel.app/'
function partnerInviteFromLocation() {
  return new URLSearchParams(window.location.hash.replace(/^#/, '')).get('partner_invite')?.trim()
    ?? new URLSearchParams(window.location.search).get('partner_invite')?.trim() ?? ''
}

export function PartnerInvitationClaim({ supabase, onError, onNotice, onApplicationRequired }: {
  supabase: SupabaseClient; onError: (message: string) => void; onNotice: (message: string) => void; onApplicationRequired: () => void
}) {
  const token = partnerInviteFromLocation()
  const [busy, setBusy] = useState(false)
  const [finished, setFinished] = useState(false)
  if (token.length < 32 || finished) return null

  async function accept() {
    if (busy) return
    setBusy(true); onError('')
    const { data, error } = await supabase.rpc('accept_partner_staff_invitation', { p_token: token })
    function removeInvitationFromUrl() {
      const url = new URL(window.location.href); url.searchParams.delete('partner_invite')
      const hashParams = new URLSearchParams(url.hash.replace(/^#/, '')); hashParams.delete('partner_invite'); url.hash = hashParams.size ? hashParams.toString() : ''
      window.history.replaceState({}, '', url.toString())
    }
    if (error) onError(error.message)
    else if ((data as { status?: string })?.status === 'application_required') {
      setFinished(true)
      removeInvitationFromUrl()
      onNotice(`Invitation accepted for ${(data as { partner_name: string }).partner_name}. Submit your NIN or CAC document; Super Admin approval is still required.`)
      onApplicationRequired()
    } else {
      setFinished(true)
      removeInvitationFromUrl()
      onNotice(`You joined ${(data as { partner_name: string }).partner_name} as a partner team member.`)
      window.dispatchEvent(new Event('partner-invitation-accepted'))
    }
    setBusy(false)
  }

  return <section className="form-card partner-invitation-claim" aria-label="Partner company invitation">
    <p className="eyebrow">PARTNER COMPANY INVITATION</p><h2>Join a logistics partner team</h2>
    <p className="section-intro">Accept this email-bound invitation. If you are not yet approved as a logistics partner, Super Admin will review your NIN or CAC document before company access is enabled.</p>
    <button type="button" className="primary-button" onClick={() => void accept()} disabled={busy}>{busy ? 'Accepting invitation...' : 'Accept partner invitation'}</button>
  </section>
}

export function PartnerOrganizationPanel({ supabase, userId, onError, onNotice }: {
  supabase: SupabaseClient; userId: string; onError: (message: string) => void; onNotice: (message: string) => void
}) {
  const [members, setMembers] = useState<TeamMember[]>([])
  const [invitations, setInvitations] = useState<Invitation[]>([])
  const [riderJobs, setRiderJobs] = useState<RiderJob[]>([])
  const [assignmentPartner, setAssignmentPartner] = useState('')
  const [riderForJob, setRiderForJob] = useState<Record<string, string>>({})
  const [selectedPartner, setSelectedPartner] = useState('')
  const [inviteLink, setInviteLink] = useState('')
  const [riders, setRiders] = useState<CompanyRider[]>([])
  const [riderAccess, setRiderAccess] = useState<{ riderId: string; password: string; name: string } | null>(null)
  const [manualPasswords, setManualPasswords] = useState<Record<string, string>>({})
  const [riderPhotos, setRiderPhotos] = useState<Record<string, string>>({})
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const managers = useMemo(() => [...new Map(members.filter((member) => member.is_manager).map((member) => [member.partner_id, { id: member.partner_id, name: member.partner_name }])).values()], [members])
  const load = useCallback(async () => {
    setLoading(true)
    const [teamResult, invitationResult] = await Promise.all([supabase.rpc('list_my_partner_team'), supabase.rpc('list_partner_staff_invitations')])
    if (teamResult.error) onError(teamResult.error.message)
    if (invitationResult.error) onError(invitationResult.error.message)
    const team = (teamResult.data ?? []) as TeamMember[]
    setMembers(team); setInvitations((invitationResult.data ?? []) as Invitation[])
    setSelectedPartner((current) => team.some((member) => member.user_id === userId && member.is_manager && member.partner_id === current)
      ? current : (team.find((member) => member.user_id === userId && member.is_manager)?.partner_id ?? ''))
    const assignmentPartners = [...new Set(team.filter((member) => member.user_id === userId && ['manager', 'dispatcher'].includes(member.membership_role)).map((member) => member.partner_id))]
    setAssignmentPartner((current) => assignmentPartners.includes(current) ? current : (assignmentPartners[0] ?? ''))
    if (assignmentPartners.length) {
      const jobsResult = await supabase.rpc('list_partner_rider_jobs')
      if (jobsResult.error) onError(jobsResult.error.message)
      setRiderJobs((jobsResult.data ?? []) as RiderJob[])
    } else setRiderJobs([])
    setLoading(false)
  }, [onError, supabase, userId])
  useEffect(() => { const timer = window.setTimeout(() => { void load() }, 0); return () => window.clearTimeout(timer) }, [load])
  useEffect(() => {
    const refresh = () => { void load() }
    window.addEventListener('partner-invitation-accepted', refresh)
    return () => window.removeEventListener('partner-invitation-accepted', refresh)
  }, [load])

  const riderRequest = useCallback(async (body: Record<string, unknown>) => {
    const { data: { session } } = await supabase.auth.getSession()
    if (!session) throw new Error('Sign in as a company manager first.')
    const response = await fetch(`${import.meta.env.VITE_SUPABASE_URL}/functions/v1/rider-access`, {
      method: 'POST', headers: { 'content-type': 'application/json', apikey: import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY,
        Authorization: `Bearer ${session.access_token}` }, body: JSON.stringify(body),
    })
    const result = await response.json() as Record<string, unknown>
    if (!response.ok) throw new Error(String(result.error ?? 'Could not manage rider access'))
    return result
  }, [supabase])
  const loadRiders = useCallback(async () => {
    if (!selectedPartner) return
    try {
      const result = await riderRequest({ action: 'list', partnerId: selectedPartner })
      const rows = (result.riders ?? []) as CompanyRider[]
      setRiders(rows)
      const photos = await Promise.all(rows.filter((row) => row.photo_path).map(async (row) => {
        const { data } = await supabase.storage.from('rider-evidence').createSignedUrl(row.photo_path!, 300)
        return [row.id, data?.signedUrl ?? ''] as const
      }))
      setRiderPhotos(Object.fromEntries(photos))
    }
    catch (cause) { onError(cause instanceof Error ? cause.message : 'Could not load riders') }
  }, [onError, riderRequest, selectedPartner, supabase])
  useEffect(() => { const timer = window.setTimeout(() => { void loadRiders() }, 0); return () => window.clearTimeout(timer) }, [loadRiders])

  async function uploadRiderFile(file: File) {
    if (!selectedPartner || !userId || file.size > 5 * 1024 * 1024) throw new Error('Choose a file under 5 MB.')
    if (!['application/pdf', 'image/jpeg', 'image/png', 'image/webp'].includes(file.type)) throw new Error('Use a PDF, JPG, PNG, or WebP file.')
    const extension = file.type === 'application/pdf' ? 'pdf' : file.type === 'image/png' ? 'png' : file.type === 'image/webp' ? 'webp' : 'jpg'
    const path = `${selectedPartner}/${userId}/${crypto.randomUUID()}.${extension}`
    const { error } = await supabase.storage.from('rider-evidence').upload(path, file, { contentType: file.type, upsert: false })
    if (error) throw error
    return path
  }

  async function createRider(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!selectedPartner || busy) return
    const formElement = event.currentTarget
    const form = new FormData(formElement)
    const name = String(form.get('rider_name') ?? '').trim()
    setBusy(true); onError(''); setRiderAccess(null)
    try {
      const ninFile = form.get('nin_file') as File
      const licenceFile = form.get('licence_file') as File
      const photoFile = form.get('photo_file') as File
      if (!ninFile?.size || !licenceFile?.size) throw new Error('Add the NIN and driving licence documents.')
      const [ninPath, licencePath, photoPath] = await Promise.all([uploadRiderFile(ninFile), uploadRiderFile(licenceFile), photoFile?.size ? uploadRiderFile(photoFile) : Promise.resolve(null)])
      const { error } = await supabase.rpc('register_company_rider', { p_partner_id: selectedPartner, p_full_name: name,
        p_nin: String(form.get('rider_nin') ?? '').trim(), p_nin_document_path: ninPath,
        p_licence_document_path: licencePath, p_photo_path: photoPath })
      if (error) throw error
      onNotice(`${name} was submitted to Super Admin. A password can be issued after approval.`)
      formElement.reset()
      await loadRiders()
    } catch (cause) { onError(cause instanceof Error ? cause.message : 'Could not create rider access') }
    finally { setBusy(false) }
  }

  async function issuePassword(rider: CompanyRider) {
    const credential = credentialFor(rider)
    if (busy || !selectedPartner || rider.status !== 'approved') return
    if (credential && !window.confirm(`Replace ${rider.full_name}'s password and registered phone?`)) return
    setBusy(true); onError(''); setRiderAccess(null)
    try {
      const result = await riderRequest({ action: credential ? 'reset' : 'create', partnerId: selectedPartner,
        rosterId: rider.id, riderId: credential?.user_id, password: manualPasswords[rider.id]?.trim() || undefined })
      setRiderAccess({ riderId: rider.id, password: String(result.password), name: rider.full_name })
      setManualPasswords((current) => ({ ...current, [rider.id]: '' }))
      onNotice(`Password ready for ${rider.full_name}. Give it to this rider privately. It works only on the first registered phone.`)
      await loadRiders()
    } catch (cause) { onError(cause instanceof Error ? cause.message : 'Could not reset rider access') }
    finally { setBusy(false) }
  }

  async function archiveRider(rider: CompanyRider) {
    if (busy || !window.confirm(`Remove ${rider.full_name}? Their login stops immediately; their record stays archived.`)) return
    setBusy(true); onError('')
    const { error } = await supabase.rpc('archive_company_rider', { p_rider_id: rider.id })
    if (error) onError(error.message)
    else { onNotice(`${rider.full_name} removed. Reassign any jobs still assigned to them.`); await loadRiders(); await load() }
    setBusy(false)
  }

  async function changePhoto(rider: CompanyRider, file?: File) {
    if (!file) return
    setBusy(true); onError('')
    try {
      if (!file.type.startsWith('image/')) throw new Error('Choose an image file.')
      const path = await uploadRiderFile(file)
      const { error } = await supabase.rpc('set_company_rider_photo', { p_rider_id: rider.id, p_photo_path: path })
      if (error) throw error
      await loadRiders()
    } catch (cause) { onError(cause instanceof Error ? cause.message : 'Could not update photo') }
    finally { setBusy(false) }
  }

  async function createInvitation(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!selectedPartner || busy) return
    const formElement = event.currentTarget
    const form = new FormData(formElement)
    setBusy(true); onError('')
    const { data, error } = await supabase.rpc('create_partner_staff_invitation', {
      p_partner_id: selectedPartner, p_email: String(form.get('email') ?? '').trim(), p_membership_role: String(form.get('membership_role') ?? 'staff'),
    })
    if (error) onError(error.message)
    else {
      const result = ((data ?? []) as InviteResult[])[0]
      if (!result?.invite_token) onError('The invitation was created, but its one-time link was not returned. Refresh the invitation list.')
      else {
        const url = new URL(publicSiteUrl); url.hash = new URLSearchParams({ partner_invite: result.invite_token }).toString()
        setInviteLink(url.toString()); onNotice('Invitation link created. Share it only with the invited email address.'); formElement.reset(); await load()
      }
    }
    setBusy(false)
  }

  async function cancel(invitation: Invitation) {
    if (busy || !window.confirm(`Cancel the invitation for ${invitation.invited_email}?`)) return
    setBusy(true)
    const { error } = await supabase.rpc('cancel_partner_staff_invitation', { p_invitation_id: invitation.invitation_id })
    if (error) onError(error.message); else { onNotice('Invitation cancelled.'); await load() }
    setBusy(false)
  }

  async function copyLink() {
    try { await navigator.clipboard.writeText(inviteLink); onNotice('Invitation link copied.') }
    catch { onError('Copy is unavailable in this browser. Select and copy the invitation link above.') }
  }

  async function assignRider(job: RiderJob) {
    const riderId = riderForJob[job.job_id] || job.assigned_rider_id
    if (!riderId || busy) return
    setBusy(true); onError('')
    const { error } = await supabase.rpc('assign_job_to_rider', { p_job_id: job.job_id, p_rider_user_id: riderId })
    if (error) onError(error.message)
    else { onNotice(`Rider assigned to ${job.job_number}. A rider may have up to five active pickups.`); await load() }
    setBusy(false)
  }

  if (loading) return <section className="form-card"><p>Loading partner organization...</p></section>
  return <section className="form-card partner-organization-panel" aria-label="Partner organization team">
    <div className="dashboard-heading"><div><p className="eyebrow">PARTNER ORGANIZATION</p><h2>Company team</h2><p className="section-intro">Invite team members by email. New Partner access still requires Super Admin approval and NIN/CAC verification.</p></div><button className="secondary-button" type="button" onClick={() => void load()}>Refresh team</button></div>
    {members.length === 0 ? <p className="finance-empty">No active partner-company membership is linked to this account.</p> : <div className="admin-list">{members.filter((member) => member.membership_role !== 'rider').map((member) => <article className="admin-row" key={`${member.partner_id}:${member.user_id}`}><div><strong>{member.full_name || member.email}</strong><p>{member.partner_name} · {member.membership_role.replaceAll('_', ' ')}</p><small>{member.membership_role === 'rider' ? 'No email needed' : member.email}{member.user_id === userId ? ' · You' : ''}</small></div>{member.is_manager && <span className="finance-status finance-status-paid">Company manager</span>}</article>)}</div>}
    {managers.some((manager) => members.some((member) => member.partner_id === manager.id && member.user_id === userId)) && <form className="finance-form" onSubmit={(event) => void createInvitation(event)}>
      <h3>Invite a team member</h3><label className="field"><span>Partner company</span><select value={selectedPartner} onChange={(event) => setSelectedPartner(event.target.value)} required>{managers.filter((manager) => members.some((member) => member.partner_id === manager.id && member.user_id === userId)).map((manager) => <option key={manager.id} value={manager.id}>{manager.name}</option>)}</select></label>
      <label className="field"><span>Invitee email address</span><input type="email" name="email" required maxLength={254} /></label><label className="field"><span>Team role</span><select name="membership_role"><option value="staff">Partner staff</option><option value="dispatcher">Dispatcher</option></select></label>
      <button className="secondary-button" disabled={busy}>{busy ? 'Creating invitation...' : 'Create invitation link'}</button>
      {inviteLink && <label className="field"><span>Share this link with the invited email</span><input value={inviteLink} readOnly onFocus={(event) => event.currentTarget.select()} /><button className="secondary-button" type="button" onClick={() => void copyLink()}>Copy invitation link</button></label>}
    </form>}
    {selectedPartner && <section className="finance-form" aria-label="Company rider access">
      <h3>Company riders</h3><div className="company-review-actions"><button type="button" className="secondary-button" onClick={() => void navigator.clipboard.writeText(`${publicSiteUrl}rider#company=${selectedPartner}`).then(() => onNotice('Rider link copied.')).catch(() => onError('Copy is unavailable. Share the link from the WhatsApp button.'))}>Copy rider link</button><a className="secondary-button" href={`https://wa.me/?text=${encodeURIComponent(`Use your company rider password to sign in: ${publicSiteUrl}rider#company=${selectedPartner}`)}`} target="_blank" rel="noopener noreferrer">Send to WhatsApp</a></div>
      <details><summary>Add new rider</summary><form className="form-grid" onSubmit={(event) => void createRider(event)}><label className="field"><span>Full name</span><input name="rider_name" minLength={3} maxLength={120} required /></label><label className="field"><span>11-digit NIN</span><input name="rider_nin" inputMode="numeric" pattern="[0-9]{11}" required /></label><label className="field"><span>NIN document</span><input name="nin_file" type="file" accept="application/pdf,image/jpeg,image/png,image/webp" required /></label><label className="field"><span>Driving licence</span><input name="licence_file" type="file" accept="application/pdf,image/jpeg,image/png,image/webp" required /></label><label className="field"><span>Rider photo</span><input name="photo_file" type="file" accept="image/jpeg,image/png,image/webp" /></label><button className="primary-button" disabled={busy}>Submit for approval</button></form></details>
      {riders.length === 0 ? <p className="finance-empty">No registered drivers yet.</p> : <div className="admin-list">{riders.map((rider) => { const credential = credentialFor(rider); return <article className="admin-row rider-roster-card" key={rider.id}><div className="rider-roster-photo">{riderPhotos[rider.id] ? <img src={riderPhotos[rider.id]} alt={`${rider.full_name} profile`} /> : <span aria-label="No rider photo">{rider.full_name.slice(0, 1)}</span>}<label className="rider-photo-edit">Photo<input type="file" accept="image/jpeg,image/png,image/webp" disabled={busy || rider.status === 'archived'} onChange={(event) => void changePhoto(rider, event.target.files?.[0])} /></label></div><div className="rider-roster-details"><strong>{rider.full_name}</strong><p>{rider.status === 'approved' ? credential?.device_bound_at ? 'Phone registered' : 'Approved · waiting for first login' : rider.status}</p>{rider.rejection_reason && <p>{rider.rejection_reason}</p>}{credential?.device_label && <small>Reported phone: {credential.device_label}</small>}{credential?.password_revoked_at && <p role="alert">Someone may be trying to access this rider account. Their password was removed. Create a new one.</p>}{rider.status === 'approved' && <div className="rider-password-controls"><label className="field"><span>Custom password (optional)</span><input type="text" minLength={12} value={manualPasswords[rider.id] ?? ''} onChange={(event) => setManualPasswords((current) => ({ ...current, [rider.id]: event.target.value }))} placeholder="Or generate an easy password" /></label><button type="button" className="secondary-button" disabled={busy} onClick={() => void issuePassword(rider)}>{credential ? 'Regenerate rider password' : 'Generate rider password'}</button>{riderAccess?.riderId === rider.id && <p role="status"><strong>{riderAccess.name}: {riderAccess.password}</strong><br />Shown once. Share privately.</p>}</div>}</div>{rider.status !== 'archived' && <button type="button" className="secondary-button finance-cancel" disabled={busy} onClick={() => void archiveRider(rider)}>Remove rider</button>}</article> })}</div>}
    </section>}
    {!!assignmentPartner && <section className="finance-form" aria-label="Rider pickup assignments">
      <h3>Assign pickups to riders</h3>
      <p className="section-intro">A rider can handle up to five active pickups. Active pickup work includes scheduled pickups, collected parcels, and exceptions; capacity opens when a job moves into transit or is completed/cancelled.</p>
      <label className="field"><span>Partner company</span><select value={assignmentPartner} onChange={(event) => setAssignmentPartner(event.target.value)}>{[...new Map(members.filter((member) => member.user_id === userId && ['manager', 'dispatcher'].includes(member.membership_role)).map((member) => [member.partner_id, { id: member.partner_id, name: member.partner_name }])).values()].map((partner) => <option key={partner.id} value={partner.id}>{partner.name}</option>)}</select></label>
      {riderJobs.filter((job) => job.partner_id === assignmentPartner).length === 0 ? <p className="finance-empty">No accepted partner jobs need rider assignment.</p> : <div className="admin-list">{riderJobs.filter((job) => job.partner_id === assignmentPartner).map((job) => {
        const availableRiders = riders.filter((rider) => rider.status === 'approved' && credentialFor(rider)?.user_id && !credentialFor(rider)?.revoked_at && !credentialFor(rider)?.password_revoked_at)
        return <article className="admin-row" key={job.job_id}><div><strong>{job.job_number}</strong><p>{job.status.replaceAll('_', ' ')}{job.assigned_rider_id ? ' · rider assigned' : ' · rider needed'}</p></div><label className="field"><span>Rider</span><select aria-label={`Rider for ${job.job_number}`} value={riderForJob[job.job_id] ?? job.assigned_rider_id ?? ''} onChange={(event) => setRiderForJob((current) => ({ ...current, [job.job_id]: event.target.value }))} required><option value="">Choose a rider</option>{availableRiders.map((rider) => <option key={rider.id} value={credentialFor(rider)!.user_id}>{rider.full_name}</option>)}</select></label><button className="secondary-button" type="button" disabled={busy || !(riderForJob[job.job_id] || job.assigned_rider_id)} onClick={() => void assignRider(job)}>{busy ? 'Saving...' : 'Assign rider'}</button></article>
      })}</div>}
    </section>}
    {invitations.length > 0 && <div className="partner-invitation-list"><h3>Company invitations</h3>{invitations.map((invitation) => <article className="admin-row" key={invitation.invitation_id}><div><strong>{invitation.invited_email}</strong><p>{invitation.partner_name} · {invitation.membership_role.replaceAll('_', ' ')} · {invitation.status}</p><small>Expires {new Date(invitation.expires_at).toLocaleDateString('en-NG')}</small></div>{invitation.status === 'pending' && <button className="secondary-button finance-cancel" disabled={busy} onClick={() => void cancel(invitation)}>Cancel invite</button>}</article>)}</div>}
  </section>
}
