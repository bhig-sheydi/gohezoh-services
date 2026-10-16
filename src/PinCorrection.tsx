import { useEffect, useState, type MouseEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { reverseAddress, staticPinMap, type AddressSuggestion, type LocationEvidence } from './lib/geoapify-geocoding'

type Point = { latitude: number; longitude: number }
const width = 320, height = 220
function moved(point: Point, dx: number, dy: number, zoom: number): Point {
  const size = 256 * 2 ** zoom
  const lat = Math.max(-85, Math.min(85, point.latitude)) * Math.PI / 180
  const x = (point.longitude + 180) / 360 * size + dx
  const y = (1 - Math.log(Math.tan(lat) + 1 / Math.cos(lat)) / Math.PI) / 2 * size + dy
  return { longitude: x / size * 360 - 180, latitude: Math.atan(Math.sinh(Math.PI * (1 - 2 * y / size))) * 180 / Math.PI }
}

export default function PinCorrection({ supabase, initial, onChoose, onClose, requireMove = false }: {
  supabase: SupabaseClient; initial: Point; onChoose: (evidence: LocationEvidence, address: AddressSuggestion | null) => void; onClose: () => void; requireMove?: boolean
}) {
  const [point, setPoint] = useState(initial)
  const [zoom, setZoom] = useState(17)
  const [image, setImage] = useState<{ key: string; url: string } | null>(null)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const [movedPin, setMovedPin] = useState(false)
  const [retry, setRetry] = useState(0)
  const mapKey = `${point.latitude}:${point.longitude}:${zoom}`
  const currentImage = image?.key === mapKey ? image.url : ''
  useEffect(() => {
    const controller = new AbortController()
    let url = ''
    void staticPinMap(supabase, point.latitude, point.longitude, zoom, controller.signal)
      .then((blob) => { if (!controller.signal.aborted) { url = URL.createObjectURL(blob); setImage({ key: `${point.latitude}:${point.longitude}:${zoom}`, url }); setError('') } })
      .catch((cause) => { if (!controller.signal.aborted) setError(cause instanceof Error ? cause.message : 'Map unavailable') })
    return () => { controller.abort(); if (url) URL.revokeObjectURL(url) }
  }, [supabase, point.latitude, point.longitude, zoom, retry])
  function place(event: MouseEvent<HTMLButtonElement>) {
    if (event.detail === 0 || !currentImage) return
    const rect = event.currentTarget.getBoundingClientRect()
    const dx = ((event.clientX - rect.left) / rect.width - 0.5) * width
    const dy = ((event.clientY - rect.top) / rect.height - 0.5) * height
    setPoint(moved(point, dx, dy, zoom)); setMovedPin(true)
  }
  async function confirm() {
    setBusy(true); setError('')
    let address: AddressSuggestion | null = null
    try { address = await reverseAddress(supabase, { ...point, accuracyMetres: null, capturedAt: Date.now(), source: 'map' }) }
    catch { /* The chosen pin is useful even when the map has no street address. */ }
    onChoose({ ...point, accuracyMetres: null, capturedAt: Date.now(), source: 'map' }, address)
    setBusy(false)
  }
  return <div className="pin-correction" aria-label="Adjust location pin">
    <div className="pin-map-controls"><strong>Adjust pin</strong><button type="button" onClick={onClose} aria-label="Close pin map">Close</button></div>
    <p>Tap the actual pickup or delivery entrance. The written address can still be edited.</p>
    <button type="button" className="pin-map-image" onClick={place} aria-label="Choose a point on the map">
      {currentImage ? <img src={currentImage} alt="Street map around the selected address" /> : <span>{error ? "Map unavailable" : "Loading map..."}</span>}
      <span className="pin-map-marker" aria-hidden="true">●</span>
    </button>
    <div className="pin-map-controls"><button type="button" onClick={() => setZoom(Math.max(14, zoom - 1))}>− Zoom out</button><button type="button" onClick={() => setZoom(Math.min(19, zoom + 1))}>+ Zoom in</button></div>
    {error && <div><small role="alert">{error}</small> <button type="button" className="text-button" onClick={() => { setError(''); setRetry((value) => value + 1) }}>Retry map</button></div>}
    <button type="button" className="primary-button" disabled={busy || !currentImage || (requireMove && !movedPin)} onClick={() => void confirm()}>{busy ? 'Checking pin…' : 'Use this pin'}</button>
    <small>Map data © OpenStreetMap contributors, rendered by Geoapify.</small>
  </div>
}
