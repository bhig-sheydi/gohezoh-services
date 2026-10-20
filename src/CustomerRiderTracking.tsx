import { useCallback, useEffect, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import './CustomerRiderTracking.css'

type Tracking = {
  state: 'live' | 'offline' | 'awaiting_rider' | 'completed'
  latitude?: number
  longitude?: number
  accuracy_metres?: number
  captured_at?: string
  distance_metres?: number | null
  speed_kmh?: number | null
  eta_minutes?: number | null
}

function validTracking(value: unknown): value is Tracking {
  if (!value || typeof value !== 'object') return false
  const data = value as Record<string, unknown>
  if (!['live', 'offline', 'awaiting_rider', 'completed'].includes(String(data.state))) return false
  return data.state !== 'live' || (typeof data.latitude === 'number' && Math.abs(data.latitude) <= 90 &&
    typeof data.longitude === 'number' && Math.abs(data.longitude) <= 180 && typeof data.captured_at === 'string')
}

export default function CustomerRiderTracking({ supabase, jobId }: { supabase: SupabaseClient; jobId: string }) {
  const [tracking, setTracking] = useState<Tracking | null>(null)
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const [showMap, setShowMap] = useState(false)

  const refresh = useCallback(async () => {
    if (document.hidden) return
    const { data, error: rpcError } = await supabase.rpc('get_my_delivery_tracking', { p_job_id: jobId })
    if (rpcError) { setError('Tracking is unavailable right now.'); setTracking(null) }
    else if (!validTracking(data)) { setError('Tracking returned an invalid position.'); setTracking(null) }
    else { setError(''); setTracking(data); if (data.state !== 'live') setShowMap(false) }
    setLoading(false)
  }, [supabase, jobId])

  useEffect(() => {
    const initial = window.setTimeout(() => void refresh(), 0)
    const timer = window.setInterval(() => void refresh(), 60_000)
    const onVisible = () => { if (!document.hidden) void refresh() }
    document.addEventListener('visibilitychange', onVisible)
    return () => { window.clearTimeout(initial); window.clearInterval(timer); document.removeEventListener('visibilitychange', onVisible) }
  }, [refresh])

  const live = tracking?.state === 'live' && tracking.latitude !== undefined && tracking.longitude !== undefined
  const lat = tracking?.latitude ?? 0
  const lon = tracking?.longitude ?? 0
  const mapUrl = `https://www.openstreetmap.org/export/embed.html?bbox=${lon - 0.012}%2C${lat - 0.008}%2C${lon + 0.012}%2C${lat + 0.008}&layer=mapnik&marker=${lat}%2C${lon}`
  return <section className="customer-rider-tracking" aria-label="Rider tracking">
    <div className="customer-rider-tracking-head"><strong>Rider location</strong><button type="button" className="text-button" onClick={() => void refresh()}>Refresh</button></div>
    {loading && <p>Checking rider location…</p>}
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
      <p className="customer-rider-tracking-note">Updated {new Intl.DateTimeFormat('en-NG', { timeStyle: 'short' }).format(new Date(tracking.captured_at!))} · GPS ±{Math.round(tracking.accuracy_metres ?? 0)} m. ETA excludes pickup, road layout, stops and traffic; unavailable while speed cannot be measured.</p>
      <button type="button" className="secondary-button" onClick={() => setShowMap((shown) => !shown)}>{showMap ? 'Hide location map' : 'Show rider on map'}</button>
      {showMap && <iframe className="customer-rider-tracking-map" title="Rider's latest location on OpenStreetMap" src={mapUrl} loading="lazy" referrerPolicy="no-referrer" />}
    </>}
  </section>
}
