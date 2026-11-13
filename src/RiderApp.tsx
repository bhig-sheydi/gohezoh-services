import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react'
import type { Session } from '@supabase/supabase-js'
import { getSupabaseClient } from './lib/supabase'
import { riderDeviceProof } from './lib/rider-device'
import RideAlerts from './RideAlerts'
import { clearRideAlerts } from './lib/ride-alerts'
import { routeLabel } from './lib/route-label'
import RiderAvailability from './RiderAvailability'
import { stopNativeRiderTracking } from './lib/native-rider'
import RiderNextStop, { type RiderRouteStop } from './RiderNextStop'
import './App.css'
import './dark.css'

type RiderJob = { job_id: string; job_number: string; status: string; pickup_address: string; pickup_city: string;
  delivery_address: string; delivery_city: string; recipient_name: string; recipient_phone: string;
  parcel_summary: string; company_name: string; latitude?: number | null; longitude?: number | null; delivery_latitude?: number | null; delivery_longitude?: number | null; sender_name?: string; sender_phone?: string }
type SelectedPickup = { request_id: string; request_number: string; pickup_city: string; delivery_city: string;
  pickup_address?: string | null; delivery_address?: string | null; parcel_summary: string | null; company_name: string; selected_at: string }
type IndependentOffer = { request_id: string; request_number: string; pickup_address: string; delivery_address: string;
  parcel_summary: string; customer_price_ngn: number; company_share_ngn: number; deadline_at: string }
type RiderDashboardSnapshot = {
  has_role: boolean; session_active: boolean; jobs: RiderJob[];
  profile: Array<{ company_name?: string | null }>;
  pickup_locations: Array<{ job_id: string; sender_name?: string; sender_phone?: string; latitude?: number; longitude?: number }>;
  delivery_locations: Array<{ job_id: string; latitude?: number; longitude?: number }>;
  selected_pickups: SelectedPickup[]; next_stop: RiderRouteStop[];
  assignment_responses?: Array<{ job_id: string; deadline_at: string; accepted_at: string | null }>;
}
const nextStatus: Record<string, string[]> = {
  partner_assigned: ['pickup_scheduled', 'exception'], pickup_scheduled: ['exception'],
  picked_up: ['exception'], in_transit: ['exception'],
  out_for_delivery: ['exception'], exception: ['pickup_scheduled', 'in_transit'],
}
const label = (status: string) => (status === 'picked_up' || status === 'out_for_delivery' ? 'In transit' : status.replaceAll('_', ' ').replace(/^./, (letter) => letter.toUpperCase()))
const token = () => new URLSearchParams(window.location.hash.replace(/^#/, '')).get('rider') ?? ''
const company = () => new URLSearchParams(window.location.hash.replace(/^#/, '')).get('company') ?? ''
async function deviceLabel() {
  const hints = (navigator as Navigator & { userAgentData?: { getHighEntropyValues?: (names: string[]) => Promise<{ model?: string; platform?: string }> } }).userAgentData
  try {
    const details = await hints?.getHighEntropyValues?.(['model', 'platform'])
    if (details?.model) return `${details.platform ?? 'Phone'} ${details.model}`.slice(0, 120)
  } catch { /* Model hints are optional and may be unavailable. */ }
  const ua = navigator.userAgent
  const android = ua.match(/Android[^;)]*;\s*([^;)]+)\s*[;)]/i)
  if (android) return `Android ${android[1].trim()}`.slice(0, 120)
  if (/iPhone/i.test(ua)) return 'iPhone (model unavailable)'
  return 'Phone model unavailable'
}

async function access(body: Record<string, unknown>) {
  const response = await fetch(`${import.meta.env.VITE_SUPABASE_URL}/functions/v1/rider-access`, {
    method: 'POST', headers: { 'content-type': 'application/json', apikey: import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY },
    body: JSON.stringify(body),
  })
  const result = await response.json() as Record<string, unknown>
  if (!response.ok) throw new Error(String(result.error ?? 'Rider access is unavailable'))
  return result
}

export default function RiderApp() {
  const supabase = getSupabaseClient()
  useEffect(() => {
    let saved: string | null = null
    try { saved = window.localStorage.getItem('gohezoh-theme') } catch { /* Browser storage may be unavailable. */ }
    const theme = saved === 'light' || saved === 'dark' ? saved : window.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'
    document.documentElement.dataset.theme = theme
    document.querySelector('meta[name="theme-color"]')?.setAttribute('content', theme === 'dark' ? '#101a19' : '#f4f6ef')
  }, [])
  const [session, setSession] = useState<Session | null>(null)
  const [ready, setReady] = useState(false)
  const [rider, setRider] = useState<boolean | null>(null)
  const [jobs, setJobs] = useState<RiderJob[]>([])
  const [assignmentResponses, setAssignmentResponses] = useState<RiderDashboardSnapshot['assignment_responses']>([])
  const [selectedPickups, setSelectedPickups] = useState<SelectedPickup[]>([])
  const [nextStop, setNextStop] = useState<RiderRouteStop | null>(null)
  const [companyName, setCompanyName] = useState('Company rider')
  const [companies, setCompanies] = useState<Array<{ id: string; name: string }>>([])
  const [independentOffers, setIndependentOffers] = useState<IndependentOffer[]>([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [codes, setCodes] = useState<Record<string, string>>({})
  const [pickupCodes, setPickupCodes] = useState<Record<string, string>>({})
  const [senderConfirmationRequested, setSenderConfirmationRequested] = useState<Record<string, boolean>>({})
  const lastAccessCheckAt = useRef(0)
  const loadGeneration = useRef(0)
  const clearDashboard = useCallback(() => {
    setJobs([]); setAssignmentResponses([]); setSelectedPickups([]); setNextStop(null); setCompanyName('Company rider')
  }, [])
  useEffect(() => {
    void supabase.auth.getSession().then(({ data }) => { setSession(data.session); setReady(true) })
    const { data: { subscription } } = supabase.auth.onAuthStateChange((event, next) => {
      loadGeneration.current++
      if (event === 'SIGNED_OUT') { stopNativeRiderTracking(); lastAccessCheckAt.current = 0; clearDashboard() }
      setSession(next); setRider(null)
    })
    return () => subscription.unsubscribe()
  }, [supabase, clearDashboard])
  const load = useCallback(async () => {
    if (!session?.user) return
    const generation = ++loadGeneration.current
    let result: Awaited<ReturnType<typeof supabase.rpc>>
    try { result = await supabase.rpc('my_rider_dashboard_snapshot') }
    catch {
      if (generation !== loadGeneration.current) return
      lastAccessCheckAt.current = 0; clearDashboard(); setError('Could not check rider access. Refresh to try again.')
      return
    }
    if (generation !== loadGeneration.current) return
    const { data, error: loadError } = result
    if (loadError) { lastAccessCheckAt.current = 0; clearDashboard(); setError(loadError.message); return }
    const snapshot = data as RiderDashboardSnapshot | null
    if (!snapshot || typeof snapshot.has_role !== 'boolean' || typeof snapshot.session_active !== 'boolean' ||
      !Array.isArray(snapshot.jobs) || !Array.isArray(snapshot.profile) ||
      !Array.isArray(snapshot.pickup_locations) || !Array.isArray(snapshot.delivery_locations) ||
      !Array.isArray(snapshot.selected_pickups) || !Array.isArray(snapshot.next_stop)) {
      lastAccessCheckAt.current = 0; clearDashboard(); setError('Could not load rider jobs. Refresh to try again.'); return
    }
    lastAccessCheckAt.current = Date.now()
    setRider(snapshot.has_role)
    if (!snapshot.has_role) {
      clearDashboard()
      if (session.user.user_metadata?.account_kind === 'independent_rider') { setError(''); return }
      setError('Your rider access has ended. Ask company management for a new password.')
      await supabase.auth.signOut()
      return
    }
    if (!snapshot.session_active) {
      clearDashboard()
      setError('Your rider access has ended. Ask company management for a new password.')
      await supabase.auth.signOut()
      return
    }
    setJobs(snapshot.jobs.map((job) => {
      const delivery = snapshot.delivery_locations.find((location) => location.job_id === job.job_id)
      return { ...job, ...snapshot.pickup_locations.find((location) => location.job_id === job.job_id),
        delivery_latitude: delivery?.latitude, delivery_longitude: delivery?.longitude }
    }))
    setAssignmentResponses(snapshot.assignment_responses ?? [])
    setSelectedPickups(snapshot.selected_pickups)
    setNextStop(snapshot.next_stop[0] ?? null)
    if (snapshot.profile[0]?.company_name) setCompanyName(snapshot.profile[0].company_name)
    if (session.user.user_metadata?.account_kind === 'independent_rider') {
      const { data: offers, error: offerError } = await supabase.rpc('my_independent_rider_offers')
      if (offerError) setError(offerError.message)
      else setIndependentOffers(Array.isArray(offers) ? offers as IndependentOffer[] : [])
    }
  }, [session, supabase, clearDashboard])
  useEffect(() => { const timer = window.setTimeout(() => { void load() }, 0); return () => window.clearTimeout(timer) }, [load])
  useEffect(() => {
    if (session?.user.user_metadata?.account_kind !== 'independent_rider' || rider) return
    void supabase.rpc('list_independent_rider_companies').then(({ data, error }) => {
      if (error) setError(error.message)
      else setCompanies(Array.isArray(data) ? data as Array<{ id: string; name: string }> : [])
    })
  }, [session, rider, supabase])
  useEffect(() => {
    if (!session?.user || !rider) return
    const refresh = () => { if (document.visibilityState === 'visible') void load() }
    const timer = window.setInterval(refresh, 10000)
    document.addEventListener('visibilitychange', refresh)
    return () => { window.clearInterval(timer); document.removeEventListener('visibilitychange', refresh) }
  }, [session, rider, load])
  useEffect(() => {
    if (!session?.user || !rider) return
    const check = async (force = false) => {
      if (!force && document.visibilityState === 'visible' && Date.now() - lastAccessCheckAt.current < 15_000) return
      const { data, error } = await supabase.rpc('rider_session_active')
      if (error) { lastAccessCheckAt.current = 0; return }
      lastAccessCheckAt.current = Date.now()
      if (data === false) {
        loadGeneration.current++
        clearDashboard()
        setError('Your rider access has ended. Ask company management for a new password.')
        await supabase.auth.signOut()
      }
    }
    const timer = window.setInterval(() => { void check() }, 15000)
    const focused = () => { void check(true) }
    window.addEventListener('focus', focused)
    return () => { window.clearInterval(timer); window.removeEventListener('focus', focused) }
  }, [rider, session, supabase, clearDashboard])

  async function signIn(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (busy) return
    const riderToken = token()
    const companyId = company()
    if (!/^[0-9a-f]{64}$/.test(riderToken) && !/^[0-9a-f-]{36}$/.test(companyId)) { setError('Ask your company management for your rider link.'); return }
    const password = String(new FormData(event.currentTarget).get('password') ?? '')
    setBusy(true); setError(''); setNotice('')
    try {
      const credentials = riderToken ? { token: riderToken } : { companyId }
      const challenge = await access({ action: 'challenge', ...credentials, password })
      const proof = await riderDeviceProof(String(challenge.riderId ?? riderToken), typeof challenge.challenge === 'string' ? challenge.challenge : undefined)
      const result = await access({ action: 'login', ...credentials, password, deviceLabel: await deviceLabel(), ...proof })
      const auth = result.session as Session
      if (!auth?.access_token || !auth.refresh_token) throw new Error('Rider sign-in could not be completed')
      const { error: sessionError } = await supabase.auth.setSession({ access_token: auth.access_token, refresh_token: auth.refresh_token })
      if (sessionError) throw sessionError
    } catch (cause) { setError(cause instanceof Error ? cause.message : 'Could not sign in. Contact your company management.') }
    finally { setBusy(false) }
  }

  async function signInIndependent(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const form = new FormData(event.currentTarget)
    setBusy(true); setError('')
    const { error: authError } = await supabase.auth.signInWithPassword({
      email: String(form.get('email') ?? '').trim(), password: String(form.get('password') ?? ''),
    })
    if (authError) setError(authError.message)
    setBusy(false)
  }

  async function registerIndependent(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const form = new FormData(event.currentTarget)
    setBusy(true); setError('')
    const { error: registrationError } = await supabase.rpc('register_independent_rider', {
      p_partner_id: String(form.get('partner_id') ?? ''), p_phone: String(form.get('phone') ?? '').trim(),
    })
    if (registrationError) setError(registrationError.message)
    else { setNotice('Your rider workspace is ready.'); await load() }
    setBusy(false)
  }

  async function respondIndependent(offer: IndependentOffer, accept: boolean) {
    setBusy(true); setError('')
    const { error: responseError } = await supabase.rpc('respond_independent_rider_offer', {
      p_request_id: offer.request_id, p_accept: accept,
    })
    if (responseError) setError(responseError.message)
    else { setNotice(accept ? 'Delivery accepted. Wait for customer payment before moving.' : 'Delivery declined.'); await load() }
    setBusy(false)
  }

  async function uploadIndependentPhoto(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!session) return
    const file = (event.currentTarget.elements.namedItem('photo') as HTMLInputElement | null)?.files?.[0]
    if (!file) return
    if (!['image/jpeg', 'image/png', 'image/webp'].includes(file.type) || file.size > 5_242_880) {
      setError('Choose a JPG, PNG, or WebP photo under 5 MB.'); return
    }
    setBusy(true); setError('')
    const extension = file.type === 'image/png' ? 'png' : file.type === 'image/webp' ? 'webp' : 'jpg'
    const path = `independent/${session.user.id}/${crypto.randomUUID()}.${extension}`
    const uploaded = await supabase.storage.from('rider-evidence').upload(path, file, { contentType: file.type })
    if (uploaded.error) setError(uploaded.error.message)
    else {
      const { error: saveError } = await supabase.rpc('set_own_independent_rider_photo', { p_photo_path: path })
      if (saveError) setError(saveError.message)
      else setNotice('Your rider photo is saved. Customers can now identify you at pickup.')
    }
    setBusy(false)
  }

  async function advance(job: RiderJob, status: string) {
    if (busy) return
    setBusy(true); setError(''); setNotice('')
    const { error: updateError } = await supabase.rpc('rider_update_job_status', { p_job_id: job.job_id, p_new_status: status })
    if (updateError) setError(updateError.message)
    else { setNotice(`${job.job_number}: ${label(status)}.`); await load() }
    setBusy(false)
  }

  async function acceptAssignment(job: RiderJob) {
    if (busy) return
    setBusy(true); setError('')
    const { data, error: acceptError } = await supabase.rpc('accept_rider_assignment', { p_job_id: job.job_id })
    if (acceptError) setError(acceptError.message)
    else if (!data) setError('This ride is no longer assigned to you. Refresh your jobs.')
    else {
      window.KwikParselNative?.postMessage?.(JSON.stringify({ type: 'ride:stop-alarm', jobId: job.job_id }))
      setNotice(`${job.job_number}: ride accepted. Head to the pickup.`)
    }
    await load()
    setBusy(false)
  }

  async function confirmPickup(job: RiderJob) {
    if (busy) return
    setBusy(true); setError(''); setNotice('')
    const { data, error: verifyError } = await supabase.rpc('verify_pickup_handoff_code', {
      p_job_id: job.job_id, p_code: pickupCodes[job.job_id] ?? '',
    })
    if (verifyError) setError(verifyError.message)
    else if (!data?.verified) setError(`Incorrect pickup code. ${data?.attempts_remaining ?? 0} attempts left.`)
    else {
      setPickupCodes((current) => { const next = { ...current }; delete next[job.job_id]; return next })
      setNotice(`${job.job_number}: parcel collected from sender.`)
      await load()
    }
    setBusy(false)
  }

  async function sendCode(job: RiderJob) {
    setBusy(true); setError(''); setNotice('')
    const { error: sendError } = await supabase.functions.invoke('delivery-otp', { body: { jobId: job.job_id } })
    if (sendError) setError(sendError.message)
    else setNotice(`A delivery code was sent to the recipient for ${job.job_number}.`)
    setBusy(false)
  }

  async function verifyCode(job: RiderJob) {
    setBusy(true); setError(''); setNotice('')
    const { data, error: verifyError } = await supabase.rpc('verify_delivery_otp', { p_job_id: job.job_id, p_code: codes[job.job_id] ?? '' })
    if (verifyError) setError(verifyError.message)
    else if (!data?.verified) setError('That code is incorrect. Ask the recipient to check it.')
    else {
      setCodes((current) => { const next = { ...current }; delete next[job.job_id]; return next })
      setNotice(`${job.job_number} delivered.`)
      await load()
    }
    setBusy(false)
  }

  async function askSenderToConfirm(job: RiderJob) {
    if (busy) return
    setBusy(true); setError(''); setNotice('')
    const { error: requestError } = await supabase.rpc('request_sender_delivery_confirmation', { p_job_id: job.job_id })
    if (requestError) setError(requestError.message)
    else {
      setSenderConfirmationRequested((current) => ({ ...current, [job.job_id]: true }))
      setNotice(`The sender has been asked to verify arrival for ${job.job_number}. Wait for their answer.`)
    }
    setBusy(false)
  }

  return <main className="app-shell rider-shell">
    <header className="topbar"><a className="brand" href="/rider"><span className="brand-mark">K</span><span><strong>KWIK-PARSEL</strong><small>RIDER</small></span></a>
      {session && <button className="text-button" onClick={() => void (async () => { await clearRideAlerts(supabase); await supabase.auth.signOut() })()}>Sign out</button>}</header>
    {!ready ? <div className="loading">Preparing rider access...</div> : !session ? <section className="form-card narrow rider-login" aria-label="Rider sign in">
      <p className="eyebrow">RIDER ACCESS</p><h1>Welcome back</h1>
      {(token() || company()) && <form className="form-grid" onSubmit={(event) => void signIn(event)}><label className="field"><span>Your password</span><input name="password" type="password" autoComplete="current-password" required /></label>
        <button className="primary-button" disabled={busy}>{busy ? 'Signing in...' : 'Sign in'}</button></form>}
      {!token() && !company() && <><p className="form-footnote">Independent rider? Sign in with your email below.</p>
      <form className="form-grid" onSubmit={(event) => void signInIndependent(event)}><label className="field"><span>Email</span><input name="email" type="email" required /></label><label className="field"><span>Password</span><input name="password" type="password" required /></label><button className="secondary-button" disabled={busy}>Sign in with email</button></form></>}
    </section> : rider === null ? <div className="loading">Checking rider access...</div> : !rider && session.user.user_metadata?.account_kind === 'independent_rider' ? <section className="form-card narrow"><h1>Choose your logistics company</h1><p>Use the company you ride under. Your offers and deliveries stay linked to that company.</p><form className="form-grid" onSubmit={(event) => void registerIndependent(event)}><label className="field"><span>Company</span><select name="partner_id" required defaultValue=""><option value="" disabled>Select company</option>{companies.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label><label className="field"><span>Your phone number</span><input name="phone" type="tel" defaultValue={session.user.user_metadata?.phone ?? ''} required /></label><button className="primary-button" disabled={busy || companies.length === 0}>{busy ? 'Joining...' : 'Join company'}</button></form></section> : !rider ? <section className="form-card narrow"><h1>Rider access only</h1><p>Sign out of your current account to use a company rider link.</p></section> : <section className="rider-workspace">
      <RideAlerts supabase={supabase} userId={session.user.id} kind="rider" />
      <div className="dashboard-heading"><div><p className="eyebrow">YOUR RIDES</p><h1>{session.user.user_metadata?.full_name ?? 'Rider'}</h1><p>{companyName}</p></div><button className="secondary-button" onClick={() => void load()}>Refresh jobs</button></div>
      <RiderAvailability supabase={supabase} />
      {session.user.user_metadata?.account_kind === 'independent_rider' && <form className="form-card form-grid" onSubmit={(event) => void uploadIndependentPhoto(event)}><label className="field"><span>Your rider photo</span><input name="photo" type="file" accept="image/jpeg,image/png,image/webp" required /></label><button className="secondary-button" disabled={busy}>Save photo</button></form>}
      {session.user.user_metadata?.account_kind === 'independent_rider' && <section className="form-card" aria-label="Direct delivery offers"><h2>Delivery offers</h2>{independentOffers.length === 0 ? <p>No matching offers right now.</p> : independentOffers.map((offer) => <article className="partner-job-card" key={offer.request_id}><strong>{offer.request_number}</strong><p>{offer.pickup_address} → {offer.delivery_address}</p><p>{offer.parcel_summary}</p><strong>Price: ₦{offer.customer_price_ngn.toLocaleString()} · Company share: ₦{Number(offer.company_share_ngn).toLocaleString()}</strong><p>Offer closes {new Date(offer.deadline_at).toLocaleTimeString('en-NG')}</p><div className="field-row"><button className="primary-button" disabled={busy} onClick={() => void respondIndependent(offer,true)}>Accept delivery</button><button className="secondary-button" disabled={busy} onClick={() => void respondIndependent(offer,false)}>Decline</button></div></article>)}</section>}
      <RiderNextStop stop={nextStop} jobs={jobs} />
      {selectedPickups.length > 0 && <section aria-label="Selected pickups"><h2>Upcoming pickups</h2><div className="partner-assignment-list">{selectedPickups.map((pickup) => <article className="form-card partner-job-card" key={pickup.request_id}>
        <p className="eyebrow">{pickup.request_number} · {pickup.company_name}</p><h3>Company bid selected</h3>
        <p className="customer-route-label">{routeLabel(pickup.pickup_address, pickup.pickup_city, pickup.delivery_address, pickup.delivery_city)}</p><p>{pickup.parcel_summary}</p>
        <p>Waiting for customer payment. Do not travel, contact the customer, or collect the parcel. This task becomes actionable only when a confirmed job appears here.</p>
      </article>)}</div></section>}
      {jobs.length === 0 && selectedPickups.length === 0 ? <section className="form-card"><h2>No jobs assigned yet</h2><p>Your company will assign deliveries here.</p></section> : jobs.length > 0 && <div className="partner-assignment-list">{jobs.map((job) => <article className="form-card partner-job-card" key={job.job_id}>
        <div className="review-title"><div><p className="eyebrow">{job.job_number}</p><h2>{label(job.status)}</h2></div></div>
        {assignmentResponses?.some((response) => response.job_id === job.job_id && !response.accepted_at) &&
          <div className="delivery-otp-panel" role="alert"><strong>New ride: accept within one minute</strong><button className="primary-button" disabled={busy} onClick={() => void acceptAssignment(job)}>Accept ride</button></div>}
        {(job.sender_name || job.sender_phone) && <p><strong>Sender: {job.sender_name || 'Name unavailable'} · {job.sender_phone || 'Phone unavailable'}</strong></p>}
        {job.latitude != null && job.longitude != null && <p><a href={`https://www.google.com/maps/search/?api=1&query=${job.latitude},${job.longitude}`} target="_blank" rel="noreferrer">Open pickup directions</a></p>}
        <p>{job.parcel_summary}</p><div className="partner-job-route"><div><small>PICKUP</small><p>{job.pickup_address}<br />{job.pickup_city}</p></div><div><small>DELIVER TO</small><p>{job.delivery_address}<br />{job.delivery_city}</p><strong>{job.recipient_name} · {job.recipient_phone}</strong></div></div>
        {job.delivery_latitude != null && job.delivery_longitude != null && <p><a href={`https://www.google.com/maps/search/?api=1&query=${job.delivery_latitude},${job.delivery_longitude}`} target="_blank" rel="noreferrer">Open delivery pin</a></p>}
        {(nextStatus[job.status] ?? []).length === 1 && nextStatus[job.status][0] === 'exception' ? <button className="secondary-button" disabled={busy} onClick={() => void advance(job, 'exception')}>Report a problem</button> : (nextStatus[job.status] ?? []).length > 0 && <label className="field"><span>Update delivery</span><select disabled={busy} value="" onChange={(event) => { if (event.target.value) void advance(job, event.target.value) }}><option value="">Choose next step</option>{nextStatus[job.status].map((status) => <option key={status} value={status}>{label(status)}</option>)}</select></label>}
        {['partner_assigned','pickup_scheduled'].includes(job.status) && !assignmentResponses?.some((response) => response.job_id === job.job_id && !response.accepted_at) && <section className="delivery-otp-panel" aria-label={`Pickup code for ${job.job_number}`}><label className="field"><span>Sender pickup code</span><input inputMode="numeric" autoComplete="one-time-code" value={pickupCodes[job.job_id] ?? ''} onChange={(event) => setPickupCodes((current) => ({ ...current, [job.job_id]: event.target.value.replace(/\D/g, '').slice(0, 8) }))} maxLength={8} placeholder="8-digit code" /></label><button className="primary-button" disabled={busy || (pickupCodes[job.job_id] ?? '').length !== 8} onClick={() => void confirmPickup(job)}>Confirm parcel collected</button></section>}
        {['in_transit','picked_up','out_for_delivery'].includes(job.status) && <section className="delivery-otp-panel"><button className="secondary-button" disabled={busy} onClick={() => void sendCode(job)}>Send recipient code</button><label className="field"><span>Recipient code</span><input inputMode="numeric" value={codes[job.job_id] ?? ''} onChange={(event) => setCodes((current) => ({ ...current, [job.job_id]: event.target.value.replace(/\D/g, '').slice(0, 6) }))} maxLength={6} /></label><button className="primary-button" disabled={busy || (codes[job.job_id] ?? '').length !== 6} onClick={() => void verifyCode(job)}>Confirm delivery</button><p>If the recipient cannot provide a code, call the sender at {job.sender_phone || 'the pickup number'}. Ask them to confirm only after they have independently checked that the recipient received the parcel.</p><button className="secondary-button" type="button" disabled={busy || !!senderConfirmationRequested[job.job_id]} onClick={() => void askSenderToConfirm(job)}>{senderConfirmationRequested[job.job_id] ? 'Waiting for sender confirmation' : 'Ask sender to confirm delivery'}</button></section>}
      </article>)}</div>}
    </section>}
    {error && <div className="toast toast-error" role="alert"><span>{error}</span><button type="button" onClick={() => setError('')}>Close</button></div>}
    {notice && <div className="toast toast-success" role="status"><span>{notice}</span><button type="button" onClick={() => setNotice('')}>Close</button></div>}
    <footer className="page-footer"><a href="/privacy-policy.html">Privacy</a><a href="/delete-account">Delete account</a></footer>
  </main>
}
