import { useCallback, useEffect, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'

type Attribution = { attribution_id: string; partner_id: string; partner_number: string; partner_name: string; partner_status: string; attribution_type: string; effective_from: string; attribution_status: string }
type Ledger = { id: string; partner_number: string | null; partner_name: string | null; job_id: string; job_number: string | null; eligible_amount_ngn: number; calculated_amount_ngn: number; status: string; payment_reference: string | null; created_at: string }
type NetworkShare = { id: string; job_id: string; eligible_contribution_ngn: number; calculated_amount_ngn: number; status: string; payment_reference: string | null; created_at: string }
type Payout = { id: string; commission_type: string; amount_ngn: number; entry_count: number; transfer_reference: string | null; paid_at: string; gross_amount_ngn: number; offset_amount_ngn: number }
const money = (value: number) => new Intl.NumberFormat('en-NG', { style: 'currency', currency: 'NGN' }).format(value)

export default function BdoTransparencyPanel({ supabase, onError }: { supabase: SupabaseClient; onError: (message: string) => void }) {
  const [attributions, setAttributions] = useState<Attribution[]>([])
  const [ledger, setLedger] = useState<Ledger[]>([])
  const [networkShares, setNetworkShares] = useState<NetworkShare[]>([])
  const [payouts, setPayouts] = useState<Payout[]>([])
  const [from, setFrom] = useState('')
  const [to, setTo] = useState('')
  const load = useCallback(async () => {
    const [attributionResult, ledgerResult, shareResult, payoutsResult] = await Promise.all([
      supabase.rpc('list_my_bdo_partners'), supabase.rpc('list_my_bdo_commissions'), supabase.rpc('list_my_bdo_marketer_share_commissions'), supabase.rpc('list_my_commission_payouts'),
    ])
    if (attributionResult.error || ledgerResult.error || shareResult.error || payoutsResult.error) { onError((attributionResult.error ?? ledgerResult.error ?? shareResult.error ?? payoutsResult.error)?.message ?? 'Could not load commission data.'); return }
    setAttributions((attributionResult.data ?? []) as Attribution[])
    setLedger((ledgerResult.data ?? []) as Ledger[])
    setNetworkShares((shareResult.data ?? []) as NetworkShare[])
    setPayouts((payoutsResult.data ?? []) as Payout[])
  }, [supabase, onError])
  useEffect(() => { const timer = window.setTimeout(() => { void load() }, 0); return () => clearTimeout(timer) }, [load])
  const filterDates = <T extends { created_at: string }>(rows: T[]) => rows.filter((row) => (!from || row.created_at.slice(0, 10) >= from) && (!to || row.created_at.slice(0, 10) <= to))
  const filtered = filterDates(ledger)
  const filteredShares = filterDates(networkShares)
  function download() {
    const rows = [
      ['Date', 'Commission type', 'Job', 'Partner', 'Eligible amount NGN', 'Commission NGN', 'Status', 'Payment reference'],
      ...filtered.map((row) => [row.created_at.slice(0, 10), 'Direct BDO', row.job_number ?? row.job_id, row.partner_number ?? '', String(row.eligible_amount_ngn), String(row.calculated_amount_ngn), row.status, row.payment_reference ?? '']),
      ...filteredShares.map((row) => [row.created_at.slice(0, 10), 'Marketer network share', row.job_id, '', String(row.eligible_contribution_ngn), String(row.calculated_amount_ngn), row.status, row.payment_reference ?? '']),
    ]
    const csv = rows.map((row) => row.map((cell) => `"${String(cell).replaceAll('"', '""')}"`).join(',')).join('\r\n')
    const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' }))
    const link = document.createElement('a'); link.href = url; link.download = 'kwik-parsel-commission-statement.csv'; link.click(); URL.revokeObjectURL(url)
  }
  return <section className="history-panel"><div className="history-heading"><div><p className="eyebrow">MY PARTNERS & COMMISSION</p><h2>Attribution and earnings</h2></div><button className="secondary-button" onClick={() => void load()}>Refresh</button></div>
    <h3>My registered partners</h3>{attributions.length === 0 ? <p className="notification-empty">No approved partner attribution has been recorded for you.</p> : <div className="request-list">{attributions.map((row) => <article className="request-item" key={row.attribution_id}><div className="request-item-top"><strong>{row.partner_name} ({row.partner_number})</strong><span>{row.attribution_status.replaceAll('_', ' ')}</span></div><p>{row.attribution_type.replaceAll('_', ' ')} · Effective {row.effective_from.slice(0, 10)} · {row.partner_status}</p></article>)}</div>}
    <div className="history-heading"><div><h3>My commission statements</h3><p className="form-footnote">Direct commissions use your approved collected-revenue plan. Your separate marketer-network share uses its signed plan rate against accepted-quote contribution, prorated across recorded receipts. Receipt reversals create negative adjustments.</p></div></div>
    <div className="field-row"><label className="field"><span>From</span><input type="date" value={from} onChange={(event) => setFrom(event.target.value)} /></label><label className="field"><span>To</span><input type="date" value={to} onChange={(event) => setTo(event.target.value)} /></label></div><button className="secondary-button" disabled={!filtered.length && !filteredShares.length} onClick={download}>Download statement CSV</button>
    <h3>Direct customer commissions</h3>{filtered.length === 0 ? <p className="notification-empty">No direct commission transactions match these dates.</p> : <div className="request-list">{filtered.map((row) => <article className="request-item" key={row.id}><div className="request-item-top"><strong>{row.job_number ?? 'Transaction'} · {row.partner_name ?? 'Partner'}</strong><span>{row.status.replaceAll('_', ' ')}</span></div><p>Eligible amount {money(Number(row.eligible_amount_ngn))} · Commission {money(Number(row.calculated_amount_ngn))}</p><small>{row.created_at.slice(0, 10)}{row.payment_reference ? ` · Payment ${row.payment_reference}` : ''}</small></article>)}</div>}
    <h3>Marketer-network share</h3><p className="form-footnote">Your separately approved share of Gohezo contribution generated by customers referred through your marketers.</p>{filteredShares.length === 0 ? <p className="notification-empty">No marketer-network share transactions match these dates.</p> : <div className="request-list">{filteredShares.map((row) => <article className="request-item" key={row.id}><div className="request-item-top"><strong>Job {row.job_id.slice(0, 8)}</strong><span>{row.status.replaceAll('_', ' ')}</span></div><p>Eligible contribution {money(Number(row.eligible_contribution_ngn))} · Your share {money(Number(row.calculated_amount_ngn))}</p><small>{row.created_at.slice(0, 10)}{row.payment_reference ? ` · Payment ${row.payment_reference}` : ''}</small></article>)}</div>}
    <h3>Payout history</h3>{payouts.length === 0 ? <p className="notification-empty">No transfers or offsets have been recorded yet.</p> : <div className="request-list">{payouts.map((payout) => <article className="request-item" key={payout.id}><div className="request-item-top"><strong>{money(Number(payout.amount_ngn))} paid · {payout.entry_count} commission entries</strong><span>{Number(payout.offset_amount_ngn) > 0 ? 'offset applied' : 'paid'}</span></div><p>{payout.commission_type.replaceAll('_', ' ')} · Gross {money(Number(payout.gross_amount_ngn))} · Offset {money(Number(payout.offset_amount_ngn))}{payout.transfer_reference ? ` · Transfer ${payout.transfer_reference}` : ' · No transfer due'}</p><small>{payout.paid_at.slice(0, 10)}</small></article>)}</div>}
  </section>
}
