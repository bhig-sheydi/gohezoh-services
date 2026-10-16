import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import './partner-bid-screen.css'

type Parcel = { description?: string; quantity?: number; weight_kg?: number; length_cm?: number; width_cm?: number; height_cm?: number }
type BidJob = { request_id: string; request_number: string; pickup_city: string; delivery_city: string; parcel_summary: string; parcel_items: Parcel[] | null; photo_path: string | null; photo_url?: string | null; deadline_at: string; own_bid_amount_ngn: number | null; own_bid_status: string | null }
type Props = { supabase: SupabaseClient; partnerIds: string[]; onError: (message: string) => void; onNotice: (message: string) => void }
type Pickup = { request_id: string; pickup_address: string; sender_name: string; sender_phone: string; latitude: number; longitude: number; location_source: string; nearby_rider_name: string; distance_metres: number }
type DeliveryPin = { request_id: string; latitude: number; longitude: number }
const money = (value: number) => new Intl.NumberFormat('en-NG', { style: 'currency', currency: 'NGN' }).format(value)

export default function PartnerBidScreen({ supabase, partnerIds, onError, onNotice }: Props) {
  const partnerIdKey = partnerIds.join(',')
  const [jobs, setJobs] = useState<BidJob[]>([])
  const [now, setNow] = useState(0)
  const [openBid, setOpenBid] = useState<string | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [pickups, setPickups] = useState<Pickup[]>([])
  const [deliveryPins, setDeliveryPins] = useState<DeliveryPin[]>([])
  const loading = useRef(false)
  const photos = useRef(new Map<string, { url: string; expires: number }>())

  const load = useCallback(async () => {
    if (!partnerIdKey) { setJobs([]); return }
    if (loading.current) return
    loading.current = true
    try {
    const [{ data, error }, locations, deliveries] = await Promise.all([supabase.rpc('list_partner_bid_screen'), supabase.rpc('list_company_bid_pickups'), supabase.rpc('list_company_bid_delivery_locations')])
    if (error) { onError(error.message); return }
    if (locations.error) { onError(locations.error.message); setPickups([]) }
    else setPickups(Array.isArray(locations.data) ? locations.data as Pickup[] : [])
    if (deliveries.error) onError(deliveries.error.message)
    else setDeliveryPins(Array.isArray(deliveries.data) ? deliveries.data as DeliveryPin[] : [])
    const rows = (data ?? []) as BidJob[]
    const withPhotos = await Promise.all(rows.map(async (job) => {
      if (!job.photo_path) return { ...job, photo_url: null }
      const cached = photos.current.get(job.photo_path)
      if (cached && cached.expires > Date.now()) return { ...job, photo_url: cached.url }
      const signed = await supabase.storage.from('customer-saved-parcels').createSignedUrl(job.photo_path, 75)
      if (signed.data?.signedUrl) photos.current.set(job.photo_path, { url: signed.data.signedUrl, expires: Date.now() + 60_000 })
      return { ...job, photo_url: signed.error ? null : signed.data?.signedUrl ?? null }
    }))
    setJobs(withPhotos)
    const paths = new Set(rows.map((row) => row.photo_path))
    for (const path of photos.current.keys()) if (!paths.has(path)) photos.current.delete(path)
    } finally { loading.current = false }
  }, [supabase, partnerIdKey, onError])

  useEffect(() => {
    const initial = window.setTimeout(() => { setNow(new Date().getTime()); void load() }, 0)
    const refresh = window.setInterval(() => { if (!document.hidden) void load() }, 30_000)
    const clock = window.setInterval(() => { if (!document.hidden) setNow(new Date().getTime()) }, 1000)
    const onFocus = () => { setNow(new Date().getTime()); void load() }
    const onVisibility = () => { if (!document.hidden) onFocus() }
    window.addEventListener('focus', onFocus)
    document.addEventListener('visibilitychange', onVisibility)
    const channel = supabase.channel('partner-open-bid-windows')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'delivery_quote_windows' }, () => { void load() })
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'company_bid_invitations' }, () => { if (!document.hidden) void load() })
      .subscribe((status) => { if (status === 'SUBSCRIBED') void load() })
    return () => {
      window.clearTimeout(initial); window.clearInterval(refresh); window.clearInterval(clock)
      window.removeEventListener('focus', onFocus)
      document.removeEventListener('visibilitychange', onVisibility)
      void supabase.removeChannel(channel)
    }
  }, [load, supabase])

  async function submit(event: FormEvent<HTMLFormElement>, job: BidJob) {
    event.preventDefault()
    if (busy || now >= new Date(job.deadline_at).getTime()) return
    const form = new FormData(event.currentTarget)
    if (Number(form.get('amount')) < 1000) { onError('Minimum delivery bid is ₦1,000.'); return }
    setBusy(job.request_id)
    const { error } = await supabase.rpc('submit_partner_quote', {
      p_request_id: job.request_id,
      p_amount_ngn: Number(form.get('amount')),
      p_eta_hours: Number(form.get('eta_hours')),
      p_inclusions: String(form.get('inclusions')).trim(),
      p_exclusions: String(form.get('exclusions')).trim(),
      p_availability_confirmed: form.get('availability_confirmed') === 'on',
      p_surcharge_conditions: String(form.get('surcharge_conditions')).trim(),
    })
    if (error) onError(error.message)
    else { onNotice('Your private bid was submitted.'); setOpenBid(null); await load() }
    setBusy(null)
  }

  return <section className="partner-bid-screen" aria-label="Bidding screen">
    <header className="partner-bid-screen-header"><div><p className="eyebrow">LIVE BIDDING</p><h2>Jobs to bid on</h2></div><button className="secondary-button" onClick={() => void load()}>Refresh</button></header>
    <div className="partner-bid-screen-display">
      {jobs.filter((job) => new Date(job.deadline_at).getTime() > now).map((job) => {
        const remaining = Math.max(0, Math.ceil((new Date(job.deadline_at).getTime() - now) / 1000))
        const parcel = Array.isArray(job.parcel_items) ? job.parcel_items[0] : null
        const pickup = pickups.find((item) => item.request_id === job.request_id)
        const deliveryPin = deliveryPins.find((item) => item.request_id === job.request_id)
        return <article className="partner-bid-job" key={job.request_id}>
          <div className="partner-bid-photo">{job.photo_url ? <img src={job.photo_url} alt={`Goods for ${job.request_number}`} /> : <span>No parcel photo supplied</span>}</div>
          <div className="partner-bid-details"><small>{job.request_number}</small><h3>{job.parcel_summary || parcel?.description || 'Parcel delivery'}</h3>
            <div className="partner-bid-route"><span><small>PICKUP</small><strong>{job.pickup_city}</strong></span><span aria-hidden="true">→</span><span><small>DROP-OFF</small><strong>{job.delivery_city}</strong></span></div>
            <div className="partner-bid-facts"><span>{parcel?.quantity ? `${parcel.quantity} item${parcel.quantity === 1 ? '' : 's'}` : 'Quantity not supplied'}</span><span>{parcel?.weight_kg ? `${parcel.weight_kg} kg each` : 'Weight not supplied'}</span><span>{parcel?.length_cm && parcel?.width_cm && parcel?.height_cm ? `${parcel.length_cm} × ${parcel.width_cm} × ${parcel.height_cm} cm each` : 'Size not supplied'}</span></div>
            <p className="partner-bid-rider">Your company bids. Assign a rider after winning.</p>
            {pickup && <div className="partner-bid-pickup"><strong>{pickup.pickup_address}</strong><p>{pickup.sender_name} · {pickup.sender_phone}</p>
              <small>{pickup.nearby_rider_name} was about {(pickup.distance_metres / 1000).toFixed(1)} km away when invited.</small>
              <p><a href={`https://www.google.com/maps/search/?api=1&query=${pickup.latitude},${pickup.longitude}`} target="_blank" rel="noreferrer">Open pickup directions</a>{pickup.location_source === 'search' && <small> Approximate address match</small>}</p>
            </div>}
            {deliveryPin && <p><a href={`https://www.google.com/maps/search/?api=1&query=${deliveryPin.latitude},${deliveryPin.longitude}`} target="_blank" rel="noreferrer">Open delivery pin</a></p>}
            <div className="partner-bid-actions"><strong className="partner-bid-timer" aria-label={`${remaining} seconds remaining`}>{String(Math.floor(remaining / 60)).padStart(2, '0')}:{String(remaining % 60).padStart(2, '0')}</strong>{job.own_bid_amount_ngn != null ? <span>Your bid: {money(Number(job.own_bid_amount_ngn))}</span> : <button className="partner-bid-button" type="button" onClick={() => setOpenBid(openBid === job.request_id ? null : job.request_id)}>Bid</button>}</div>
            {openBid === job.request_id && job.own_bid_amount_ngn == null && <form className="partner-bid-form" onSubmit={(event) => void submit(event, job)}><div className="field-row"><label className="field"><span>Total price (NGN)</span><input name="amount" type="number" min="1000" step="0.01" required /></label><label className="field"><span>Delivery estimate (hours)</span><input name="eta_hours" type="number" min="1" required /></label></div><details><summary>Bid terms</summary><label className="field"><span>Inclusions</span><textarea name="inclusions" required rows={2} defaultValue="Pickup and delivery" /></label><label className="field"><span>Exclusions</span><textarea name="exclusions" required rows={2} defaultValue="None" /></label><label className="field"><span>Surcharge conditions (write None if none)</span><textarea name="surcharge_conditions" required rows={2} defaultValue="None" /></label></details><label className="partner-bid-confirm"><input type="checkbox" name="availability_confirmed" required /> I confirm availability for this route and timing</label><button className="partner-bid-button" disabled={busy === job.request_id}>{busy === job.request_id ? 'Submitting...' : 'Submit bid'}</button></form>}
          </div>
        </article>
      })}
    </div>
  </section>
}
