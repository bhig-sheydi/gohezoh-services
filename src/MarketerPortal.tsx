import { useEffect, useState } from 'react'
import type { getSupabaseClient } from './lib/supabase'

type Supabase = ReturnType<typeof getSupabaseClient>
type Earning = { id: string; job_id: string; eligible_amount_ngn: number; calculated_amount_ngn: number; status: string; payment_reference: string | null; created_at: string }
type Payout = { id: string; commission_type: string; amount_ngn: number; entry_count: number; transfer_reference: string | null; paid_at: string; gross_amount_ngn: number; offset_amount_ngn: number }

export function MarketerPortal({ supabase, onError }: { supabase: Supabase; onError: (message: string) => void }) {
  const [code, setCode] = useState('')
  const [referrals, setReferrals] = useState<number | null>(null)
  const [earnings, setEarnings] = useState<Earning[]>([])
  const [payouts, setPayouts] = useState<Payout[]>([])
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    let active = true
    void Promise.all([supabase.rpc('get_my_marketer_referral_code'), supabase.rpc('get_my_marketer_referral_count'), supabase.rpc('list_my_marketer_commissions'), supabase.rpc('list_my_commission_payouts')]).then(([codeResult, countResult, earningsResult, payoutsResult]) => {
      if (!active) return
      if (codeResult.error) onError(codeResult.error.message)
      else setCode(String(codeResult.data ?? ''))
      if (countResult.error) onError(countResult.error.message)
      else setReferrals(Number(countResult.data ?? 0))
      if (earningsResult.error) onError(earningsResult.error.message)
      else setEarnings((earningsResult.data ?? []) as Earning[])
      if (payoutsResult.error) onError(payoutsResult.error.message)
      else setPayouts((payoutsResult.data ?? []) as Payout[])
    })
    return () => { active = false }
  }, [onError, supabase])

  const link = code ? `${window.location.origin}/?ref=${encodeURIComponent(code)}` : ''
  async function copy() {
    if (!link) return
    try { await navigator.clipboard.writeText(link); setCopied(true) }
    catch { onError('Could not copy the link. Copy it from the field instead.') }
  }

  const total = earnings.reduce((sum, item) => sum + Number(item.calculated_amount_ngn), 0)
  return <main className="dashboard"><div className="dashboard-heading"><div><p className="eyebrow">MARKETER PORTAL</p><h1>Share your Kwik-Parsel link</h1><p className="section-intro">Customers who sign up through your link are attributed to you and your supervising BDO.</p></div></div>
    <section className="form-card"><p className="eyebrow">CUSTOMER ATTRIBUTION</p><h2>Your referral link</h2><div className="field-row"><label className="field"><span>Personal customer link</span><input aria-label="Personal marketer referral link" readOnly value={link || 'Preparing your link...'} /></label><button className="secondary-button" disabled={!link} onClick={() => void copy()}>{copied ? 'Copied' : 'Copy link'}</button></div><small>Earnings apply only to completed, paid transactions covered by your management-approved signed plan. Opportunity estimates do not count as commission.</small></section>
    <section className="finance-kpis"><article><span>Customer accounts referred</span><strong>{referrals === null ? '—' : referrals.toLocaleString('en-NG')}</strong></article><article><span>Calculated earnings</span><strong>₦{total.toLocaleString('en-NG', { maximumFractionDigits: 2 })}</strong></article></section>
    <section className="form-card"><p className="eyebrow">COMMISSION LEDGER</p><h2>Your eligible earnings</h2>{earnings.length === 0 ? <p>No eligible earnings yet. Commissions appear after a referred customer’s delivery is completed and their receipt is recorded under an approved plan.</p> : <div className="commission-plan-list">{earnings.map((item) => <article className="commission-plan-row" key={item.id}><div><strong>Job {item.job_id.slice(0, 8)}</strong><p>Collected ₦{Number(item.eligible_amount_ngn).toLocaleString('en-NG')} · Earned ₦{Number(item.calculated_amount_ngn).toLocaleString('en-NG')}</p><small>{item.payment_reference ? `Receipt ${item.payment_reference} · ` : ''}{new Date(item.created_at).toLocaleDateString('en-NG')}</small></div><span className="finance-status">{item.status.replaceAll('_', ' ')}</span></article>)}</div>}</section>
    <section className="form-card"><p className="eyebrow">PAYOUT HISTORY</p><h2>Recorded payouts and offsets</h2>{payouts.length === 0 ? <p>No transfers or offsets have been recorded yet.</p> : <div className="commission-plan-list">{payouts.map((payout) => <article className="commission-plan-row" key={payout.id}><div><strong>NGN {Number(payout.amount_ngn).toLocaleString('en-NG')} paid · {payout.entry_count} commission entries</strong><p>Gross NGN {Number(payout.gross_amount_ngn).toLocaleString('en-NG')} · Offset NGN {Number(payout.offset_amount_ngn).toLocaleString('en-NG')}{payout.transfer_reference ? ` · Transfer reference ${payout.transfer_reference}` : ' · No transfer due'}</p><small>{new Date(payout.paid_at).toLocaleDateString('en-NG')}</small></div><span className="finance-status finance-status-paid">{Number(payout.offset_amount_ngn) > 0 ? 'offset applied' : 'paid'}</span></article>)}</div>}</section>
  </main>
}
