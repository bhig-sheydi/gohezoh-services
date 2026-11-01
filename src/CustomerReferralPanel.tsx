import { useCallback, useEffect, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import './customer-referrals.css'

type Member = { code: string; display_name: string; rank: number; earned_ngn: number; completed_job_value_ngn: number }
type Leader = { rank: number; display_name: string; earned_ngn: number; completed_job_value_ngn: number }
type Dashboard = { year: number; member: Member | null; leaders: Leader[] }
const money = (amount: number) => new Intl.NumberFormat('en-NG', { style: 'currency', currency: 'NGN', maximumFractionDigits: 2 }).format(Number(amount) || 0)
const publicOrigin = (import.meta.env.VITE_PUBLIC_APP_URL || 'https://gohezoh-services.vercel.app').replace(/\/+$/, '')

export default function CustomerReferralPanel({ supabase, onError, onNotice }: { supabase: SupabaseClient;
  onError: (message: string) => void; onNotice: (message: string) => void }) {
  const [dashboard, setDashboard] = useState<Dashboard | null>(null)
  const [busy, setBusy] = useState(false)
  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc('my_customer_referral_dashboard')
    if (error) onError(error.message)
    else setDashboard(data as Dashboard)
  }, [supabase, onError])
  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => clearTimeout(timer) }, [load])

  async function join(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (busy) return
    setBusy(true)
    const alias = String(new FormData(event.currentTarget).get('display_name') ?? '').trim()
    const { error } = await supabase.rpc('join_customer_referral_program', { p_display_name: alias || null })
    if (error) onError(error.message)
    else { onNotice('You joined the referral program. Your link is ready to share.'); await load() }
    setBusy(false)
  }
  async function copy(value: string) {
    try { await navigator.clipboard.writeText(value); onNotice('Referral link copied.') }
    catch { onError('Copy failed. Press and hold the link to select it.') }
  }

  const member = dashboard?.member
  const customerLink = member ? `${publicOrigin}/?ref=${encodeURIComponent(member.code)}` : ''
  return <section className="customer-referral-panel" aria-label="Customer referral program">
    <header><div><p className="eyebrow">REFER & EARN</p><h2>Kwik-Parsel marketer program</h2></div><span className="customer-referral-prize">₦1 million year-end prize</span></header>
    <p>Refer a customer or a new logistics company. For each completed, paid job they bring, you earn 2.5% of Kwik-Parsel’s 25% share from that side. If you refer both sides of one job, both eligible shares count.</p>
    <p className="customer-referral-rule">The highest completed referred-job value in {dashboard?.year ?? new Date().getFullYear()} wins the ₦1 million prize, provided it reaches at least ₦500,000. Results are provisional until year-end checks.</p>
    {!dashboard ? <p>Loading referral program…</p> : !member ? <form className="customer-referral-join" onSubmit={(event) => void join(event)}>
      <label className="field"><span>Public leaderboard name</span><input name="display_name" minLength={3} maxLength={40} placeholder="Optional · a private alias is generated" /></label>
      <button className="primary-button" disabled={busy}>{busy ? 'Joining…' : 'Join referral program'}</button>
      <small>Joining is optional. Your contact details are never shown on the leaderboard.</small>
    </form> : <>
      <div className="customer-referral-stats">
        <div><span>Your rank</span><strong>#{member.rank}</strong></div>
        <div><span>Earned this year</span><strong>{money(member.earned_ngn)}</strong></div>
        <div><span>Completed referred jobs</span><strong>{money(member.completed_job_value_ngn)}</strong></div>
      </div>
      <div className="customer-referral-links">
        <label className="field"><span>Your referral code</span><input readOnly value={member.code} aria-label="Your customer referral code" /></label>
        <label className="field"><span>Shareable signup link</span><input readOnly value={customerLink} aria-label="Your customer referral link" /></label>
        <button className="secondary-button" type="button" onClick={() => void copy(customerLink)}>Copy link</button>
      </div>
      <small>Send the same link to a new customer or logistics company. They can also type {member.code} during signup. Company referrals count after approval and completed paid deliveries.</small>
      <div className="customer-referral-progress"><span>Year-end prize minimum</span><progress max={500000} value={Math.min(500000, Number(member.completed_job_value_ngn))} /><strong>{money(member.completed_job_value_ngn)} / ₦500,000</strong></div>
    </>}
    <div className="customer-referral-leaderboard"><h3>{dashboard?.year ?? new Date().getFullYear()} leaderboard</h3>
      {!dashboard?.leaders?.length ? <p>No earnings yet. Completed and paid jobs will appear here.</p> : <ol>{dashboard.leaders.map((leader) => <li key={`${leader.rank}-${leader.display_name}`}><span>#{leader.rank} {leader.display_name}</span><strong>{money(leader.earned_ngn)}</strong><small>{money(leader.completed_job_value_ngn)} in jobs</small></li>)}</ol>}
    </div>
  </section>
}
