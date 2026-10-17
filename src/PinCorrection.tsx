import { useEffect, useRef, useState, type PointerEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { nearbyPlaces, reverseAddress, staticPinMap, suggestNearby, type AddressSuggestion, type LocationEvidence } from './lib/geoapify-geocoding'

type Point = { latitude: number; longitude: number }
const width = 320, height = 220
function shifted(point: Point, dx: number, dy: number, zoom: number): Point {
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
  const [zoom, setZoom] = useState(requireMove ? 15 : 17)
  const [image, setImage] = useState<{ key: string; url: string } | null>(null)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const [movedPin, setMovedPin] = useState(false)
  const [retry, setRetry] = useState(0)
  const [offset, setOffset] = useState({ x: 0, y: 0 })
  const drag = useRef<{ id: number; x: number; y: number } | null>(null)
  const placesRequest = useRef(0)
  const [query, setQuery] = useState('')
  const [landmarkQuery, setLandmarkQuery] = useState('')
  const [selectedLabel, setSelectedLabel] = useState('')
  const [selectedStreet, setSelectedStreet] = useState('')
  const [suggestions, setSuggestions] = useState<AddressSuggestion[]>([])
  const [landmarkSuggestions, setLandmarkSuggestions] = useState<AddressSuggestion[]>([])
  const [places, setPlaces] = useState<AddressSuggestion[]>([])
  const [placesLoaded, setPlacesLoaded] = useState(false)
  const [lookupError, setLookupError] = useState('')
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

  useEffect(() => {
    if (query.trim().length < 2) return
    const controller = new AbortController()
    const timer = window.setTimeout(() => {
      void suggestNearby(supabase, query.trim(), 'street', point, controller.signal)
        .then((results) => { if (!controller.signal.aborted) { setSuggestions(results); setLookupError('') } })
        .catch((cause) => { if (!controller.signal.aborted) { setSuggestions([]); setLookupError(cause instanceof Error ? cause.message : 'No nearby matches found.') } })
    }, 400)
    return () => { window.clearTimeout(timer); controller.abort() }
  }, [supabase, query, point])

  useEffect(() => {
    if (!selectedStreet || landmarkQuery.trim().length < 2) return
    const controller = new AbortController()
    const timer = window.setTimeout(() => {
      void suggestNearby(supabase, landmarkQuery.trim(), 'amenity', point, controller.signal, selectedStreet)
        .then((results) => { if (!controller.signal.aborted) { setLandmarkSuggestions(results); setLookupError('') } })
        .catch((cause) => { if (!controller.signal.aborted) { setLandmarkSuggestions([]); setLookupError(cause instanceof Error ? cause.message : 'No landmark found on this street.') } })
    }, 400)
    return () => { window.clearTimeout(timer); controller.abort() }
  }, [supabase, landmarkQuery, point, selectedStreet])

  function beginDrag(event: PointerEvent<HTMLButtonElement>) {
    if (!currentImage) return
    drag.current = { id: event.pointerId, x: event.clientX, y: event.clientY }
    event.currentTarget.setPointerCapture(event.pointerId)
  }
  function moving(event: PointerEvent<HTMLButtonElement>) {
    if (drag.current?.id !== event.pointerId) return
    setOffset({ x: event.clientX - drag.current.x, y: event.clientY - drag.current.y })
  }
  function endDrag(event: PointerEvent<HTMLButtonElement>) {
    const start = drag.current
    if (!start || start.id !== event.pointerId || !currentImage) return
    const rect = event.currentTarget.getBoundingClientRect()
    const dx = event.clientX - start.x, dy = event.clientY - start.y
    const next = Math.hypot(dx, dy) > 6
      ? shifted(point, -dx * width / rect.width, -dy * height / rect.height, zoom)
      : shifted(point, ((event.clientX - rect.left) / rect.width - 0.5) * width, ((event.clientY - rect.top) / rect.height - 0.5) * height, zoom)
    drag.current = null; placesRequest.current++; setOffset({ x: 0, y: 0 }); setPoint(next); setMovedPin(true); setPlaces([])
  }
  function chooseSuggestion(result: AddressSuggestion) {
    setPoint({ latitude: result.latitude, longitude: result.longitude }); setZoom(17)
    setQuery(''); setSelectedLabel(result.address); setSuggestions([]); setPlaces([]); setPlacesLoaded(false); setMovedPin(false)
    setSelectedStreet(result.address); setLandmarkQuery(''); setLandmarkSuggestions([])
    const request = ++placesRequest.current
    void nearbyPlaces(supabase, { latitude: result.latitude, longitude: result.longitude }, result.address)
      .then((results) => { if (request === placesRequest.current) { setPlaces(results); setPlacesLoaded(true) } })
      .catch(() => { if (request === placesRequest.current) { setPlaces([]); setPlacesLoaded(true) } })
  }
  function choosePlace(result: AddressSuggestion) {
    setPoint({ latitude: result.latitude, longitude: result.longitude }); setZoom(18)
    placesRequest.current++; setSelectedLabel(result.address); setPlaces([]); setLandmarkQuery(''); setLandmarkSuggestions([]); setMovedPin(false)
  }
  async function confirm() {
    setBusy(true); setError('')
    let address: AddressSuggestion | null = null
    try { address = await reverseAddress(supabase, { ...point, accuracyMetres: null, capturedAt: Date.now(), source: 'map' }) }
    catch { /* The customer's chosen pin remains valid when reverse geocoding fails. */ }
    onChoose({ ...point, accuracyMetres: null, capturedAt: Date.now(), source: 'map' }, address)
    setBusy(false)
  }
  return <div className="pin-correction" aria-label="Adjust location pin">
    <div className="pin-map-controls"><strong>Choose the entrance</strong><button type="button" onClick={onClose} aria-label="Close pin map">Close</button></div>
    <p>Drag the map under the pin, or tap a location.</p>
    <label className="field"><span>Search street</span><input aria-label="Street name" value={query} placeholder="Type a street name" onChange={(event) => { setQuery(event.target.value); setSuggestions([]) }} /></label>
    {suggestions.length > 0 && <div className="address-suggestions" role="group" aria-label="Nearby mapped suggestions">{suggestions.map((result, index) => <button type="button" key={`${result.latitude}-${result.longitude}-${index}`} onClick={() => chooseSuggestion(result)}>{result.address}{result.city ? `, ${result.city}` : ''}</button>)}</div>}
    {selectedStreet && <label className="field"><span>Search landmark on {selectedStreet}</span><input aria-label="Search landmark on this street" value={landmarkQuery} placeholder="Type a shop, school or landmark" onChange={(event) => { setLandmarkQuery(event.target.value); setLandmarkSuggestions([]) }} /></label>}
    {landmarkSuggestions.length > 0 && <div className="address-suggestions" role="group" aria-label="Landmark search results on selected street">{landmarkSuggestions.map((result, index) => <button type="button" key={`${result.latitude}-${result.longitude}-${index}`} onClick={() => choosePlace(result)}>{result.address}</button>)}</div>}
    {places.length > 0 && <div className="address-suggestions" role="group" aria-label="Landmarks on selected street"><small>Landmarks mapped on {selectedStreet}</small>{places.map((result, index) => <button type="button" key={`${result.latitude}-${result.longitude}-${index}`} onClick={() => choosePlace(result)}>{result.address}{result.distanceMetres != null ? ` · about ${Math.round(result.distanceMetres)} m away` : ''}</button>)}</div>}
    {selectedStreet && placesLoaded && places.length === 0 && <small role="status">No mapped landmarks found on {selectedStreet}. Search one by name or place the pin at the house.</small>}
    {selectedLabel && <small role="status">Near {selectedLabel}. Drag or tap to choose the exact entrance.</small>}
    {lookupError && <small role="status">{lookupError}</small>}
    <button type="button" className="pin-map-image" onPointerDown={beginDrag} onPointerMove={moving} onPointerUp={endDrag} onPointerCancel={() => { drag.current = null; setOffset({ x: 0, y: 0 }) }} aria-label="Drag or tap map to choose a point">
      {currentImage ? <img src={currentImage} alt="Street map around the selected address" draggable={false} style={{ transform: `translate(${offset.x}px, ${offset.y}px)` }} /> : <span>{error ? 'Map unavailable' : 'Loading map...'}</span>}
      <span className="pin-map-marker" aria-hidden="true">●</span>
    </button>
    <div className="pin-map-controls"><button type="button" onClick={() => setZoom(Math.max(14, zoom - 1))}>− Zoom out</button><button type="button" onClick={() => setZoom(Math.min(19, zoom + 1))}>+ Zoom in</button></div>
    {error && <div><small role="alert">{error}</small> <button type="button" className="text-button" onClick={() => { setError(''); setRetry((value) => value + 1) }}>Retry map</button></div>}
    <button type="button" className="primary-button" disabled={busy || !currentImage || (requireMove && !movedPin)} onClick={() => void confirm()}>{busy ? 'Checking pin...' : 'Use this pin'}</button>
    <small>Mapped streets and places may be incomplete. <a href="https://www.geoapify.com/" target="_blank" rel="noreferrer">Powered by Geoapify</a> · <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noreferrer">© OpenStreetMap contributors</a></small>
  </div>
}
