import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import './partner-vehicles.css'

type TeamMember = { partner_id: string; partner_name: string; user_id: string; is_manager: boolean }
type RiderCredential = { user_id: string; device_bound_at: string | null; device_label: string | null; password_revoked_at: string | null; revoked_at: string | null }
type CompanyRider = { id: string; full_name: string; phone: string | null; status: string; rejection_reason: string | null; photo_path: string | null; source_vehicle_id: string | null; created_at: string; rider_credentials: RiderCredential | RiderCredential[] | null }
type RiderDelivery = { id: string; job_number: string; status: string; pickup_address: string; delivery_address: string; updated_at: string }
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

export function PartnerRidersPanel({ supabase, userId, onError, onNotice }: {
  supabase: SupabaseClient; userId: string; onError: (message: string) => void; onNotice: (message: string) => void
}) {
  const [members, setMembers] = useState<TeamMember[]>([])
  const [selectedPartner, setSelectedPartner] = useState('')
  const [riders, setRiders] = useState<CompanyRider[]>([])
  const [riderAccess, setRiderAccess] = useState<{ riderId: string; password: string; name: string } | null>(null)
  const [manualPasswords, setManualPasswords] = useState<Record<string, string>>({})
  const [riderPhotos, setRiderPhotos] = useState<Record<string, string>>({})
  const [expandedRiderId, setExpandedRiderId] = useState<string | null>(null)
  const [riderDeliveries, setRiderDeliveries] = useState<RiderDelivery[]>([])
  const [deliveriesLoading, setDeliveriesLoading] = useState(false)
  const [deliveriesError, setDeliveriesError] = useState('')
  const riderRequestSequence = useRef(0)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const managers = useMemo(() => [...new Map(members.filter((member) => member.is_manager).map((member) => [member.partner_id, { id: member.partner_id, name: member.partner_name }])).values()], [members])
  const load = useCallback(async () => {
    setLoading(true)
    const teamResult = await supabase.rpc('list_my_partner_team')
    if (teamResult.error) onError(teamResult.error.message)
    const team = (teamResult.data ?? []) as TeamMember[]
    setMembers(team)
    setSelectedPartner((current) => team.some((member) => member.user_id === userId && member.is_manager && member.partner_id === current)
      ? current : (team.find((member) => member.user_id === userId && member.is_manager)?.partner_id ?? ''))
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

  async function toggleRiderDetails(rider: CompanyRider) {
    const requestSequence = ++riderRequestSequence.current
    if (expandedRiderId === rider.id) { setExpandedRiderId(null); return }
    setExpandedRiderId(rider.id)
    setRiderDeliveries([])
    setDeliveriesError('')
    const riderUserId = credentialFor(rider)?.user_id
    if (!riderUserId || !selectedPartner) return
    setDeliveriesLoading(true)
    const { data, error } = await supabase.from('jobs')
      .select('id,job_number,status,pickup_address,delivery_address,updated_at')
      .eq('partner_id', selectedPartner).eq('assigned_rider_id', riderUserId)
      .order('updated_at', { ascending: false }).limit(20)
    if (requestSequence !== riderRequestSequence.current) return
    if (error) setDeliveriesError('Could not load this rider’s deliveries. Try opening the card again.')
    else setRiderDeliveries((data ?? []) as RiderDelivery[])
    setDeliveriesLoading(false)
  }

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
      const { data: riderId, error } = await supabase.rpc('register_company_rider', { p_partner_id: selectedPartner, p_full_name: name,
        p_nin: String(form.get('rider_nin') ?? '').trim(), p_nin_document_path: ninPath,
        p_licence_document_path: licencePath, p_photo_path: photoPath })
      if (error) throw error
      const riderPhone = String(form.get('rider_phone') ?? '').trim()
      if (riderPhone) {
        const { error: phoneError } = await supabase.rpc('set_company_rider_phone', { p_rider_id: riderId, p_phone: riderPhone })
        if (phoneError) throw phoneError
      }
      onNotice(`${name} was submitted to Super Admin. A password can be issued after approval.`)
      formElement.reset()
      await loadRiders()
    } catch (cause) { onError(cause instanceof Error ? cause.message : 'Could not create rider access') }
    finally { setBusy(false) }
  }

  async function saveRiderPhone(event: FormEvent<HTMLFormElement>, rider: CompanyRider) {
    event.preventDefault()
    if (busy) return
    setBusy(true); onError('')
    const phone = String(new FormData(event.currentTarget).get('phone') ?? '').trim()
    const { error } = await supabase.rpc('set_company_rider_phone', { p_rider_id: rider.id, p_phone: phone })
    if (error) onError(error.message)
    else { onNotice(`${rider.full_name}'s contact number saved.`); await loadRiders() }
    setBusy(false)
  }

  async function issuePassword(rider: CompanyRider) {
    const credential = credentialFor(rider)
    if (busy || !selectedPartner || rider.status !== 'approved') return
    if (credential && !window.confirm(`Replace ${rider.full_name}'s password and registered login device?`)) return
    setBusy(true); onError(''); setRiderAccess(null)
    try {
      const result = await riderRequest({ action: credential ? 'reset' : 'create', partnerId: selectedPartner,
        rosterId: rider.id, riderId: credential?.user_id, password: manualPasswords[rider.id]?.trim() || undefined })
      setRiderAccess({ riderId: rider.id, password: String(result.password), name: rider.full_name })
      setManualPasswords((current) => ({ ...current, [rider.id]: '' }))
      onNotice(`Password ready for ${rider.full_name}. Give it to this rider privately. It works only on the first registered login device.`)
      await loadRiders()
    } catch (cause) { onError(cause instanceof Error ? cause.message : 'Could not reset rider access') }
    finally { setBusy(false) }
  }

  async function archiveRider(rider: CompanyRider) {
    if (busy || !window.confirm(`Remove ${rider.full_name}? Their login stops immediately; their record stays archived.`)) return
    setBusy(true); onError('')
    const { error } = await supabase.rpc('archive_company_rider', { p_rider_id: rider.id })
    if (error) onError(error.message)
    else { onNotice(`${rider.full_name} removed. Reassign any jobs still assigned to them.`); await loadRiders() }
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

  if (loading) return <section className="form-card"><p>Loading riders...</p></section>
  return <section className="form-card partner-riders-panel" aria-label="Company riders">
    <div className="dashboard-heading"><div><p className="eyebrow">RIDER MANAGEMENT</p><h2>Company riders</h2></div><button className="secondary-button" type="button" onClick={() => void loadRiders()}>Refresh riders</button></div>
    {managers.length > 1 && <label className="field"><span>Company</span><select value={selectedPartner} onChange={(event) => setSelectedPartner(event.target.value)}>{managers.map((manager) => <option key={manager.id} value={manager.id}>{manager.name}</option>)}</select></label>}
    {!selectedPartner ? <p className="finance-empty">No company rider access is linked to this account.</p> : <>
      <div className="company-review-actions"><button type="button" className="secondary-button" onClick={() => void navigator.clipboard.writeText(`${publicSiteUrl}rider#company=${selectedPartner}`).then(() => onNotice('Rider link copied.')).catch(() => onError('Copy is unavailable. Share the link from the WhatsApp button.'))}>Copy rider link</button><a className="secondary-button" href={`https://wa.me/?text=${encodeURIComponent(`Use your company rider password to sign in: ${publicSiteUrl}rider#company=${selectedPartner}`)}`} target="_blank" rel="noopener noreferrer">Send to WhatsApp</a></div>
      <details><summary>Add new rider</summary><form className="form-grid" onSubmit={(event) => void createRider(event)}><label className="field"><span>Full name</span><input name="rider_name" minLength={3} maxLength={120} required /></label><label className="field"><span>11-digit NIN</span><input name="rider_nin" inputMode="numeric" pattern="[0-9]{11}" required /></label><label className="field"><span>Rider phone number</span><input name="rider_phone" type="tel" inputMode="tel" pattern="[+]?[0-9]{10,15}" placeholder="e.g. 08031234567" /></label><label className="field"><span>NIN document</span><input name="nin_file" type="file" accept="application/pdf,image/jpeg,image/png,image/webp" required /></label><label className="field"><span>Driving licence</span><input name="licence_file" type="file" accept="application/pdf,image/jpeg,image/png,image/webp" required /></label><label className="field"><span>Rider photo</span><input name="photo_file" type="file" accept="image/jpeg,image/png,image/webp" /></label><button className="primary-button" disabled={busy}>Submit for approval</button></form></details>
      {riders.length === 0 ? <p className="finance-empty">No registered riders yet.</p> :
        <div className="rider-roster-grid">{riders.map((rider) => {
          const credential = credentialFor(rider)
          const expanded = expandedRiderId === rider.id
          return <article className={`rider-roster-card${expanded ? ' rider-roster-card-expanded' : ''}`} key={rider.id}>
            <div className="rider-roster-summary">
              <div className="rider-roster-photo">{riderPhotos[rider.id] ? <img src={riderPhotos[rider.id]} alt={`${rider.full_name} profile`} /> : <span aria-label="No rider photo">{rider.full_name.slice(0, 1)}</span>}</div>
              <strong>{rider.full_name}</strong>
              <span className="rider-roster-status">{rider.status === 'approved' ? 'Approved' : rider.status}</span>
              <button type="button" className="secondary-button" aria-expanded={expanded} aria-controls={`rider-details-${rider.id}`} onClick={() => void toggleRiderDetails(rider)}>{expanded ? 'Hide rider info' : 'Show & edit rider info'}</button>
            </div>
            {expanded && <div className="rider-roster-details" id={`rider-details-${rider.id}`}>
              <div className="rider-details-heading"><div><h4>{rider.full_name}</h4><p>{rider.status === 'approved' ? credential?.device_bound_at ? 'Login device registered' : 'Approved ? waiting for first login' : rider.status}</p></div><button type="button" className="text-button" onClick={() => void toggleRiderDetails(rider)}>Close</button></div>
              {rider.rejection_reason && <p className="rider-rejection-reason">Reason: {rider.rejection_reason}</p>}
              <div className="rider-detail-columns">
                <div className="rider-detail-settings">
                  <label className="rider-photo-edit">Change rider photo<input type="file" accept="image/jpeg,image/png,image/webp" disabled={busy || rider.status === 'archived'} onChange={(event) => void changePhoto(rider, event.target.files?.[0])} /></label>
                  {rider.status !== 'archived' && <form className="rider-phone-edit" onSubmit={(event) => void saveRiderPhone(event, rider)}><label className="field"><span>Rider phone number</span><input name="phone" type="tel" inputMode="tel" pattern="[+]?[0-9]{10,15}" defaultValue={rider.phone ?? ''} required /></label><button type="submit" className="secondary-button" disabled={busy}>Save number</button></form>}
                  {credential?.device_label && <small>Login device: {credential.device_label}</small>}
                  {credential?.password_revoked_at && <p role="alert">Someone may be trying to access this rider account. Their password was removed. Create a new one.</p>}
                  {rider.status === 'approved' && <div className="rider-password-controls"><label className="field"><span>Custom password (optional)</span><input type="text" minLength={12} value={manualPasswords[rider.id] ?? ''} onChange={(event) => setManualPasswords((current) => ({ ...current, [rider.id]: event.target.value }))} placeholder="Or generate an easy password" /></label><button type="button" className="secondary-button" disabled={busy} onClick={() => void issuePassword(rider)}>{credential ? 'Regenerate rider password' : 'Generate rider password'}</button>{riderAccess?.riderId === rider.id && <p role="status"><strong>{riderAccess.name}: {riderAccess.password}</strong><br />Shown once. Share privately.</p>}</div>}
                  {rider.status !== 'archived' && <button type="button" className="secondary-button finance-cancel" disabled={busy} onClick={() => void archiveRider(rider)}>Remove rider</button>}
                </div>
                <div className="rider-delivery-history"><h5>Assigned deliveries</h5>{deliveriesLoading ? <p>Loading deliveries...</p> : deliveriesError ? <p role="alert">{deliveriesError}</p> : riderDeliveries.length === 0 ? <p>No deliveries assigned yet.</p> : <ul>{riderDeliveries.map((job) => <li key={job.id}>
                  <div className="rider-delivery-line"><strong>{job.job_number}</strong><span>{job.pickup_address} to {job.delivery_address}</span><small>{job.status.replaceAll('_', ' ')}</small></div>
                </li>)}</ul>}</div>
              </div>
            </div>}
          </article>
        })}</div>}

    </>}
  </section>
}
