import { useCallback, useEffect, useState, type FormEvent } from 'react'
import type { Session } from '@supabase/supabase-js'
import { getSupabaseClient } from './lib/supabase'
import { riderDeviceProof } from './lib/rider-device'
import RiderAvailability from './RiderAvailability'
import './App.css'
import './dark.css'

type RiderJob = { job_id: string; job_number: string; status: string; pickup_address: string; pickup_city: string;
  delivery_address: string; delivery_city: string; recipient_name: string; recipient_phone: string;
  parcel_summary: string; company_name: string; latitude?: number | null; longitude?: number | null; delivery_latitude?: number | null; delivery_longitude?: number | null; sender_name?: string; sender_phone?: string }
type SelectedPickup = { request_id: string; request_number: string; pickup_city: string; delivery_city: string;
  parcel_summary: string | null; company_name: string; selected_at: string }
const nextStatus: Record<string, string[]> = {
  partner_assigned: ['pickup_scheduled', 'picked_up', 'exception'], pickup_scheduled: ['picked_up', 'exception'],
  picked_up: ['in_transit', 'exception'], in_transit: ['out_for_delivery', 'exception'],
  out_for_delivery: ['exception'], exception: ['pickup_scheduled', 'picked_up', 'in_transit', 'out_for_delivery'],
}
const label = (status: string) => status.replaceAll('_', ' ').replace(/^./, (letter) => letter.toUpperCase())
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
  const [selectedPickups, setSelectedPickups] = useState<SelectedPickup[]>([])
  const [companyName, setCompanyName] = useState('Company rider')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [codes, setCodes] = useState<Record<string, string>>({})
  useEffect(() => {
    void supabase.auth.getSession().then(({ data }) => { setSession(data.session); setReady(true) })
    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, next) => { setSession(next); setRider(null) })
    return () => subscription.unsubscribe()
  }, [supabase])
  const load = useCallback(async () => {
    if (!session?.user) return
    const { data: role } = await supabase.from('user_roles').select('role').eq('user_id', session.user.id).eq('role', 'rider').maybeSingle()
    setRider(Boolean(role))
    if (!role) return
    const [{ data, error: loadError }, profile, pickupLocations, deliveryLocations, selected] = await Promise.all([
      supabase.rpc('list_my_rider_jobs'), supabase.rpc('my_rider_profile'), supabase.rpc('list_my_rider_pickup_locations'), supabase.rpc('list_my_rider_delivery_locations'), supabase.rpc('list_my_selected_pickups'),
    ])
    if (loadError || selected.error) setError((loadError ?? selected.error)?.message ?? 'Could not load pickups')
    else setJobs(((data ?? []) as RiderJob[]).map((job) => {
      const delivery = Array.isArray(deliveryLocations.data) ? deliveryLocations.data.find((location: { job_id: string }) => location.job_id === job.job_id) : null
      return { ...job, ...(Array.isArray(pickupLocations.data) ? pickupLocations.data.find((location: { job_id: string }) => location.job_id === job.job_id) : {}),
        delivery_latitude: delivery?.latitude, delivery_longitude: delivery?.longitude }
    }))
    if (!selected.error) setSelectedPickups((selected.data ?? []) as SelectedPickup[])
    if (!profile.error && profile.data?.[0]?.company_name) setCompanyName(String(profile.data[0].company_name))
  }, [session, supabase])
  useEffect(() => { const timer = window.setTimeout(() => { void load() }, 0); return () => window.clearTimeout(timer) }, [load])
  useEffect(() => {
    if (!session?.user || !rider) return
    const refresh = () => { if (document.visibilityState === 'visible') void load() }
    const timer = window.setInterval(refresh, 10000)
    document.addEventListener('visibilitychange', refresh)
    return () => { window.clearInterval(timer); document.removeEventListener('visibilitychange', refresh) }
  }, [session, rider, load])

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

  async function advance(job: RiderJob, status: string) {
    if (busy) return
    setBusy(true); setError(''); setNotice('')
    const { error: updateError } = await supabase.rpc('rider_update_job_status', { p_job_id: job.job_id, p_new_status: status })
    if (updateError) setError(updateError.message)
    else { setNotice(`${job.job_number}: ${label(status)}.`); await load() }
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
    else await advanceAfterCode(job)
    setBusy(false)
  }

  async function advanceAfterCode(job: RiderJob) {
    const { error: updateError } = await supabase.rpc('rider_update_job_status', { p_job_id: job.job_id, p_new_status: 'delivered' })
    if (updateError) setError(updateError.message)
    else { setNotice(`${job.job_number} delivered.`); await load() }
  }

  return <main className="app-shell rider-shell">
    <header className="topbar"><a className="brand" href="/rider"><span className="brand-mark">K</span><span><strong>KWIK-PARSEL</strong><small>RIDER</small></span></a>
      {session && <button className="text-button" onClick={() => void supabase.auth.signOut()}>Sign out</button>}</header>
    {!ready ? <div className="loading">Preparing rider access...</div> : !session ? <section className="form-card narrow rider-login" aria-label="Rider sign in">
      <p className="eyebrow">COMPANY RIDER</p><h1>Welcome back</h1>
      <form className="form-grid" onSubmit={(event) => void signIn(event)}><label className="field"><span>Your password</span><input name="password" type="password" autoComplete="current-password" required /></label>
        <button className="primary-button" disabled={busy}>{busy ? 'Signing in...' : 'Sign in'}</button></form>
    </section> : rider === null ? <div className="loading">Checking rider access...</div> : !rider ? <section className="form-card narrow"><h1>Rider access only</h1><p>Sign out of your current account to use a company rider link.</p></section> : <section className="rider-workspace">
      <div className="dashboard-heading"><div><p className="eyebrow">YOUR RIDES</p><h1>{session.user.user_metadata?.full_name ?? 'Rider'}</h1><p>{companyName}</p></div><button className="secondary-button" onClick={() => void load()}>Refresh jobs</button></div>
      <RiderAvailability supabase={supabase} />
      {selectedPickups.length > 0 && <section aria-label="Selected pickups"><h2>Upcoming pickups</h2><div className="partner-assignment-list">{selectedPickups.map((pickup) => <article className="form-card partner-job-card" key={pickup.request_id}>
        <p className="eyebrow">{pickup.request_number} · {pickup.company_name}</p><h3>Company bid selected</h3>
        <p>{pickup.pickup_city} → {pickup.delivery_city}</p><p>{pickup.parcel_summary}</p>
        <p>Prepare for this pickup. Wait for the confirmed job here before contacting the customer or collecting the parcel.</p>
      </article>)}</div></section>}
      {jobs.length === 0 && selectedPickups.length === 0 ? <section className="form-card"><h2>No jobs assigned yet</h2><p>Your company will assign deliveries here.</p></section> : jobs.length > 0 && <div className="partner-assignment-list">{jobs.map((job) => <article className="form-card partner-job-card" key={job.job_id}>
        <div className="review-title"><div><p className="eyebrow">{job.job_number}</p><h2>{label(job.status)}</h2></div></div>
        {job.latitude != null && job.longitude != null && <p><strong>{job.sender_name} · {job.sender_phone}</strong><br /><a href={`https://www.google.com/maps/search/?api=1&query=${job.latitude},${job.longitude}`} target="_blank" rel="noreferrer">Open pickup directions</a></p>}
        <p>{job.parcel_summary}</p><div className="partner-job-route"><div><small>PICKUP</small><p>{job.pickup_address}<br />{job.pickup_city}</p></div><div><small>DELIVER TO</small><p>{job.delivery_address}<br />{job.delivery_city}</p><strong>{job.recipient_name} · {job.recipient_phone}</strong></div></div>
        {job.delivery_latitude != null && job.delivery_longitude != null && <p><a href={`https://www.google.com/maps/search/?api=1&query=${job.delivery_latitude},${job.delivery_longitude}`} target="_blank" rel="noreferrer">Open delivery pin</a></p>}
        {(nextStatus[job.status] ?? []).length > 0 && <label className="field"><span>Update delivery</span><select disabled={busy} value="" onChange={(event) => { if (event.target.value) void advance(job, event.target.value) }}><option value="">Choose next step</option>{nextStatus[job.status].map((status) => <option key={status} value={status}>{label(status)}</option>)}</select></label>}
        {job.status === 'out_for_delivery' && <section className="delivery-otp-panel"><button className="secondary-button" disabled={busy} onClick={() => void sendCode(job)}>Send recipient code</button><label className="field"><span>Recipient code</span><input inputMode="numeric" value={codes[job.job_id] ?? ''} onChange={(event) => setCodes((current) => ({ ...current, [job.job_id]: event.target.value.replace(/\D/g, '').slice(0, 6) }))} maxLength={6} /></label><button className="primary-button" disabled={busy || (codes[job.job_id] ?? '').length !== 6} onClick={() => void verifyCode(job)}>Confirm delivery</button></section>}
      </article>)}</div>}
    </section>}
    {error && <div className="toast toast-error" role="alert"><span>{error}</span><button type="button" onClick={() => setError('')}>Close</button></div>}
    {notice && <div className="toast toast-success" role="status"><span>{notice}</span><button type="button" onClick={() => setNotice('')}>Close</button></div>}
  </main>
}
