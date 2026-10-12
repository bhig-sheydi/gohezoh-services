import { useCallback, useEffect, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'

type Attribution = { attribution_id: string; partner_id: string; partner_number: string; partner_name: string; partner_status: string; attribution_type: string; effective_from: string; attribution_status: string }
type Ledger = { id: string; partner_id: string | null; partner_number: string | null; partner_name: string | null; job_id: string | null; job_number: string | null; eligible_amount_ngn: number; calculated_amount_ngn: number; status: string; payment_reference: string | null; calculated_at: string | null; created_at: string; customer_price_ngn: number | null; collected_amount_ngn: number | null }
const money = (value: number) => new Intl.NumberFormat('en-NG', { style: 'currency', currency: 'NGN' }).format(value)

export default function BdoTransparencyPanel({ supabase, onError }: { supabase: SupabaseClient; onError: (message: string) => void }) {
  const [attributions, setAttributions] = useState<Attribution[]>([])
  const [ledger, setLedger] = useState<Ledger[]>([])
  const [from, setFrom] = useState('')
  const [to, setTo] = useState('')
  const load = useCallback(async () => {
    const [attributionResult, ledgerResult] = await Promise.all([
      supabase.rpc('list_my_bdo_partners'),
      supabase.rpc('list_my_bdo_commissions'),
    ])
    if (attributionResult.error || ledgerResult.error) { onError((attributionResult.error ?? ledgerResult.error)?.message ?? 'Could not load commission data.'); return }
    const ownAttributions = (attributionResult.data ?? []) as Attribution[]
    const ownLedger = (ledgerResult.data ?? []) as Ledger[]
    setAttributions(ownAttributions); setLedger(ownLedger)
  }, [supabase, onError])
  useEffect(() => { const timer = window.setTimeout(() => { void load() }, 0); return () => clearTimeout(timer) }, [load])
  const filtered = ledger.filter((row) => (!from || row.created_at.slice(0, 10) >= from) && (!to || row.created_at.slice(0, 10) <= to))
  function download() {
    const rows = [['Date', 'Job', 'Partner', 'Eligible amount NGN', 'Commission NGN', 'Status', 'Payment reference'], ...filtered.map((row) => [row.created_at.slice(0, 10), row.job_number ?? '', row.partner_number ?? '', String(row.eligible_amount_ngn), String(row.calculated_amount_ngn), row.status, row.payment_reference ?? ''])]
    const csv = rows.map((row) => row.map((cell) => `"${String(cell).replaceAll('"', '""')}"`).join(',')).join('\r\n')
    const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' }))
    const link = document.createElement('a'); link.href = url; link.download = 'gohezoh-commission-statement.csv'; link.click(); URL.revokeObjectURL(url)
  }
  return <section className="history-panel"><div className="history-heading"><div><p className="eyebrow">MY PARTNERS & COMMISSION</p><h2>Attribution and earnings</h2></div><button className="secondary-button" onClick={() => void load()}>Refresh</button></div><h3>My registered partners</h3>{attributions.length === 0 ? <p className="notification-empty">No approved partner attribution has been recorded for you.</p> : <div className="request-list">{attributions.map((row) => { return <article className="request-item" key={row.attribution_id}><div className="request-item-top"><strong>{row.partner_name} ({row.partner_number})</strong><span>{row.attribution_status.replaceAll('_', ' ')}</span></div><p>{row.attribution_type.replaceAll('_', ' ')} · Effective {row.effective_from.slice(0, 10)} · {row.partner_status}</p></article> })}</div>}<div className="history-heading"><div><h3>My successful transactions and commission</h3><p className="form-footnote">Entries appear after Finance applies an approved agreement to eligible completed and paid transactions.</p></div></div><div className="field-row"><label className="field"><span>From</span><input type="date" value={from} onChange={(event) => setFrom(event.target.value)} /></label><label className="field"><span>To</span><input type="date" value={to} onChange={(event) => setTo(event.target.value)} /></label></div><button className="secondary-button" disabled={!filtered.length} onClick={download}>Download statement CSV</button>{filtered.length === 0 ? <p className="notification-empty">No commission transactions match these dates.</p> : <div className="request-list">{filtered.map((row) => <article className="request-item" key={row.id}><div className="request-item-top"><strong>{row.job_number ?? 'Transaction'} · {row.partner_name ?? 'Partner'}</strong><span>{row.status.replaceAll('_', ' ')}</span></div><p>Eligible amount {money(Number(row.eligible_amount_ngn))} · Commission {money(Number(row.calculated_amount_ngn))}</p><small>{row.created_at.slice(0, 10)}{row.payment_reference ? ` · Payment ${row.payment_reference}` : ''}</small></article>)}</div>}</section>
}
