import { useCallback, useEffect, useMemo, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'

type TeamMember = { partner_id: string; partner_name: string; user_id: string; email: string; full_name: string | null; membership_role: string; is_manager: boolean }
type Invitation = { invitation_id: string; partner_id: string; partner_name: string; invited_email: string; membership_role: string; status: string; expires_at: string; created_at: string }
type InviteResult = { invitation_id: string; invite_token: string; expires_at: string }
type RiderJob = { partner_id: string; job_id: string; job_number: string; status: string; assigned_rider_id: string | null }
type CompanyRider = { user_id: string; rider_name: string; device_bound_at: string | null; revoked_at: string | null; created_at: string }
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
  const [riderAccess, setRiderAccess] = useState<{ link: string; password: string; name: string } | null>(null)
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
    try { const result = await riderRequest({ action: 'list', partnerId: selectedPartner }); setRiders((result.riders ?? []) as CompanyRider[]) }
    catch (cause) { onError(cause instanceof Error ? cause.message : 'Could not load riders') }
  }, [onError, riderRequest, selectedPartner])
  useEffect(() => { const timer = window.setTimeout(() => { void loadRiders() }, 0); return () => window.clearTimeout(timer) }, [loadRiders])

  async function createRider(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!selectedPartner || busy) return
    const formElement = event.currentTarget
    const name = String(new FormData(formElement).get('rider_name') ?? '').trim()
    setBusy(true); onError(''); setRiderAccess(null)
    try {
      const result = await riderRequest({ action: 'create', partnerId: selectedPartner, name })
      setRiderAccess({ link: `${publicSiteUrl}rider#rider=${result.token}`, password: String(result.password), name })
      onNotice(`Access created for ${name}. Give the link and password to this rider privately.`)
      formElement.reset()
      await loadRiders()
    } catch (cause) { onError(cause instanceof Error ? cause.message : 'Could not create rider access') }
    finally { setBusy(false) }
  }

  async function resetRider(rider: CompanyRider) {
    if (busy || !selectedPartner || !window.confirm(`Reset ${rider.rider_name}'s password and phone binding?`)) return
    setBusy(true); onError(''); setRiderAccess(null)
    try {
      const result = await riderRequest({ action: 'reset', partnerId: selectedPartner, riderId: rider.user_id })
      setRiderAccess({ link: `${publicSiteUrl}rider#rider=${result.token}`, password: String(result.password), name: rider.rider_name })
      onNotice(`New access created for ${rider.rider_name}. The old rider link and password no longer work.`)
      await loadRiders()
    } catch (cause) { onError(cause instanceof Error ? cause.message : 'Could not reset rider access') }
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
    {members.length === 0 ? <p className="finance-empty">No active partner-company membership is linked to this account.</p> : <div className="admin-list">{members.map((member) => <article className="admin-row" key={`${member.partner_id}:${member.user_id}`}><div><strong>{member.full_name || member.email}</strong><p>{member.partner_name} · {member.membership_role.replaceAll('_', ' ')}</p><small>{member.membership_role === 'rider' ? 'No email needed' : member.email}{member.user_id === userId ? ' · You' : ''}</small></div>{member.is_manager && <span className="finance-status finance-status-paid">Company manager</span>}</article>)}</div>}
    {managers.some((manager) => members.some((member) => member.partner_id === manager.id && member.user_id === userId)) && <form className="finance-form" onSubmit={(event) => void createInvitation(event)}>
      <h3>Invite a team member</h3><label className="field"><span>Partner company</span><select value={selectedPartner} onChange={(event) => setSelectedPartner(event.target.value)} required>{managers.filter((manager) => members.some((member) => member.partner_id === manager.id && member.user_id === userId)).map((manager) => <option key={manager.id} value={manager.id}>{manager.name}</option>)}</select></label>
      <label className="field"><span>Invitee email address</span><input type="email" name="email" required maxLength={254} /></label><label className="field"><span>Team role</span><select name="membership_role"><option value="staff">Partner staff</option><option value="dispatcher">Dispatcher</option><option value="rider">Rider</option></select></label>
      <button className="secondary-button" disabled={busy}>{busy ? 'Creating invitation...' : 'Create invitation link'}</button>
      {inviteLink && <label className="field"><span>Share this link with the invited email</span><input value={inviteLink} readOnly onFocus={(event) => event.currentTarget.select()} /><button className="secondary-button" type="button" onClick={() => void copyLink()}>Copy invitation link</button></label>}
    </form>}
    {selectedPartner && <section className="finance-form" aria-label="Company rider access">
      <h3>Rider access</h3><p className="section-intro">Create a separate password for each rider. Riders use the link below without an email address and see only their assigned deliveries.</p>
      <form className="form-grid" onSubmit={(event) => void createRider(event)}><label className="field"><span>Rider full name</span><input name="rider_name" minLength={3} maxLength={120} required /></label><button className="primary-button" disabled={busy}>Generate rider password and link</button></form>
      {riderAccess && <div className="form-grid" aria-label="New rider credentials"><strong>{riderAccess.name}</strong><label className="field"><span>Rider link</span><input readOnly value={riderAccess.link} onFocus={(event) => event.currentTarget.select()} /></label><label className="field"><span>Unique password — shown once</span><input readOnly value={riderAccess.password} onFocus={(event) => event.currentTarget.select()} /></label></div>}
      {riders.length > 0 && <div className="admin-list">{riders.map((rider) => <article className="admin-row" key={rider.user_id}><div><strong>{rider.rider_name}</strong><p>{rider.device_bound_at ? 'Phone registered' : 'Waiting for first login'}</p></div><button type="button" className="secondary-button" disabled={busy} onClick={() => void resetRider(rider)}>Reset password and phone</button></article>)}</div>}
    </section>}
    {!!assignmentPartner && <section className="finance-form" aria-label="Rider pickup assignments">
      <h3>Assign pickups to riders</h3>
      <p className="section-intro">A rider can handle up to five active pickups. Active pickup work includes scheduled pickups, collected parcels, and exceptions; capacity opens when a job moves into transit or is completed/cancelled.</p>
      <label className="field"><span>Partner company</span><select value={assignmentPartner} onChange={(event) => setAssignmentPartner(event.target.value)}>{[...new Map(members.filter((member) => member.user_id === userId && ['manager', 'dispatcher'].includes(member.membership_role)).map((member) => [member.partner_id, { id: member.partner_id, name: member.partner_name }])).values()].map((partner) => <option key={partner.id} value={partner.id}>{partner.name}</option>)}</select></label>
      {riderJobs.filter((job) => job.partner_id === assignmentPartner).length === 0 ? <p className="finance-empty">No accepted partner jobs need rider assignment.</p> : <div className="admin-list">{riderJobs.filter((job) => job.partner_id === assignmentPartner).map((job) => {
        const riders = members.filter((member) => member.partner_id === job.partner_id && member.membership_role === 'rider')
        return <article className="admin-row" key={job.job_id}><div><strong>{job.job_number}</strong><p>{job.status.replaceAll('_', ' ')}{job.assigned_rider_id ? ' · rider assigned' : ' · rider needed'}</p></div><label className="field"><span>Rider</span><select aria-label={`Rider for ${job.job_number}`} value={riderForJob[job.job_id] ?? job.assigned_rider_id ?? ''} onChange={(event) => setRiderForJob((current) => ({ ...current, [job.job_id]: event.target.value }))} required><option value="">Choose a rider</option>{riders.map((rider) => <option key={rider.user_id} value={rider.user_id}>{rider.full_name || rider.email}</option>)}</select></label><button className="secondary-button" type="button" disabled={busy || !(riderForJob[job.job_id] || job.assigned_rider_id)} onClick={() => void assignRider(job)}>{busy ? 'Saving...' : 'Assign rider'}</button></article>
      })}</div>}
    </section>}
    {invitations.length > 0 && <div className="partner-invitation-list"><h3>Company invitations</h3>{invitations.map((invitation) => <article className="admin-row" key={invitation.invitation_id}><div><strong>{invitation.invited_email}</strong><p>{invitation.partner_name} · {invitation.membership_role.replaceAll('_', ' ')} · {invitation.status}</p><small>Expires {new Date(invitation.expires_at).toLocaleDateString('en-NG')}</small></div>{invitation.status === 'pending' && <button className="secondary-button finance-cancel" disabled={busy} onClick={() => void cancel(invitation)}>Cancel invite</button>}</article>)}</div>}
  </section>
}
