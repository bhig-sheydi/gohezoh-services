import { useEffect, useRef, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { ParcelDestination } from './ParcelPalsPanel'
import { requestAddressPosition } from './lib/proximity'
import { identifyCurrentLocation, searchAddress, suggestAddresses, suggestNearby, type AddressSuggestion, type LocationEvidence } from './lib/geoapify-geocoding'
import PinCorrection from './PinCorrection'

type Point = { latitude: number; longitude: number }
type Kind = 'pickup' | 'delivery'
const savedFix = (address?: ParcelDestination | null): LocationEvidence | null =>
  typeof address?.latitude === 'number' && Number.isFinite(address.latitude) && typeof address.longitude === 'number' && Number.isFinite(address.longitude)
    ? { latitude: address.latitude, longitude: address.longitude, accuracyMetres: null, capturedAt: Date.now(), source: 'saved' }
    : null

export default function UnifiedLocationPicker({ kind, supabase, userId, destination, onCitySelected }: {
  kind: Kind; supabase: SupabaseClient; userId?: string; destination?: ParcelDestination | null; onCitySelected?: (city: string) => void
}) {
  const [city, setCity] = useState(destination?.city ?? '')
  const [query, setQuery] = useState(destination?.address ?? '')
  const [address, setAddress] = useState(destination?.address ?? '')
  const [fix, setFix] = useState<LocationEvidence | null>(() => savedFix(destination))
  const [point, setPoint] = useState<Point | null>(() => savedFix(destination))
  const [suggestions, setSuggestions] = useState<AddressSuggestion[]>([])
  const [searching, setSearching] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [note, setNote] = useState(destination ? 'Saved delivery location' : '')
  const [needsPin, setNeedsPin] = useState(false)
  const [saved, setSaved] = useState<ParcelDestination[]>([])
  const [slot, setSlot] = useState('')
  const [pinVersion, setPinVersion] = useState(0)
  const root = useRef<HTMLDivElement>(null)
  const pending = useRef<AbortController | null>(null)

  useEffect(() => {
    const form = root.current?.closest('form')
    const readCity = () => {
      const input = form?.elements.namedItem(`${kind}_city`)
      if (input instanceof HTMLSelectElement || input instanceof HTMLInputElement) setCity(input.value)
    }
    readCity()
    const changed = (event: Event) => {
      const target = event.target as HTMLInputElement
      if (target.name !== `${kind}_city`) return
      readCity()
      pending.current?.abort(); pending.current = null
      setFix(null); setPoint(null); setSuggestions([]); setAddress(''); setQuery(''); setSlot(''); setNote(''); setError(''); setNeedsPin(false)
    }
    const reset = () => { pending.current?.abort(); pending.current = null; setFix(null); setPoint(null); setSuggestions([]); setAddress(''); setQuery(''); setSlot(''); setNote(''); setError(''); setNeedsPin(false) }
    form?.addEventListener('change', changed); form?.addEventListener('reset', reset)
    return () => { pending.current?.abort(); form?.removeEventListener('change', changed); form?.removeEventListener('reset', reset) }
  }, [kind])

  useEffect(() => {
    if (!userId || kind !== 'pickup') return
    let active = true
    void supabase.from('customer_parcel_destinations').select('slot,label,address,city,state,latitude,longitude,location_source,location_accuracy_metres')
      .eq('user_id', userId).order('slot').then(({ data }) => { if (active) setSaved((data ?? []) as ParcelDestination[]) })
    return () => { active = false }
  }, [kind, supabase, userId])

  useEffect(() => {
    if (query.trim().length < 3 || fix) return
    const controller = new AbortController()
    const timer = window.setTimeout(() => {
      setSearching(true)
      void suggestAddresses(supabase, `${query.trim()}${city ? `, ${city}` : ''}, Nigeria`, controller.signal)
        .then((results) => { if (!controller.signal.aborted) { setSuggestions(results.filter((item) => !city || !item.city || item.city.toLowerCase() === city.toLowerCase())); setSearching(false) } })
        .catch(() => { if (!controller.signal.aborted) { setSuggestions([]); setSearching(false) } })
    }, 350)
    return () => { window.clearTimeout(timer); controller.abort() }
  }, [query, city, fix, supabase])

  function chooseResult(result: AddressSuggestion, nearby = false) {
    setQuery(result.address); setAddress(result.address); setFix(result.evidence)
    setPoint(result.evidence); setPinVersion((value) => value + 1)
    setSuggestions([]); setSearching(false); setError(''); setSlot('')
    const broad = result.specificity === 'area' || result.confidence !== null && result.confidence < 0.7
    setNeedsPin(broad)
    setNote(broad ? 'Only a broad area was found. Adjust the pin to confirm the location.' : nearby ? 'Matched near your phone. Confirm the point.' : 'Confirm this mapped point.')
  }

  function chooseSaved(value: string) {
    setSlot(value); setError(''); setSuggestions([])
    const selected = saved.find((item) => String(item.slot) === value)
    if (!selected) { setQuery(''); setAddress(''); setFix(null); setPoint(null); setNote(''); setNeedsPin(false); return }
    const evidence = savedFix(selected)
    setQuery(selected.address); setAddress(selected.address); setFix(evidence); setPoint(evidence)
    setPinVersion((version) => version + 1); setCity(selected.city)
    setNote(evidence ? 'Saved pickup location' : '')
    if (!evidence) setError('This saved address has no map point. Select a search result or update it in Edit my delivery info.')
    setNeedsPin(false); onCitySelected?.(selected.city)
  }

  async function find() {
    if (pending.current || query.trim().length < 3) return
    const controller = new AbortController(); pending.current = controller
    setBusy(true); setError(''); setSuggestions([])
    try {
      const cityValue = city || (root.current?.closest('form')?.elements.namedItem(`${kind}_city`) as HTMLSelectElement | null)?.value || ''
      if (!cityValue) throw new Error(`Choose the ${kind} city first.`)
      let device: Awaited<ReturnType<typeof requestAddressPosition>> | null = null
      try { device = await requestAddressPosition({ signal: controller.signal }) }
      catch { /* Text lookup still works if the user denies location or GPS times out. */ }
      controller.signal.throwIfAborted()
      let result: AddressSuggestion | undefined
      if (device && device.accuracyMetres <= 500) {
        const nearby = await Promise.allSettled([
          suggestNearby(supabase, query.trim(), 'amenity', device, controller.signal, undefined, 10000),
          suggestNearby(supabase, query.trim(), 'street', device, controller.signal, undefined, 10000),
        ])
        result = nearby.flatMap((entry) => entry.status === 'fulfilled' ? entry.value : [])
          .find((item) => !item.city || item.city.toLowerCase() === cityValue.toLowerCase())
      }
      result ??= await searchAddress(supabase, `${query.trim()}, ${cityValue}, Nigeria`, controller.signal)
      if (result.city && result.city.toLowerCase() !== cityValue.toLowerCase()) throw new Error(`That result is in ${result.city}, not ${cityValue}. Try another nearby place.`)
      if (!controller.signal.aborted) chooseResult(result, !!device && result.distanceMetres !== null)
    } catch (cause) { if (!controller.signal.aborted) setError(cause instanceof Error ? cause.message : 'Could not find that place.') }
    finally { if (pending.current === controller) pending.current = null; if (!controller.signal.aborted) setBusy(false) }
  }

  async function findCurrentPosition() {
    if (pending.current) return
    const controller = new AbortController(); pending.current = controller
    setBusy(true); setError('')
    try {
      const device = await requestAddressPosition({ signal: controller.signal })
      const result = await identifyCurrentLocation(supabase, device, controller.signal)
      if (!controller.signal.aborted) {
        setQuery(result.label); setAddress(result.label); setFix(device); setPoint(device)
        setPinVersion((value) => value + 1); setSuggestions([])
        const areaOnly = result.landmarkDistanceMetres === null && result.matchedAddress?.specificity === 'area'
        setNote(areaOnly
          ? `Phone accuracy ±${Math.round(device.accuracyMetres)} m. The map found only an area, not your building or street. Add the exact address or search a nearby place before confirming.`
          : `${result.landmarkDistanceMetres === null ? 'Mapped address' : `Named place ${result.landmarkDistanceMetres} m away`} · phone accuracy ±${Math.round(device.accuracyMetres)} m. Confirm the point.`)
        setNeedsPin(device.accuracyMetres > 100)
      }
    } catch (cause) { if (!controller.signal.aborted) setError(cause instanceof Error ? cause.message : 'Could not get your location.') }
    finally { if (pending.current === controller) pending.current = null; if (!controller.signal.aborted) setBusy(false) }
  }

  return <div ref={root} className={`field unified-location-picker ${kind}-location`}>
    {saved.length > 0 && kind === 'pickup' && <label className="field"><span>My pickup addresses</span><select value={slot} onChange={(event) => chooseSaved(event.target.value)}><option value="">Use a new place</option>{saved.map((item) => <option key={item.slot} value={item.slot}>{item.label} — {item.address}</option>)}</select></label>}
    <label className="field"><span>{kind === 'pickup' ? 'Pickup place' : 'Drop-off place'}</span>
      <input className="location-single-search" type="search" autoComplete="off" aria-label={`${kind === 'pickup' ? 'Pickup' : 'Drop-off'} place search`} placeholder={`Search the closest known place to you in ${city || 'the selected city'}`} value={query} required onChange={(event) => { setQuery(event.target.value); setAddress(event.target.value); setFix(null); setPoint(null); setNote(''); setSlot(''); setError(''); setNeedsPin(false) }} />
    </label>
    {searching && <small role="status" className="address-search-status"><span className="address-search-spinner" aria-hidden="true" />Searching places...</small>}
    {suggestions.length > 0 && <div className="address-suggestions" role="group" aria-label={`${kind} place suggestions`}>{suggestions.map((item, index) => <button type="button" key={`${item.latitude}-${item.longitude}-${index}`} onClick={() => chooseResult(item)}><strong>{item.address}</strong><small>{item.city}, {item.state}</small></button>)}</div>}
    <div className="field-row"><button type="button" className="secondary-button" disabled={busy || query.trim().length < 3} onClick={() => void find()}>{busy ? 'Finding location...' : 'Find location'}</button><button type="button" className="text-button" disabled={busy} onClick={() => void findCurrentPosition()}>I'm here — use GPS</button></div>
    {error && <small role="alert">{error}</small>}
    {fix && point && <><small role="status">{note || 'Confirm this location.'}</small>
      <PinCorrection key={pinVersion} supabase={supabase} initial={point} compactMap hideSearch requireMove={needsPin} onChoose={(evidence) => { setFix(evidence); setPoint(evidence); setNeedsPin(false); setNote('Pin chosen by you. Confirm this point.') }} />
      {!needsPin && <label className="recipient-location-confirm"><input type="checkbox" name={`${kind}_location_confirmed`} value="yes" required />This is the {kind} location.</label>}
      {slot && kind === 'pickup' && <input type="hidden" name="pickup_saved_slot" value={slot} />}
      <input type="hidden" name={`${kind}_latitude`} value={fix.latitude} /><input type="hidden" name={`${kind}_longitude`} value={fix.longitude} />
      <input type="hidden" name={`${kind}_accuracy_metres`} value={fix.accuracyMetres ?? ''} /><input type="hidden" name={`${kind}_location_source`} value={fix.source} />
      <input type="hidden" name={`${kind}_captured_at`} value={new Date(fix.capturedAt).toISOString()} />
    </>}
    <input type="hidden" name={`${kind}_address`} value={address} /><input type="hidden" name={`${kind}_community`} value="" />
  </div>
}
