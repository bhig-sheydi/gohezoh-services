import { useCallback, useEffect, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'

type QuoteWindow = { request_id: string; deadline_at: string; status: string }
type CustomerQuote = { request_id: string; customer_price_ngn: number | null; expires_at: string | null; status: string }
type OpenRequest = { request_id: string; request_number: string; pickup_city: string; delivery_city: string; parcel_summary: string; preferred_pickup_at: string | null; special_instructions: string | null; deadline_at: string; own_bid_amount_ngn: number | null; own_bid_status: string | null }
const money = (value: number) => new Intl.NumberFormat('en-NG', { style: 'currency', currency: 'NGN' }).format(value)
const date = (value: string) => new Intl.DateTimeFormat('en-NG', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value))

export function CustomerQuotePanel({ supabase, requestIds, onError, onNotice, onRefresh }: { supabase: SupabaseClient; requestIds: string[]; onError: (message: string) => void; onNotice: (message: string) => void; onRefresh: () => void }) {
  const requestIdKey = requestIds.join(',')
  const [windows, setWindows] = useState<QuoteWindow[]>([])
  const [quotes, setQuotes] = useState<CustomerQuote[]>([])
  const [busy, setBusy] = useState('')
  const load = useCallback(async () => {
    const ids = requestIdKey ? requestIdKey.split(',') : []
    if (!ids.length) { setWindows([]); setQuotes([]); return }
    const [windowResult, quoteResult] = await Promise.all([
      supabase.from('delivery_quote_windows').select('request_id, deadline_at, status').in('request_id', ids),
      supabase.from('customer_delivery_quotes').select('request_id, customer_price_ngn, expires_at, status').in('request_id', ids),
    ])
    if (windowResult.error || quoteResult.error) { onError((windowResult.error ?? quoteResult.error)?.message ?? 'Could not load quotes.'); return }
    setWindows((windowResult.data ?? []) as QuoteWindow[])
    setQuotes((quoteResult.data ?? []) as CustomerQuote[])
  }, [supabase, requestIdKey, onError])
  useEffect(() => { const timer = window.setTimeout(() => { void load() }, 0); return () => clearTimeout(timer) }, [load])
  async function accept(requestId: string) {
    setBusy(requestId)
    const { error } = await supabase.rpc('accept_customer_delivery_quote', { p_request_id: requestId })
    if (error) onError(error.message)
    else { onNotice('Quote accepted. Kwik-Parsel will confirm payment and award the delivery.'); await load(); onRefresh() }
    setBusy('')
  }
  return <>{requestIds.map((requestId) => {
    const quote = quotes.find((row) => row.request_id === requestId)
    const bidWindow = windows.find((row) => row.request_id === requestId)
    if (quote) return <div className="customer-quote-card" key={requestId}><strong>{quote.customer_price_ngn == null ? 'Quote under review' : `Delivery quote: ${money(Number(quote.customer_price_ngn))}`}</strong><small>{quote.expires_at ? `Accept by ${date(quote.expires_at)} · ` : ''}{quote.status.replaceAll('_', ' ')}</small>{quote.status === 'sent' && quote.customer_price_ngn != null && <button className="primary-button" disabled={busy === requestId} onClick={() => void accept(requestId)}>{busy === requestId ? 'Accepting...' : 'Accept quote'}</button>}</div>
    if (bidWindow) return <p className="form-footnote" key={requestId}>Partner quotes {bidWindow.status === 'open' ? `close ${date(bidWindow.deadline_at)}` : bidWindow.status.replaceAll('_', ' ')}. Your price will appear here after review.</p>
    return null
  })}</>
}

export function PartnerBidQueue({ supabase, partnerIds, onError, onNotice }: { supabase: SupabaseClient; partnerIds: string[]; onError: (message: string) => void; onNotice: (message: string) => void }) {
  const partnerIdKey = partnerIds.join(',')
  const [requests, setRequests] = useState<OpenRequest[]>([])
  const [busy, setBusy] = useState('')
  const load = useCallback(async () => {
    if (!partnerIdKey) { setRequests([]); return }
    const { data, error } = await supabase.rpc('list_eligible_delivery_requests')
    if (error) onError(error.message)
    else setRequests((data ?? []) as OpenRequest[])
  }, [supabase, partnerIdKey, onError])
  useEffect(() => { const timer = window.setTimeout(() => { void load() }, 0); return () => clearTimeout(timer) }, [load])
  async function submit(event: FormEvent<HTMLFormElement>, requestId: string) {
    event.preventDefault()
    const form = new FormData(event.currentTarget)
    setBusy(requestId)
    const { error } = await supabase.rpc('submit_partner_quote', { p_request_id: requestId, p_amount_ngn: Number(form.get('amount')), p_eta_hours: Number(form.get('eta_hours')), p_inclusions: String(form.get('inclusions')).trim(), p_exclusions: String(form.get('exclusions')).trim(), p_availability_confirmed: form.get('availability_confirmed') === 'on', p_surcharge_conditions: String(form.get('surcharge_conditions')).trim() })
    if (error) onError(error.message)
    else { onNotice('Your private quote was submitted.'); await load() }
    setBusy('')
  }
  return <section className="history-panel"><div className="history-heading"><div><p className="eyebrow">PARTNER BIDDING</p><h2>Eligible quote requests</h2></div><button className="secondary-button" onClick={() => void load()}>Refresh</button></div>{requests.length === 0 ? <p className="notification-empty">No eligible quote windows are open for your approved routes.</p> : <div className="request-list">{requests.map((request) => {
    return <article className="request-item" key={request.request_id}><div className="request-item-top"><strong>{request.request_number} · {request.pickup_city} to {request.delivery_city}</strong><span className="request-status">Closes {date(request.deadline_at)}</span></div><p>{request.parcel_summary}</p>{request.preferred_pickup_at && <small>Preferred pickup: {date(request.preferred_pickup_at)}</small>}{request.special_instructions && <p>Handling: {request.special_instructions}</p>}{request.own_bid_amount_ngn != null ? <p>Your quote: {money(Number(request.own_bid_amount_ngn))} · {request.own_bid_status?.replaceAll('_', ' ')}</p> : <form className="form-grid" onSubmit={(event) => void submit(event, request.request_id)}><div className="field-row"><label className="field"><span>Total price (NGN)</span><input name="amount" type="number" min="1000" step="0.01" required /></label><label className="field"><span>Delivery estimate (hours)</span><input name="eta_hours" type="number" min="1" required /></label></div><label className="field"><span>Inclusions</span><textarea name="inclusions" required rows={2} /></label><label className="field"><span>Exclusions</span><textarea name="exclusions" required rows={2} /></label><label className="field"><span>Surcharge conditions (write None if none)</span><textarea name="surcharge_conditions" required rows={2} /></label><label className="field"><span><input type="checkbox" name="availability_confirmed" required /> I confirm availability for this route and timing</span></label><button className="primary-button" disabled={busy === request.request_id}>{busy === request.request_id ? 'Submitting...' : 'Submit private quote'}</button></form>}</article>
  })}</div>}</section>
}
