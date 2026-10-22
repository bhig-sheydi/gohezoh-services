import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { routeLabel } from './lib/route-label'
import './customer-bidding.css'

type QuoteWindow = { request_id: string; deadline_at: string; status: string }
type CustomerQuote = { request_id: string; customer_price_ngn: number | null; expires_at: string | null; status: string }
type PaymentHold = { request_id: string; status: string; amount_ngn: number; account_number: string | null;
  bank_name: string | null; expires_at: string; reference: string }
const TERMINAL_NOTICE_MS = 10 * 60 * 1000
function terminalNoticeDeadline(hold: PaymentHold, paymentReceivedAt?: string) {
  const timestamp = Date.parse(hold.status === 'paid' && paymentReceivedAt ? paymentReceivedAt : hold.expires_at)
  return Number.isFinite(timestamp) ? timestamp + TERMINAL_NOTICE_MS : Number.POSITIVE_INFINITY
}
type CustomerBid = { bid_id: string; partner_name: string; partner_phone: string | null; rider_name: string | null;
  rider_phone: string | null; rider_photo_path: string | null; rider_photo_url?: string | null;
  bid_amount_ngn: number; eta_hours: number }
type OpenRequest = { request_id: string; request_number: string; pickup_city: string; delivery_city: string; parcel_summary: string; preferred_pickup_at: string | null; special_instructions: string | null; deadline_at: string; own_bid_amount_ngn: number | null; own_bid_status: string | null }
const money = (value: number) => new Intl.NumberFormat('en-NG', { style: 'currency', currency: 'NGN' }).format(value)
const date = (value: string) => new Intl.DateTimeFormat('en-NG', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value))

export function CustomerQuotePanel({ supabase, requestIds, pendingRequestIds = [], paymentReceivedAtByRequest = {}, onError, onNotice, onRefresh }: { supabase: SupabaseClient; requestIds: string[]; pendingRequestIds?: string[]; paymentReceivedAtByRequest?: Record<string, string>; onError: (message: string) => void; onNotice: (message: string) => void; onRefresh: () => void }) {
  const requestIdKey = requestIds.join(',')
  const pendingIdKey = pendingRequestIds.join(',')
  const pendingIds = new Set(pendingRequestIds)
  const [windows, setWindows] = useState<QuoteWindow[]>([])
  const [quotes, setQuotes] = useState<CustomerQuote[]>([])
  const [holds, setHolds] = useState<Record<string, PaymentHold>>({})
  const holdsRef = useRef(holds)
  useEffect(() => { holdsRef.current = holds }, [holds])
  const [offers, setOffers] = useState<Record<string, CustomerBid[]>>({})
  const [now, setNow] = useState(0)
  const [busy, setBusy] = useState('')
  const activeHoldKey = Object.values(holds).filter((hold) => ['initializing', 'pending'].includes(hold.status)).map((hold) => `${hold.request_id}:${hold.status}`).join(',')
  const pendingHoldKey = Object.values(holds).filter((hold) => hold.status === 'pending').map((hold) => hold.request_id).join(',')
  const photoCache = useRef(new Map<string, { url: string; expires: number }>())
  const load = useCallback(async () => {
    const ids = requestIdKey ? requestIdKey.split(',') : []
    if (!ids.length) { setWindows([]); setQuotes([]); setOffers({}); setHolds({}); return }
    const [windowResult, quoteResult, holdResult] = await Promise.all([
      supabase.from('delivery_quote_windows').select('request_id, deadline_at, status').in('request_id', ids),
      supabase.from('customer_delivery_quotes').select('request_id, customer_price_ngn, expires_at, status').in('request_id', ids),
      supabase.rpc('list_my_flutterwave_holds'),
    ])
    if (windowResult.error || quoteResult.error || holdResult.error) { onError((windowResult.error ?? quoteResult.error ?? holdResult.error)?.message ?? 'Could not load quotes.'); return }
    const nextWindows = (windowResult.data ?? []) as QuoteWindow[]
    const nextQuotes = (quoteResult.data ?? []) as CustomerQuote[]
    setNow(Date.now())
    setWindows(nextWindows)
    setQuotes(nextQuotes)
    setHolds(Object.fromEntries(((holdResult.data ?? []) as PaymentHold[]).filter((hold) => ids.includes(hold.request_id)).map((hold) => [hold.request_id, hold])))
    const ready = nextWindows.filter((row) => new Date(row.deadline_at).getTime() <= Date.now()
      && ['matching', 'open', 'awaiting_customer_selection'].includes(row.status)
      && !nextQuotes.some((quote) => quote.request_id === row.request_id))
    const results = await Promise.all(ready.map(async (row) => {
      const { data, error } = await supabase.rpc('list_customer_bid_offers', { p_request_id: row.request_id })
      if (error) { onError(error.message); return [row.request_id, []] as const }
      const bids = await Promise.all(((data ?? []) as CustomerBid[]).map(async (bid) => {
        if (!bid.rider_photo_path) return { ...bid, rider_photo_url: null }
        const cached = photoCache.current.get(bid.rider_photo_path)
        if (cached && cached.expires > Date.now()) return { ...bid, rider_photo_url: cached.url }
        const signed = await supabase.storage.from('rider-evidence').createSignedUrl(bid.rider_photo_path, 300)
        if (signed.data?.signedUrl) photoCache.current.set(bid.rider_photo_path, { url: signed.data.signedUrl, expires: Date.now() + 240_000 })
        return { ...bid, rider_photo_url: signed.data?.signedUrl ?? null }
      }))
      return [row.request_id, bids] as const
    }))
    setOffers(Object.fromEntries(results))
  }, [supabase, requestIdKey, onError])
  useEffect(() => { const timer = window.setTimeout(() => { void load() }, 0); return () => clearTimeout(timer) }, [load])
  useEffect(() => {
    if (!pendingIdKey && !windows.some((row) => ['matching', 'open', 'awaiting_customer_selection'].includes(row.status))
      && !Object.values(holdsRef.current).some((hold) => ['initializing', 'pending'].includes(hold.status))) return
    const activeWindow = windows.some((row) => ['matching', 'open', 'awaiting_customer_selection'].includes(row.status))
    const timer = window.setInterval(() => { if (!document.hidden) { setNow(Date.now()); void load() } }, activeWindow ? 5000 : 30000)
    const onFocus = () => { setNow(Date.now()); void load() }
    window.addEventListener('focus', onFocus)
    return () => { window.clearInterval(timer); window.removeEventListener('focus', onFocus) }
  }, [load, pendingIdKey, windows, activeHoldKey])
  useEffect(() => {
    if (!Object.values(holdsRef.current).some((hold) => ['initializing', 'pending'].includes(hold.status))) return
    const timer = window.setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(timer)
  }, [activeHoldKey])
  useEffect(() => {
    const current = Date.now()
    const nextDeadline = Object.values(holds)
      .filter((hold) => hold.status === 'paid' || hold.status === 'expired' || (hold.status !== 'review' && Date.parse(hold.expires_at) <= current))
      .map((hold) => terminalNoticeDeadline(hold, paymentReceivedAtByRequest[hold.request_id]))
      .filter((deadline) => deadline > current)
      .sort((a, b) => a - b)[0]
    if (nextDeadline === undefined || !Number.isFinite(nextDeadline)) return
    const timer = window.setTimeout(() => setNow(Date.now()), nextDeadline - current)
    return () => window.clearTimeout(timer)
  }, [holds, paymentReceivedAtByRequest])
  useEffect(() => {
    const active = Object.values(holdsRef.current).filter((hold) => hold.status === 'pending' && new Date(hold.expires_at).getTime() > Date.now())
    if (!active.length) return
    const timer = window.setInterval(() => { if (!document.hidden) void Promise.all(active.map(async (hold) => {
      await supabase.functions.invoke('flutterwave-payment', { body: { action: 'check', requestId: hold.request_id } })
      await load()
    })) }, 15000)
    return () => clearInterval(timer)
  }, [pendingHoldKey, supabase, load])
  async function choose(requestId: string, bidId: string) {
    setBusy(requestId)
    const { data, error } = await supabase.functions.invoke('flutterwave-payment', { body: { action: 'start', requestId, bidId } })
    if (error) onError(error.message)
    else { onNotice(data?.status === 'management' ? 'Company selected. Your final delivery price is being prepared.' : 'Company selected. Pay within two minutes to confirm the rider.'); await load(); onRefresh() }
    setBusy('')
  }
  async function accept(requestId: string) {
    setBusy(requestId)
    const { error } = await supabase.rpc('accept_customer_delivery_quote', { p_request_id: requestId })
    if (error) onError(error.message)
    else { onNotice('Quote accepted. Kwik-Parsel will confirm payment and award the delivery.'); await load(); onRefresh() }
    setBusy('')
  }
  async function retryAccount(requestId: string) {
    setBusy(requestId)
    const { error } = await supabase.functions.invoke('flutterwave-payment', { body: { action: 'status', requestId } })
    if (error) onError(error.message)
    await load()
    setBusy('')
  }
  return <>{requestIds.map((requestId) => {
    const quote = quotes.find((row) => row.request_id === requestId)
    const bidWindow = windows.find((row) => row.request_id === requestId)
    const hold = holds[requestId]
    if (hold) {
      const seconds = Math.max(0, Math.ceil((new Date(hold.expires_at).getTime() - now) / 1000))
      const active = ['initializing', 'pending'].includes(hold.status) && seconds > 0
      if (!active && hold.status !== 'review' && now >= terminalNoticeDeadline(hold, paymentReceivedAtByRequest[requestId])) return null
      const displayStatus = hold.status === 'paid' ? 'paid' : active ? 'pending' : hold.status === 'review' ? 'review' : 'expired'
      return <section className={`customer-payment-card customer-payment-${displayStatus}`} key={requestId} aria-label="Delivery payment" role="status">
        <div className="customer-payment-heading"><img src="/favicon.svg" alt="Kwik-Parsel logo" /><p className="eyebrow">KWIK-PARSEL · DELIVERY PAYMENT</p></div>
        <h3>{hold.status === 'paid' ? 'Payment confirmed' : active ? `Pay ${money(Number(hold.amount_ngn))}` : hold.status === 'review' ? 'Payment needs review' : 'Booking expired'}</h3>
        {active && <><strong className="customer-payment-timer">{Math.floor(seconds / 60)}:{String(seconds % 60).padStart(2, '0')} left</strong>
          {hold.account_number && hold.bank_name ? <div className="customer-payment-account"><span>{hold.bank_name}</span><strong>{hold.account_number}</strong><button type="button" onClick={() => void navigator.clipboard.writeText(hold.account_number!)}>Copy account</button></div> : <><p>Preparing your temporary bank account…</p><button type="button" disabled={busy === requestId} onClick={() => void retryAccount(requestId)}>Retry account</button></>}
          <p>Transfer the exact amount now. Your rider waits until payment is confirmed.</p></>}
        {hold.status === 'paid' && <p>Payment confirmed. Keep your phone nearby while your company rider is confirmed.</p>}
        {hold.status === 'review' && <p>A payment arrived after the booking window or needs review. Please contact support; do not pay again yet.</p>}
        {(hold.status === 'expired' || (!active && hold.status !== 'paid' && hold.status !== 'review')) && <p>The rider is no longer reserved. Please book another delivery. If you transferred money, contact support before paying again.</p>}
      </section>
    }
    if (quote) return <div className="customer-quote-card" key={requestId}><strong>{quote.customer_price_ngn == null ? 'Quote under review' : `Delivery quote: ${money(Number(quote.customer_price_ngn))}`}</strong><small>{quote.expires_at ? `Accept by ${date(quote.expires_at)} · ` : ''}{quote.status.replaceAll('_', ' ')}</small>{quote.status === 'sent' && quote.customer_price_ngn != null && <button className="primary-button" disabled={busy === requestId} onClick={() => void accept(requestId)}>{busy === requestId ? 'Accepting...' : 'Accept quote'}</button>}</div>
    if (bidWindow?.status === 'no_bids' && pendingIds.has(requestId)) return <section className="customer-bid-panel" key={requestId} role="status"><div className="customer-bid-wait"><div className="customer-bid-radar" aria-hidden="true"><span /><span /><span /><i /></div><div className="customer-bid-wait-copy"><h3>Searching for a rider</h3><p>We will keep checking for a rider whose route fits your delivery.</p><div className="customer-bid-progress customer-bid-progress-search" aria-label="Searching for a matching rider"><span /></div><small>Searching automatically</small></div></div></section>
    if (bidWindow?.status === 'no_bids') return <p className="customer-bid-empty" key={requestId}>No companies bid this time. Try matching again.</p>
    if (bidWindow?.status === 'matching') return <section className="customer-bid-panel" key={requestId} role="status"><div className="customer-bid-wait"><div className="customer-bid-radar" aria-hidden="true"><span /><span /><span /><i /></div><div className="customer-bid-wait-copy"><h3>Finding interested riders</h3><p>Checking riders near your pickup and those already heading your way.</p><div className="customer-bid-progress customer-bid-progress-search" aria-label="Matching riders"><span /></div></div></div></section>
    if (bidWindow) {
      const remaining = Math.max(0, Math.ceil((new Date(bidWindow.deadline_at).getTime() - now) / 1000))
      const waiting = remaining > 0
      const bids = offers[requestId] ?? []
      return <section className="customer-bid-panel" key={requestId} aria-label="Interested companies">
        {waiting ? <div className="customer-bid-wait" role="status">
          <div className="customer-bid-radar" aria-hidden="true"><span /><span /><span /><i /></div>
          <div className="customer-bid-wait-copy"><p className="eyebrow">MATCHING YOUR DELIVERY</p><h3>Finding interested riders</h3>
            <p>Invited companies have {remaining} seconds to bid.</p>
            <div className="customer-bid-progress" role="progressbar" aria-label="Bidding window" aria-valuemin={0} aria-valuemax={60} aria-valuenow={Math.max(0, 60 - remaining)}><span style={{ width: `${Math.min(100, Math.max(0, (60 - remaining) / 60 * 100))}%` }} /></div>
            <small>{remaining}s left in the bidding window</small></div>
        </div> : bids.length ? <><header className="customer-bid-heading"><p className="eyebrow">YOUR DELIVERY OPTIONS</p><h3>You have {bids.length} interested {bids.length === 1 ? 'company' : 'companies'}</h3></header>
          <div className="customer-bid-grid">{bids.map((bid) => <article className="customer-bid-offer" key={bid.bid_id}>
            <div className="customer-bid-rider">{bid.rider_photo_url ? <img src={bid.rider_photo_url} alt={`${bid.rider_name ?? 'Rider'} profile`} /> : <div className="customer-bid-no-photo" aria-label="No rider photo">Photo unavailable</div>}
              <div><strong>{bid.partner_name}</strong><span>{bid.rider_name ?? 'Rider to be assigned'}</span></div></div>
            <strong className="customer-bid-price">{money(Number(bid.bid_amount_ngn))}</strong><small>Company bid. For local delivery, this is your final price; interstate pricing follows approval.</small>
            <div className="customer-bid-contacts"><span>Rider: {bid.rider_phone ?? 'Number not supplied'}</span><span>Company: {bid.partner_phone ?? 'Number not supplied'}</span></div>
            <button type="button" className="primary-button" disabled={busy === requestId} onClick={() => void choose(requestId, bid.bid_id)}>{busy === requestId ? 'Selecting...' : 'Choose this company'}</button>
          </article>)}</div>
          <p className="customer-bid-safety">Check the rider’s face against their profile photo at pickup. If the photo is unclear or does not match, do not hand over your parcel; contact the company.</p>
        </> : <div className="customer-bid-wait" role="status"><div className="customer-bid-radar" aria-hidden="true"><span /><span /><span /><i /></div><div><h3>Checking company bids</h3><p>We’re collecting the bids placed before the window closed.</p></div></div>}
      </section>
    }
    if (pendingIds.has(requestId)) return <section className="customer-bid-panel" key={requestId} role="status"><div className="customer-bid-wait"><div className="customer-bid-radar" aria-hidden="true"><span /><span /><span /><i /></div><div className="customer-bid-wait-copy"><h3>Searching for a rider</h3><p>We will keep checking for a rider whose route fits your delivery.</p><div className="customer-bid-progress customer-bid-progress-search" aria-label="Searching for a matching rider"><span /></div><small>Searching automatically</small></div></div></section>
    return null
  })}</>
}

export function PartnerBidQueue({ supabase, partnerIds, onError, onNotice }: { supabase: SupabaseClient; partnerIds: string[]; onError: (message: string) => void; onNotice: (message: string) => void }) {
  const partnerIdKey = partnerIds.join(',')
  const [requests, setRequests] = useState<OpenRequest[]>([])
  const [routes, setRoutes] = useState<Array<{ request_id: string; pickup_address: string | null; delivery_address: string | null }>>([])
  const [busy, setBusy] = useState('')
  const load = useCallback(async () => {
    if (!partnerIdKey) { setRequests([]); return }
    const [{ data, error }, routeResult] = await Promise.all([supabase.rpc('list_eligible_delivery_requests'), supabase.rpc('list_partner_bid_route_addresses')])
    if (error) onError(error.message)
    else setRequests((data ?? []) as OpenRequest[])
    if (routeResult.error) onError(routeResult.error.message)
    else setRoutes(Array.isArray(routeResult.data) ? routeResult.data : [])
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
    return <article className="request-item" key={request.request_id}><div className="request-item-top"><strong>{request.request_number} · {routeLabel(routes.find((route) => route.request_id === request.request_id)?.pickup_address, request.pickup_city, routes.find((route) => route.request_id === request.request_id)?.delivery_address, request.delivery_city)}</strong><span className="request-status">Closes {date(request.deadline_at)}</span></div><p>{request.parcel_summary}</p>{request.preferred_pickup_at && <small>Preferred pickup: {date(request.preferred_pickup_at)}</small>}{request.special_instructions && <p>Handling: {request.special_instructions}</p>}{request.own_bid_amount_ngn != null ? <p>Your quote: {money(Number(request.own_bid_amount_ngn))} · {request.own_bid_status?.replaceAll('_', ' ')}</p> : <form className="form-grid" onSubmit={(event) => void submit(event, request.request_id)}><div className="field-row"><label className="field"><span>Total price (NGN)</span><input name="amount" type="number" min="1000" step="0.01" required /></label><label className="field"><span>Delivery estimate (hours)</span><input name="eta_hours" type="number" min="1" required /></label></div><label className="field"><span>Inclusions</span><textarea name="inclusions" required rows={2} /></label><label className="field"><span>Exclusions</span><textarea name="exclusions" required rows={2} /></label><label className="field"><span>Surcharge conditions (write None if none)</span><textarea name="surcharge_conditions" required rows={2} /></label><label className="field"><span><input type="checkbox" name="availability_confirmed" required /> I confirm availability for this route and timing</span></label><button className="primary-button" disabled={busy === request.request_id}>{busy === request.request_id ? 'Submitting...' : 'Submit private quote'}</button></form>}</article>
  })}</div>}</section>
}
