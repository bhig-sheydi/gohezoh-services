import { useCallback, useEffect, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { closestMappedLandmark, reverseAddress } from './lib/geoapify-geocoding'
import './CustomerRiderTracking.css'

type Tracking = { state: 'live' | 'offline' | 'awaiting_rider' | 'completed'; captured_at?: string;
  distance_metres?: number | null; speed_kmh?: number | null; eta_minutes?: number | null; checks_remaining?: number }
type Reveal = { latitude: number; longitude: number; accuracy_metres: number; captured_at: string;
  community: string | null; street: string | null; landmark: string | null; landmarkDistance: number | null }
type Claim = { state: Tracking['state'] | 'limited'; latitude?: number; longitude?: number; accuracy_metres?: number;
  captured_at?: string; checks_remaining?: number; retry_at?: string }

function validTracking(value: unknown): value is Tracking {
  if (!value || typeof value !== 'object') return false
  const data = value as Record<string, unknown>
  if (!['live', 'offline', 'awaiting_rider', 'completed'].includes(String(data.state))) return false
  return data.state !== 'live' || (typeof data.captured_at === 'string' && Number.isInteger(data.checks_remaining) &&
    Number(data.checks_remaining) >= 0 && Number(data.checks_remaining) <= 2 && !('latitude' in data) && !('longitude' in data))
}
function validClaim(value: unknown): value is Claim {
  if (!value || typeof value !== 'object') return false
  const data = value as Record<string, unknown>
  if (!['live', 'offline', 'awaiting_rider', 'completed', 'limited'].includes(String(data.state))) return false
  return data.state !== 'live' || (typeof data.latitude === 'number' && Math.abs(data.latitude) <= 90 &&
    typeof data.longitude === 'number' && Math.abs(data.longitude) <= 180 &&
    typeof data.accuracy_metres === 'number' && data.accuracy_metres >= 0 && data.accuracy_metres <= 100 &&
    typeof data.captured_at === 'string' && Number.isInteger(data.checks_remaining))
}

export default function CustomerRiderTracking({ supabase, jobId }: { supabase: SupabaseClient; jobId: string }) {
  const [tracking, setTracking] = useState<Tracking | null>(null)
  const [reveal, setReveal] = useState<Reveal | null>(null)
  const [error, setError] = useState('')
  const [revealError, setRevealError] = useState('')
  const [loading, setLoading] = useState(true)
  const [revealing, setRevealing] = useState(false)
  const [showMap, setShowMap] = useState(false)

  const refresh = useCallback(async () => {
    if (document.hidden) return
    const { data, error: rpcError } = await supabase.rpc('get_my_delivery_tracking', { p_job_id: jobId })
    if (rpcError) { setError('Tracking is unavailable right now.'); setTracking(null); setReveal(null) }
    else if (!validTracking(data)) { setError('Tracking returned an invalid status.'); setTracking(null); setReveal(null) }
    else { setError(''); setTracking(data); if (data.state !== 'live') { setReveal(null); setShowMap(false) } }
    setLoading(false)
  }, [supabase, jobId])

  useEffect(() => {
    const initial = window.setTimeout(() => void refresh(), 0)
    const timer = window.setInterval(() => void refresh(), 60_000)
    const onVisible = () => { if (!document.hidden) void refresh() }
    document.addEventListener('visibilitychange', onVisible)
    return () => { window.clearTimeout(initial); window.clearInterval(timer); document.removeEventListener('visibilitychange', onVisible) }
  }, [refresh])

  async function checkAddress() {
    if (revealing) return
    setRevealing(true); setRevealError('')
    try {
      const { data, error: rpcError } = await supabase.rpc('claim_my_rider_location_check', { p_job_id: jobId })
      if (rpcError || !validClaim(data)) { setRevealError('Could not check the rider location. Try again later.'); return }
      if (data.state === 'limited') {
        setTracking((current) => current ? { ...current, checks_remaining: 0 } : current)
        setRevealError(`Two checks have been used in the last hour.${data.retry_at ? ` Try again after ${new Intl.DateTimeFormat('en-NG', { timeStyle: 'short' }).format(new Date(data.retry_at))}.` : ''}`)
        return
      }
      if (data.state !== 'live') { setRevealError('The rider is not sharing a fresh location right now. No check was used.'); void refresh(); return }
      const latitude = data.latitude!, longitude = data.longitude!, capturedAt = data.captured_at!
      setTracking((current) => current ? { ...current, checks_remaining: data.checks_remaining } : current)
      setReveal(null); setShowMap(false)
      const [addressResult, landmarkResult] = await Promise.allSettled([
        reverseAddress(supabase, { latitude, longitude, accuracyMetres: data.accuracy_metres!, capturedAt: Date.parse(capturedAt), source: 'browser' }),
        closestMappedLandmark(supabase, { latitude, longitude }),
      ])
      const address = addressResult.status === 'fulfilled' ? addressResult.value : null
      const landmark = landmarkResult.status === 'fulfilled' ? landmarkResult.value : null
      const mappedAddress = address && address.distanceMetres !== null &&
        address.distanceMetres <= Math.max(100, data.accuracy_metres! * 2) &&
        (address.confidence === null || address.confidence >= 0.5) ? address : null
      setReveal({ latitude, longitude, accuracy_metres: data.accuracy_metres!, captured_at: capturedAt,
        community: mappedAddress?.community ?? null, street: mappedAddress?.street ?? (mappedAddress?.specificity === 'street' ? mappedAddress.address : null),
        landmark: landmark?.name ?? null, landmarkDistance: landmark?.distanceMetres ?? null })
      if (!mappedAddress) setRevealError('No reliable mapped community or street was found near this GPS point. The checked map location is still available below.')
    } finally { setRevealing(false) }
  }

  const live = tracking?.state === 'live'
  const lat = reveal?.latitude ?? 0, lon = reveal?.longitude ?? 0
  const mapUrl = `https://www.openstreetmap.org/export/embed.html?bbox=${lon - 0.012}%2C${lat - 0.008}%2C${lon + 0.012}%2C${lat + 0.008}&layer=mapnik&marker=${lat}%2C${lon}`
  return <section className="customer-rider-tracking" aria-label="Rider tracking">
    <div className="customer-rider-tracking-head"><strong>Rider progress</strong><button type="button" className="text-button" onClick={() => void refresh()}>Refresh</button></div>
    {loading && <p>Checking rider progress…</p>}
    {error && <p role="status">{error}</p>}
    {!loading && !error && tracking?.state === 'awaiting_rider' && <p>A rider has not been assigned yet.</p>}
    {!loading && !error && tracking?.state === 'offline' && <p>Rider location is unavailable. Tracking resumes when their phone is online and the rider app is open.</p>}
    {!loading && !error && tracking?.state === 'completed' && <p>Tracking ended for this delivery.</p>}
    {live && <>
      <div className="customer-rider-tracking-stats">
        <div><strong>{tracking.eta_minutes == null ? '—' : `~${Math.max(1, tracking.eta_minutes)} min`}</strong><span>to delivery at current pace</span></div>
        <div><strong>{tracking.speed_kmh == null ? '—' : `${tracking.speed_kmh} km/h`}</strong><span>recent GPS speed</span></div>
        <div><strong>{tracking.distance_metres == null ? '—' : tracking.distance_metres < 1000 ? `${Math.round(tracking.distance_metres)} m` : `${(tracking.distance_metres / 1000).toFixed(1)} km`}</strong><span>straight-line distance</span></div>
      </div>
      <p className="customer-rider-tracking-note">Updated {new Intl.DateTimeFormat('en-NG', { timeStyle: 'short' }).format(new Date(tracking.captured_at!))}. ETA excludes pickup, road layout, stops and traffic.</p>
      <div className="customer-rider-reveal-control"><button type="button" className="secondary-button" disabled={revealing || tracking.checks_remaining === 0} onClick={() => void checkAddress()}>{revealing ? 'Checking location…' : 'Check rider address'}</button><small>{tracking.checks_remaining ?? 0} of 2 checks left this hour</small></div>
      {revealError && <p className="customer-rider-tracking-note" role="status">{revealError}</p>}
      {reveal && <div className="customer-rider-address" role="status"><strong>Location at {new Intl.DateTimeFormat('en-NG', { timeStyle: 'short' }).format(new Date(reveal.captured_at))}</strong>
        <dl><div><dt>Community</dt><dd>{reveal.community ?? 'Not mapped'}</dd></div><div><dt>Street</dt><dd>{reveal.street ?? 'Not mapped'}</dd></div><div><dt>Closest mapped landmark</dt><dd>{reveal.landmark ? `${reveal.landmark}${reveal.landmarkDistance == null ? '' : ` · about ${reveal.landmarkDistance} m away`}` : 'None mapped nearby'}</dd></div></dl>
        <small>GPS ±{Math.round(reveal.accuracy_metres)} m. Map labels are estimates, not a verified house address.</small>
        <button type="button" className="secondary-button" onClick={() => setShowMap((shown) => !shown)}>{showMap ? 'Hide location map' : 'Show checked location on map'}</button>
        {showMap && <iframe className="customer-rider-tracking-map" title="Rider's checked location on OpenStreetMap" src={mapUrl} loading="lazy" referrerPolicy="no-referrer" />}
      </div>}
    </>}
  </section>
}
