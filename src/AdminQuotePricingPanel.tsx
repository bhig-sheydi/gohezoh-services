import { useCallback, useEffect, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'

type PendingQuote = { request_id: string; total_direct_cost_ngn: number; unrounded_price_ngn: number; status: string }
type PricingPolicy = { rounding_increment_ngn: number; reason: string }
const money = (value: number) => new Intl.NumberFormat('en-NG', { style: 'currency', currency: 'NGN' }).format(value)
export default function AdminQuotePricingPanel({ supabase, onError, onNotice }: { supabase: SupabaseClient; onError: (message: string) => void; onNotice: (message: string) => void }) {
  const [quotes, setQuotes] = useState<PendingQuote[]>([])
  const [busy, setBusy] = useState('')
  const [policy, setPolicy] = useState<PricingPolicy | null>(null)
  const load = useCallback(async () => {
    const [quoteResult, policyResult] = await Promise.all([
      supabase.from('customer_delivery_quotes').select('request_id, total_direct_cost_ngn, unrounded_price_ngn, status').eq('status', 'pending_price').limit(50),
      supabase.from('delivery_pricing_policies').select('rounding_increment_ngn, reason').is('retired_at', null).maybeSingle(),
    ])
    if (quoteResult.error || policyResult.error) onError((quoteResult.error ?? policyResult.error)?.message ?? 'Could not load pricing.')
    else { setQuotes((quoteResult.data ?? []) as PendingQuote[]); setPolicy((policyResult.data ?? null) as PricingPolicy | null) }
  }, [supabase, onError])
  useEffect(() => { const timer = window.setTimeout(() => { void load() }, 0); return () => clearTimeout(timer) }, [load])
  async function finalize(event: FormEvent<HTMLFormElement>, quote: PendingQuote) {
    event.preventDefault()
    const form = new FormData(event.currentTarget)
    const extra = Number(form.get('extra_cost'))
    const price = Number(form.get('price'))
    const reason = String(form.get('reason')).trim()
    if (!policy) { onError('Approve a pricing increment before sending customer quotes.'); return }
    const expected = Math.round(((Number(quote.total_direct_cost_ngn) + extra) / 0.75) / Number(policy.rounding_increment_ngn)) * Number(policy.rounding_increment_ngn)
    if (Math.abs(price - expected) > 0.01) { onError(`Approved formula and rounding require ${money(expected)}.`); return }
    setBusy(quote.request_id)
    const { error } = await supabase.rpc('set_delivery_quote_price', { p_request_id: quote.request_id, p_other_direct_cost_ngn: extra, p_customer_price_ngn: price, p_reason: reason, p_expires_at: new Date(String(form.get('expires_at'))).toISOString() })
    if (error) onError(error.message)
    else { onNotice('Customer quote priced and sent for acceptance.'); await load() }
    setBusy('')
  }
  async function configure(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const form = new FormData(event.currentTarget)
    setBusy('policy')
    const { error } = await supabase.rpc('configure_delivery_pricing_policy', { p_rounding_increment_ngn: Number(form.get('increment')), p_reason: String(form.get('reason')).trim() })
    if (error) onError(error.message)
    else { onNotice('Delivery rounding policy approved.'); await load() }
    setBusy('')
  }
  return <section className="history-panel"><div className="history-heading"><div><p className="eyebrow">CUSTOMER QUOTES</p><h2>Prices awaiting approval</h2></div><button className="secondary-button" onClick={() => void load()}>Refresh</button></div><p className="form-footnote">Customer price is total eligible direct cost ÷ 0.75, rounded to the Management-approved increment.</p>{policy ? <p>Current approved rounding: nearest {money(Number(policy.rounding_increment_ngn))}.</p> : <p className="timeline-alert">Pricing policy needs Management approval before a quote can be sent.</p>}<form className="form-grid" onSubmit={(event) => void configure(event)}><h3>Approve rounding policy</h3><label className="field"><span>Increment (NGN)</span><input name="increment" type="number" min="0.01" step="0.01" required /></label><label className="field"><span>Reason for policy</span><textarea name="reason" minLength={10} rows={2} required /></label><button className="secondary-button" disabled={busy === 'policy'}>Save approved policy</button></form>{quotes.length === 0 ? <p className="notification-empty">No selected bids await pricing.</p> : <div className="request-list">{quotes.map((quote) => <article className="request-item" key={quote.request_id}><strong>Request {quote.request_id}</strong><p>Winning direct cost: {money(Number(quote.total_direct_cost_ngn))} · Formula price before rounding: {money(Number(quote.unrounded_price_ngn))}</p><form className="form-grid" onSubmit={(event) => void finalize(event, quote)}><div className="field-row"><label className="field"><span>Other direct costs (NGN)</span><input name="extra_cost" type="number" min="0" step="0.01" defaultValue="0" required /></label><label className="field"><span>Approved customer price (NGN)</span><input name="price" type="number" min="0" step="0.01" required /></label></div><label className="field"><span>Quote expires at</span><input name="expires_at" type="datetime-local" required /></label><label className="field"><span>Price and rounding reason</span><textarea name="reason" rows={2} required /></label><button className="primary-button" disabled={busy === quote.request_id || !policy}>{busy === quote.request_id ? 'Sending...' : 'Send final quote'}</button></form></article>)}</div>}</section>
}
