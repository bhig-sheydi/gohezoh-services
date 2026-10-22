import { useCallback, useEffect, useState, type FormEvent } from 'react'
import type { Session, SupabaseClient } from '@supabase/supabase-js'
import { getSupabaseClient } from './lib/supabase'
import { riderDeviceProof } from './lib/rider-device'
import PartnerCompanyWelcome from './PartnerCompanyWelcome'
import PartnerBidScreen from './PartnerBidScreen'
import { PartnerRidersPanel } from './PartnerOrganizationPanel'
import './App.css'
import './dark.css'
import './company-operations-staff.css'

type Access = { staff_id: string; partner_id: string; full_name: string; can_bid: boolean; can_manage_riders: boolean; can_withdraw: boolean }
const staffId = () => new URLSearchParams(window.location.hash.replace(/^#/, '')).get('staff') ?? ''
const deviceKind = () => (/(Android|iPhone|iPad|Mobile)/i.test(navigator.userAgent) ? 'phone' : 'desktop')
async function request(body: Record<string, unknown>) {
  const response = await fetch(`${import.meta.env.VITE_SUPABASE_URL}/functions/v1/company-staff-access`, {
    method: 'POST', headers: { 'content-type': 'application/json', apikey: import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY },
    body: JSON.stringify(body),
  })
  const result = await response.json() as Record<string, unknown>
  if (!response.ok) throw new Error(String(result.error ?? 'Company staff access is unavailable'))
  return result
}
export function CompanyStaffLogin() {
  const supabase = getSupabaseClient()
  const [session, setSession] = useState<Session | null>(null)
  const [ready, setReady] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  useEffect(() => {
    let saved: string | null = null
    try { saved = window.localStorage.getItem('gohezoh-theme') } catch { /* Browser storage may be unavailable. */ }
    document.documentElement.dataset.theme = saved === 'dark' ? 'dark' : 'light'
  }, [])
  useEffect(() => { void supabase.auth.getSession().then(({ data }) => { setSession(data.session); setReady(true) }) }, [supabase])
  async function signIn(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); if (busy) return
    const id = staffId()
    if (!/^[0-9a-f-]{36}$/i.test(id)) { setError('Ask the company owner for your private staff link.'); return }
    const password = String(new FormData(event.currentTarget).get('password') ?? '')
    const kind = deviceKind()
    setBusy(true); setError('')
    try {
      const challenge = await request({ action: 'challenge', staffId: id, password, deviceKind: kind })
      const proof = await riderDeviceProof(`company-staff:${id}:${kind}`, typeof challenge.challenge === 'string' ? challenge.challenge : undefined)
      const result = await request({ action: 'login', staffId: id, password, deviceKind: kind,
        deviceLabel: `${kind === 'phone' ? 'Phone' : 'Laptop'} · ${navigator.userAgent.slice(0, 75)}`, ...proof })
      const signed = result.session as Session
      if (!signed?.access_token || !signed.refresh_token) throw new Error('Sign-in could not be completed')
      const { error: sessionError } = await supabase.auth.setSession({ access_token: signed.access_token, refresh_token: signed.refresh_token })
      if (sessionError) throw sessionError
      window.location.assign('/')
    } catch (cause) { setError(cause instanceof Error ? cause.message : 'Could not sign in') }
    finally { setBusy(false) }
  }
  return <main className="app-shell"><header className="topbar"><a href="/" className="brand"><img className="brand-mark" src="/favicon.svg" alt="" /><span><strong>KWIK-PARSEL</strong><small>COMPANY STAFF</small></span></a></header>
    {!ready ? <div className="loading">Preparing staff sign-in...</div> : session ? <section className="form-card narrow"><h1>Already signed in</h1><a href="/">Open your dashboard</a></section> : <section className="form-card narrow rider-login"><p className="eyebrow">COMPANY OPERATIONS</p><h1>Welcome back</h1><form className="form-grid" onSubmit={(event) => void signIn(event)}><label className="field"><span>Your password</span><input name="password" type="password" autoComplete="current-password" required /></label><button className="primary-button" disabled={busy}>{busy ? 'Signing in...' : 'Sign in'}</button></form></section>}
    {error && <div role="alert" className="toast toast-error">{error}</div>}
  </main>
}
export function CompanyStaffDashboard({ supabase, userId, onError, onNotice }: { supabase: SupabaseClient; userId: string; onError: (message: string) => void; onNotice: (message: string) => void }) {
  const [access, setAccess] = useState<Access | null>(null)
  const [ready, setReady] = useState(false)
  const refresh = useCallback(async () => {
    const { data, error } = await supabase.rpc('my_company_operations_staff')
    if (error) { setAccess(null); setReady(true); onError(error.message); return }
    if (!Array.isArray(data) || data.length !== 1) {
      setAccess(null); setReady(true); await supabase.auth.signOut(); return
    }
    const next = data[0] as Access
    setAccess(next); setReady(true)
  }, [onError, supabase])
  useEffect(() => { const timer = window.setTimeout(() => { void refresh() }, 0); const poll = window.setInterval(() => { void refresh() }, 15000); return () => { window.clearTimeout(timer); window.clearInterval(poll) } }, [refresh])
  if (!ready) return <div className="loading">Checking staff permissions...</div>
  if (!access) return <div className="loading">Signing out of unavailable staff access...</div>
  const locked = (label: string) => <div className="company-staff-locked" aria-label={`${label} unavailable`}><div className="company-staff-locked-content" aria-hidden="true"><section className="form-card"><p className="eyebrow">COMPANY WORKSPACE</p><h2>{label}</h2><button className="secondary-button" disabled>Open</button></section></div><div className="company-staff-locked-note">Owner permission required for {label.toLowerCase()}</div></div>
  return <main className="partner-page company-staff-dashboard" aria-label="Company operations dashboard">
    <div className="dashboard-heading"><div><p className="eyebrow">COMPANY OPERATIONS</p><h1>Welcome, {access.full_name}</h1></div></div>
    {access.can_bid || access.can_manage_riders || access.can_withdraw ? <PartnerCompanyWelcome supabase={supabase} onError={onError} onNotice={onNotice} showPayout={access.can_withdraw} canEditLogo={false} /> : locked('Company overview')}
    {access.can_bid ? <PartnerBidScreen supabase={supabase} partnerIds={[access.partner_id]} onError={onError} onNotice={onNotice} /> : locked('Bidding')}
    {access.can_manage_riders ? <PartnerRidersPanel supabase={supabase} userId={userId} staffPartnerId={access.partner_id} onError={onError} onNotice={onNotice} /> : locked('Rider management')}
    {!access.can_withdraw && locked('Withdrawals')}
    {locked('Rider proximity')}
    {locked('Assigned deliveries')}
  </main>
}
