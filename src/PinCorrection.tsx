import { useCallback, useEffect, useRef, useState, type PointerEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { mapTile, reverseAddress, suggestAddresses, suggestNearby, type AddressSuggestion, type LocationEvidence } from './lib/geoapify-geocoding'

type Point = { latitude: number; longitude: number }
const tileSize = 256
function project(point: Point, zoom: number) {
  const size = tileSize * 2 ** zoom
  const lat = Math.max(-85, Math.min(85, point.latitude)) * Math.PI / 180
  return { x: (point.longitude + 180) / 360 * size, y: (1 - Math.log(Math.tan(lat) + 1 / Math.cos(lat)) / Math.PI) / 2 * size }
}
function shifted(point: Point, dx: number, dy: number, zoom: number): Point {
  const size = tileSize * 2 ** zoom
  const center = project(point, zoom)
  const x = center.x + dx, y = center.y + dy
  return { longitude: x / size * 360 - 180, latitude: Math.atan(Math.sinh(Math.PI * (1 - 2 * y / size))) * 180 / Math.PI }
}

function MapTile({ supabase, z, x, y, left, top, onFailure }: { supabase: SupabaseClient; z: number; x: number; y: number; left: number; top: number; onFailure: () => void }) {
  const [url, setUrl] = useState('')
  useEffect(() => {
    const controller = new AbortController()
    let objectUrl = ''
    void mapTile(supabase, z, x, y, controller.signal)
      .then((blob) => { if (!controller.signal.aborted) { objectUrl = URL.createObjectURL(blob); setUrl(objectUrl) } })
      .catch(() => { if (!controller.signal.aborted) onFailure() })
    return () => { controller.abort(); if (objectUrl) URL.revokeObjectURL(objectUrl) }
  }, [supabase, z, x, y, onFailure])
  return url ? <img className="pin-map-tile" src={url} alt="" draggable={false} style={{ left, top }} /> : null
}

export default function PinCorrection({ supabase, initial, onChoose, onClose, requireMove = false, streetInputName, initialStreet = '', onStreetChange, onPointChange }: {
  supabase: SupabaseClient; initial: Point; onChoose: (evidence: LocationEvidence, address: AddressSuggestion | null) => void; onClose?: () => void; requireMove?: boolean
  streetInputName?: string; initialStreet?: string; onStreetChange?: (street: string) => void; onPointChange?: () => void
}) {
  const [point, setPoint] = useState(initial)
  const [zoom, setZoom] = useState(requireMove ? 15 : 17)
  const [viewport, setViewport] = useState({ width: 360, height: 320 })
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const [movedPin, setMovedPin] = useState(false)
  const [offset, setOffset] = useState({ x: 0, y: 0 })
  const mapRef = useRef<HTMLButtonElement | null>(null)
  const drag = useRef<{ id: number; x: number; y: number } | null>(null)
  const [query, setQuery] = useState(initialStreet)
  const [landmarkQuery, setLandmarkQuery] = useState('')
  const [selectedLabel, setSelectedLabel] = useState('')
  const [selectedStreet, setSelectedStreet] = useState(initialStreet)
  const [suggestions, setSuggestions] = useState<AddressSuggestion[]>([])
  const [streetStatus, setStreetStatus] = useState<'idle' | 'loading' | 'empty' | 'results'>('idle')
  const [landmarkSuggestions, setLandmarkSuggestions] = useState<AddressSuggestion[]>([])
  const [sideStreetSuggestions, setSideStreetSuggestions] = useState<AddressSuggestion[]>([])
  const [landmarkStatus, setLandmarkStatus] = useState<'idle' | 'loading' | 'empty' | 'results'>('idle')
  const [lookupError, setLookupError] = useState('')
  const tileFailed = useCallback(() => setError('Some map tiles could not load. Try moving or zooming the map.'), [])
  useEffect(() => {
    const element = mapRef.current
    if (!element) return
    const resize = () => setViewport({ width: element.clientWidth || 360, height: element.clientHeight || 320 })
    resize()
    if (typeof ResizeObserver === 'undefined') return
    const observer = new ResizeObserver(resize)
    observer.observe(element)
    return () => observer.disconnect()
  }, [])
  const center = project(point, zoom)
  const tiles: { x: number; y: number; left: number; top: number }[] = []
  const firstX = Math.floor((center.x - viewport.width / 2) / tileSize) - 1
  const lastX = Math.floor((center.x + viewport.width / 2) / tileSize) + 1
  const firstY = Math.floor((center.y - viewport.height / 2) / tileSize) - 1
  const lastY = Math.floor((center.y + viewport.height / 2) / tileSize) + 1
  for (let x = firstX; x <= lastX; x++) for (let y = firstY; y <= lastY; y++) {
    if (x >= 0 && y >= 0 && x < 2 ** zoom && y < 2 ** zoom)
      tiles.push({ x, y, left: x * tileSize - center.x + viewport.width / 2, top: y * tileSize - center.y + viewport.height / 2 })
  }
  tiles.sort((a, b) => (Math.abs(a.left + tileSize / 2 - viewport.width / 2) + Math.abs(a.top + tileSize / 2 - viewport.height / 2)) -
    (Math.abs(b.left + tileSize / 2 - viewport.width / 2) + Math.abs(b.top + tileSize / 2 - viewport.height / 2)))

  useEffect(() => {
    if (query.trim().length < 2 || (selectedStreet && query === selectedStreet)) return
    const controller = new AbortController()
    const timer = window.setTimeout(() => {
      void suggestNearby(supabase, query.trim(), 'street', point, controller.signal)
        .then(async (nearby) => nearby.length || query.trim().length < 3 ? nearby : (await suggestAddresses(supabase, query.trim(), controller.signal)).filter((item) => item.resultType === 'street' || item.specificity === 'street'))
        .then((results) => { if (!controller.signal.aborted) { setSuggestions(results); setStreetStatus(results.length ? 'results' : 'empty'); setLookupError('') } })
        .catch((cause) => { if (!controller.signal.aborted) { setSuggestions([]); setStreetStatus('empty'); setLookupError(cause instanceof Error ? cause.message : 'Street search is unavailable.') } })
    }, 400)
    return () => { window.clearTimeout(timer); controller.abort() }
  }, [supabase, query, point, selectedStreet])

  useEffect(() => {
    if (!selectedStreet || landmarkQuery.trim().length < 2) return
    const controller = new AbortController()
    const timer = window.setTimeout(() => {
      void Promise.allSettled([
        suggestNearby(supabase, landmarkQuery.trim(), 'street', point, controller.signal, selectedStreet),
        suggestNearby(supabase, landmarkQuery.trim(), 'amenity', point, controller.signal, selectedStreet),
      ]).then(([streetsResult, landmarksResult]) => {
        if (controller.signal.aborted) return
        const streets = streetsResult.status === 'fulfilled'
          ? streetsResult.value.filter((item) => item.address.toLowerCase() !== selectedStreet.toLowerCase()).slice(0, 5) : []
        const landmarks = landmarksResult.status === 'fulfilled' ? landmarksResult.value.slice(0, 5) : []
        setSideStreetSuggestions(streets); setLandmarkSuggestions(landmarks)
        setLandmarkStatus(streets.length || landmarks.length ? 'results' : 'empty')
        setLookupError(streetsResult.status === 'rejected' && landmarksResult.status === 'rejected' ? 'Nearby place search is unavailable. You can still place the pin manually.' : '')
      })
    }, 400)
    return () => { window.clearTimeout(timer); controller.abort() }
  }, [supabase, landmarkQuery, point, selectedStreet])

  function beginDrag(event: PointerEvent<HTMLButtonElement>) {
    drag.current = { id: event.pointerId, x: event.clientX, y: event.clientY }
    event.currentTarget.setPointerCapture(event.pointerId)
  }
  function moving(event: PointerEvent<HTMLButtonElement>) {
    if (drag.current?.id !== event.pointerId) return
    setOffset({ x: event.clientX - drag.current.x, y: event.clientY - drag.current.y })
  }
  function endDrag(event: PointerEvent<HTMLButtonElement>) {
    const start = drag.current
    if (!start || start.id !== event.pointerId) return
    const rect = event.currentTarget.getBoundingClientRect()
    const dx = event.clientX - start.x, dy = event.clientY - start.y
    const next = Math.hypot(dx, dy) > 6
      ? shifted(point, -dx, -dy, zoom)
      : shifted(point, event.clientX - rect.left - rect.width / 2, event.clientY - rect.top - rect.height / 2, zoom)
    drag.current = null; setOffset({ x: 0, y: 0 }); onPointChange?.(); setPoint(next); setMovedPin(true)
  }
  function chooseSuggestion(result: AddressSuggestion) {
    onStreetChange?.(result.address)
    setPoint({ latitude: result.latitude, longitude: result.longitude }); setZoom(17)
    setQuery(result.address); setSelectedLabel(result.address); setSuggestions([]); setMovedPin(false)
    setSelectedStreet(result.address); setStreetStatus('idle'); setLandmarkQuery(''); setLandmarkSuggestions([]); setSideStreetSuggestions([]); setLandmarkStatus('idle')
  }
  function choosePlace(result: AddressSuggestion) {
    setPoint({ latitude: result.latitude, longitude: result.longitude }); setZoom(18)
    setSelectedLabel(result.address); setLandmarkQuery(''); setLandmarkSuggestions([]); setSideStreetSuggestions([]); setLandmarkStatus('idle'); setMovedPin(false)
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
    <div className="pin-map-controls"><strong>Choose the entrance</strong>{onClose && <button type="button" onClick={onClose} aria-label="Close pin map">Close</button>}</div>
    <p>Drag the map under the pin, or tap a location.</p>
    <label className="field pin-street-field"><span>Search street</span><input type="text" name={streetInputName} required={!!streetInputName} aria-label="Street name" value={query} placeholder="Type a street name" autoComplete="street-address" onChange={(event) => { setQuery(event.target.value); onStreetChange?.(event.target.value); setSelectedStreet(''); setStreetStatus(event.target.value.trim().length >= 2 ? 'loading' : 'idle'); setLookupError(''); setLandmarkQuery(''); setLandmarkSuggestions([]); setSideStreetSuggestions([]); setLandmarkStatus('idle'); setSuggestions([]) }} /></label>
    {suggestions.length > 0 && <div className="address-suggestions" role="group" aria-label="Nearby mapped suggestions">{suggestions.map((result, index) => <button type="button" key={`${result.latitude}-${result.longitude}-${index}`} onClick={() => chooseSuggestion(result)}>{result.address}{result.city ? `, ${result.city}` : ''}</button>)}</div>}
    {streetStatus === 'loading' && <small role="status">Searching streets...</small>}
    {streetStatus === 'empty' && !lookupError && <small role="status">No mapped street found. Try a shorter name or enter the address manually.</small>}
    {selectedStreet && <label className="field"><span>Search a close, side street or landmark off {selectedStreet}</span><input aria-label="Search close, side street or landmark" value={landmarkQuery} placeholder="School gate, market, close..." onChange={(event) => { setLandmarkQuery(event.target.value); setLandmarkSuggestions([]); setSideStreetSuggestions([]); setLandmarkStatus(event.target.value.trim().length >= 2 ? 'loading' : 'idle') }} /></label>}
    {sideStreetSuggestions.length > 0 && <div className="address-suggestions" role="group" aria-label="Streets and closes by selected street"><small>Select only if this road connects to {selectedStreet}.</small>{sideStreetSuggestions.map((result, index) => <button type="button" key={`${result.latitude}-${result.longitude}-${index}`} onClick={() => chooseSuggestion(result)}>{result.address}{result.city ? `, ${result.city}` : ''}</button>)}</div>}
    {landmarkSuggestions.length > 0 && <div className="address-suggestions" role="group" aria-label="Landmarks on selected street">{landmarkSuggestions.map((result, index) => <button type="button" key={`${result.latitude}-${result.longitude}-${index}`} onClick={() => choosePlace(result)}>{result.address}</button>)}</div>}
    {landmarkStatus === 'loading' && <small role="status">Searching streets, closes and landmarks...</small>}
    {landmarkStatus === 'empty' && !lookupError && <small role="status">No mapped street, close or landmark with that name by {selectedStreet}. Try a shorter name or place the pin at the house.</small>}
    {selectedLabel && <small role="status">Near {selectedLabel}. Drag or tap to choose the exact entrance.</small>}
    {lookupError && <small role="status">{lookupError}</small>}
    <button type="button" ref={mapRef} className="pin-map-image" onPointerDown={beginDrag} onPointerMove={moving} onPointerUp={endDrag} onPointerCancel={() => { drag.current = null; setOffset({ x: 0, y: 0 }) }} aria-label="Drag or tap map to choose a point">
      <span className="pin-map-tile-layer" aria-hidden="true" style={{ transform: `translate(${offset.x}px, ${offset.y}px)` }}>{tiles.map((tile) => <MapTile key={`${zoom}/${tile.x}/${tile.y}`} supabase={supabase} z={zoom} x={tile.x} y={tile.y} left={tile.left} top={tile.top} onFailure={tileFailed} />)}</span>
      <span className="pin-map-marker" aria-hidden="true" />
    </button>
    <div className="pin-map-controls"><button type="button" onClick={() => setZoom(Math.max(14, zoom - 1))}>− Zoom out</button><button type="button" onClick={() => setZoom(Math.min(19, zoom + 1))}>+ Zoom in</button></div>
    {error && <small role="alert">{error}</small>}
    <button type="button" className="primary-button" disabled={busy || (requireMove && !movedPin)} onClick={() => void confirm()}>{busy ? 'Checking pin...' : 'Use this pin'}</button>
    <small>Mapped streets and places may be incomplete. <a href="https://www.geoapify.com/" target="_blank" rel="noreferrer">Geoapify</a> · <a href="https://openmaptiles.org/" target="_blank" rel="noreferrer">© OpenMapTiles</a> · <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noreferrer">© OpenStreetMap contributors</a></small>
  </div>
}
