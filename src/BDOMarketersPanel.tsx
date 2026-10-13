import { useCallback, useEffect, useState, type FormEvent } from 'react'
import type { getSupabaseClient } from './lib/supabase'

type Supabase = ReturnType<typeof getSupabaseClient>
type Marketer = { marketer_user_id: string; email: string; full_name: string | null; active: boolean; created_at: string }
type Performance = { marketer_user_id: string; email: string; full_name: string | null; active: boolean; customer_count: number; active_customer_count: number; qualifying_transactions: number; qualifying_volume_ngn: number; commission_earned_ngn: number; pending_commission_ngn: number; approved_commission_ngn: number; paid_commission_ngn: number }

export function BDOMarketersPanel({ supabase, onError, onNotice }: {
  supabase: Supabase
  onError: (message: string) => void
  onNotice: (message: string) => void
}) {
  const [email, setEmail] = useState('')
  const [inviteLink, setInviteLink] = useState('')
  const [marketers, setMarketers] = useState<Marketer[]>([])
  const [performance, setPerformance] = useState<Performance[]>([])
  const [busy, setBusy] = useState(false)

  const load = useCallback(async () => {
    const [marketersResult, performanceResult] = await Promise.all([
      supabase.rpc('list_my_bdo_marketers'),
      supabase.rpc('list_my_bdo_marketer_performance'),
    ])
    if (marketersResult.error || performanceResult.error) onError((marketersResult.error ?? performanceResult.error)?.message ?? 'Could not load your marketer network.')
    else {
      setMarketers((marketersResult.data ?? []) as Marketer[])
      setPerformance((performanceResult.data ?? []) as Performance[])
    }
  }, [onError, supabase])

  useEffect(() => { const timer = window.setTimeout(() => { void load() }, 0); return () => window.clearTimeout(timer) }, [load])

  async function invite(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setBusy(true); onError(''); setInviteLink('')
    const { data, error } = await supabase.rpc('create_bdo_marketer_invite', { p_email: email.trim() })
    if (error) onError(error.message)
    else {
      const link = `${publicAppOrigin}/?marketer_invite=${encodeURIComponent(String(data))}`
      setInviteLink(link)
      setEmail('')
      onNotice('Invitation link created. Copy it and send it to the invited person. They must register with the invited email, confirm it, and wait for Super Admin approval.')
    }
    setBusy(false)
  }

  async function copyLink() {
    if (!inviteLink) return
    try { await navigator.clipboard.writeText(inviteLink); onNotice('Marketer invitation link copied.') }
    catch { onError('Copy failed. Select and copy the invitation link from the field.') }
  }

  return <section className="form-card"><p className="eyebrow">TEAM DEVELOPMENT</p><h2>Invite a marketer</h2>
    <p className="section-intro">Invite a person by email. Their account stays inactive until they confirm their email and a Super Admin approves the request.</p>
    <form className="field-row" onSubmit={(event) => void invite(event)}><label className="field"><span>Marketer email</span><input type="email" required value={email} onChange={(event) => setEmail(event.target.value)} /></label><button className="primary-button" disabled={busy}>{busy ? 'Creating link...' : 'Create invitation link'}</button></form>
    {inviteLink && <div className="field-row"><label className="field"><span>Invitation link</span><input readOnly value={inviteLink} /></label><button className="secondary-button" onClick={() => void copyLink()}>Copy link</button></div>}
    <div className="admin-list"><h3>Your marketers and their results</h3>{marketers.length === 0 ? <p>No approved marketers yet.</p> : performance.map((marketer) => <article className="admin-row" key={marketer.marketer_user_id}><div><strong>{marketer.full_name || marketer.email}</strong><p>{marketer.active ? 'Active' : 'Revoked'} · {marketer.customer_count} referred customers ({marketer.active_customer_count} active)</p><small>{marketer.qualifying_transactions} qualifying transactions · {formatMoney(marketer.qualifying_volume_ngn)} eligible volume · {formatMoney(marketer.commission_earned_ngn)} commission earned</small><small>Pending {formatMoney(marketer.pending_commission_ngn)} · Approved {formatMoney(marketer.approved_commission_ngn)} · Paid {formatMoney(marketer.paid_commission_ngn)}</small></div></article>)}</div>
    <small>Marketer referrals are recorded for acquisition reporting. They do not create a commission until qualifying payment is collected and the approved plan applies.</small>
  </section>
}

const publicAppOrigin = (import.meta.env.VITE_PUBLIC_APP_URL || 'https://gohezoh-services.vercel.app').replace(/\/+$/, '')
const formatMoney = (amount: number) => new Intl.NumberFormat('en-NG', { style: 'currency', currency: 'NGN', maximumFractionDigits: 0 }).format(Number(amount || 0))
