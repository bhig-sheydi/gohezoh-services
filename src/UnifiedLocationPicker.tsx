import { useEffect, useRef, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { ParcelDestination } from './ParcelPalsPanel'
import { requestAddressPosition, type PositionFix } from './lib/proximity'
import { identifyCurrentLocation, searchAddress, suggestAddresses, suggestNearby, type AddressSuggestion, type LocationEvidence } from './lib/geoapify-geocoding'
import { googleMapsDemoEnabled } from './lib/google-maps'
import { googleAutocomplete, newGoogleAutocompleteSession, type GoogleAutocompleteOption, type GoogleAutocompleteSession } from './lib/google-geocoding'
import { searchSharedDeliveryPlaces } from './lib/shared-delivery-places'
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
  const [googleOptions, setGoogleOptions] = useState<GoogleAutocompleteOption[]>([])
  const [providerOnly, setProviderOnly] = useState(false)
  const [offerProvider, setOfferProvider] = useState(false)
  const [customerQuery, setCustomerQuery] = useState('')
  const [userMovedPin, setUserMovedPin] = useState(false)
  const [nearbyPhonePoint, setNearbyPhonePoint] = useState<PositionFix | null>(null)
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
  const autocompleteSession = useRef<GoogleAutocompleteSession | null>(null)

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
      pending.current?.abort(); pending.current = null; autocompleteSession.current = null
      setFix(null); setPoint(null); setSuggestions([]); setGoogleOptions([]); setAddress(''); setQuery(''); setSlot(''); setNote(''); setError(''); setNeedsPin(false); setProviderOnly(false); setOfferProvider(false); setCustomerQuery(''); setUserMovedPin(false); setNearbyPhonePoint(null)
    }
    const reset = () => { pending.current?.abort(); pending.current = null; autocompleteSession.current = null; setFix(null); setPoint(null); setSuggestions([]); setGoogleOptions([]); setAddress(''); setQuery(''); setSlot(''); setNote(''); setError(''); setNeedsPin(false); setProviderOnly(false); setOfferProvider(false); setCustomerQuery(''); setUserMovedPin(false); setNearbyPhonePoint(null) }
    form?.addEventListener('change', changed); form?.addEventListener('reset', reset)
    return () => { pending.current?.abort(); form?.removeEventListener('change', changed); form?.removeEventListener('reset', reset) }
  }, [kind])

  useEffect(() => {
    if (!userId) return
    let active = true
    void supabase.from('customer_parcel_destinations').select('slot,label,address,city,state,latitude,longitude,location_source,location_accuracy_metres')
      .eq('user_id', userId).order('slot').then(({ data }) => { if (active) setSaved((data ?? []) as ParcelDestination[]) })
    return () => { active = false }
  }, [kind, supabase, userId])

  useEffect(() => {
    if (query.trim().length < 3 || fix || nearbyPhonePoint) return
    const controller = new AbortController()
    const timer = window.setTimeout(() => {
      const text = `${query.trim()}${city ? `, ${city}` : ''}, Nigeria`
      void (async () => {
        if (!providerOnly) {
          try {
            const local = await searchSharedDeliveryPlaces(supabase, query, city, undefined, controller.signal)
            if (controller.signal.aborted) return
            if (local.length) {
              setSuggestions(local); setGoogleOptions([]); setOfferProvider(true)
              return
            }
          } catch {
            // A failed or rate-limited local search must not automatically
            // multiply paid provider requests. The customer can still opt in.
            if (!controller.signal.aborted) {
              setSuggestions([]); setGoogleOptions([]); setOfferProvider(true)
              setError('Saved places are unavailable. Tap Search more places to use the map.')
            }
            return
          }
        }
        if (controller.signal.aborted) return
        setOfferProvider(false); setError('')
        if (googleMapsDemoEnabled) {
          autocompleteSession.current ??= newGoogleAutocompleteSession()
          const results = await googleAutocomplete(text, autocompleteSession.current, controller.signal)
          if (!controller.signal.aborted) { setSuggestions([]); setGoogleOptions(results) }
        } else {
          const results = await suggestAddresses(supabase, text, controller.signal)
          if (!controller.signal.aborted) {
            setGoogleOptions([])
            setSuggestions(results.filter((item) => !city || !item.city || item.city.toLowerCase() === city.toLowerCase()))
          }
        }
      })().catch(() => { if (!controller.signal.aborted) { setSuggestions([]); setGoogleOptions([]) } })
        .finally(() => { if (!controller.signal.aborted) setSearching(false) })
    }, 600)
    return () => { window.clearTimeout(timer); controller.abort() }
  }, [query, city, fix, supabase, providerOnly, nearbyPhonePoint])

  function chooseResult(result: AddressSuggestion, nearby = false) {
    autocompleteSession.current = null
    setQuery(result.address); setAddress(result.address); setFix(result.evidence)
    setPoint(result.evidence); setPinVersion((value) => value + 1)
    setSuggestions([]); setGoogleOptions([]); setSearching(false); setError(''); setSlot(''); setOfferProvider(false); setProviderOnly(false); setUserMovedPin(false); setNearbyPhonePoint(null)
    const broad = result.specificity === 'area' || result.confidence !== null && result.confidence < 0.7
    setNeedsPin(broad)
    setNote(broad ? 'Only a broad area was found. Adjust the pin to confirm the location.' : nearby ? 'Matched near your phone. Confirm the point.' : 'Confirm this mapped point.')
  }

  async function chooseGoogleOption(option: GoogleAutocompleteOption) {
    if (pending.current) return
    const controller = new AbortController(); pending.current = controller
    setBusy(true); setError('')
    try {
      const result = await option.select(controller.signal)
      if (result.city && city && result.city.toLowerCase() !== city.toLowerCase())
        throw new Error(`That result is in ${result.city}, not ${city}. Try another nearby place.`)
      if (!controller.signal.aborted) chooseResult(result)
    } catch (cause) {
      if (!controller.signal.aborted) setError(cause instanceof Error ? cause.message : 'Could not select that place.')
    } finally {
      if (pending.current === controller) pending.current = null
      if (!controller.signal.aborted) setBusy(false)
    }
  }

  function chooseSaved(value: string) {
    autocompleteSession.current = null
    setSlot(value); setError(''); setSuggestions([]); setGoogleOptions([]); setOfferProvider(false); setProviderOnly(false); setCustomerQuery(''); setUserMovedPin(false); setNearbyPhonePoint(null)
    const selected = saved.find((item) => String(item.slot) === value)
    if (!selected) { setQuery(''); setAddress(''); setFix(null); setPoint(null); setNote(''); setNeedsPin(false); return }
    const evidence = savedFix(selected)
    setQuery(selected.address); setAddress(selected.address); setFix(evidence); setPoint(evidence)
    setPinVersion((version) => version + 1); setCity(selected.city)
    setNote(evidence ? `Saved ${kind === 'pickup' ? 'pickup' : 'drop-off'} location` : '')
    if (!evidence) setError('This saved address has no map point. Select a search result or update it in Edit my delivery info.')
    setNeedsPin(false); onCitySelected?.(selected.city)
  }

  async function find() {
    if (pending.current || query.trim().length < 3) return
    autocompleteSession.current = null
    const controller = new AbortController(); pending.current = controller
    setBusy(true); setError(''); setSuggestions([]); setGoogleOptions([])
    try {
      const cityValue = city || (root.current?.closest('form')?.elements.namedItem(`${kind}_city`) as HTMLSelectElement | null)?.value || ''
      if (!cityValue) throw new Error(`Choose the ${kind} city first.`)
      if (!providerOnly) {
        try {
          const local = await searchSharedDeliveryPlaces(supabase, query, cityValue, undefined, controller.signal)
          if (local.length) {
            if (!controller.signal.aborted) { setSuggestions(local); setOfferProvider(true) }
            return
          }
        } catch { /* Continue with the configured provider. */ }
      }
      controller.signal.throwIfAborted()
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
    autocompleteSession.current = null
    const controller = new AbortController(); pending.current = controller
    setBusy(true); setError('')
    try {
      const device = await requestAddressPosition({ signal: controller.signal })
      let local: AddressSuggestion[] = []
      if (device.accuracyMetres <= 15) {
        try {
          const nearby = await searchSharedDeliveryPlaces(supabase, '', city, device, controller.signal)
          local = nearby.filter((item) => item.distanceMetres !== null && item.distanceMetres <= 15)
        } catch { /* Continue with reverse geocoding if saved places are unavailable. */ }
      }
      controller.signal.throwIfAborted()
      if (local.length) {
        setNearbyPhonePoint(device); setSuggestions(local); setGoogleOptions([])
        setFix(null); setPoint(null); setQuery(''); setCustomerQuery(''); setAddress(''); setSlot(''); setNote(''); setError(''); setNeedsPin(false)
        setOfferProvider(query.trim().length >= 3); setSearching(false)
        return
      }
      const result = await identifyCurrentLocation(supabase, device, controller.signal)
      if (!controller.signal.aborted) {
        setQuery(result.label); setAddress(result.label); setFix(device); setPoint(device)
        setPinVersion((value) => value + 1); setSuggestions([]); setGoogleOptions([]); setOfferProvider(false); setProviderOnly(false); setUserMovedPin(false); setNearbyPhonePoint(null)
        const areaOnly = result.landmarkDistanceMetres === null && result.matchedAddress?.specificity === 'area'
        setNote(areaOnly
          ? `Phone accuracy ±${Math.round(device.accuracyMetres)} m. The map found only an area, not your building or street. Add the exact address or search a nearby place before confirming.`
          : `${result.landmarkDistanceMetres === null ? 'Mapped address' : `Named place ${result.landmarkDistanceMetres} m away`} · phone accuracy ±${Math.round(device.accuracyMetres)} m. Confirm the point.`)
        setNeedsPin(device.accuracyMetres > 100)
      }
    } catch (cause) { if (!controller.signal.aborted) setError(cause instanceof Error ? cause.message : 'Could not get your location.') }
    finally { if (pending.current === controller) pending.current = null; if (!controller.signal.aborted) setBusy(false) }
  }

  async function choosePhonePointInstead() {
    if (!nearbyPhonePoint || pending.current) return
    const controller = new AbortController(); pending.current = controller
    setBusy(true); setError('')
    try {
      const result = await identifyCurrentLocation(supabase, nearbyPhonePoint, controller.signal)
      controller.signal.throwIfAborted()
      setQuery(result.label); setAddress(result.label); setFix(nearbyPhonePoint); setPoint(nearbyPhonePoint)
      setPinVersion((value) => value + 1); setSuggestions([]); setGoogleOptions([]); setOfferProvider(false); setProviderOnly(false); setUserMovedPin(false)
      setNeedsPin(nearbyPhonePoint.accuracyMetres > 100)
      setNote(`Phone accuracy ±${Math.round(nearbyPhonePoint.accuracyMetres)} m. Confirm the point.`)
      setNearbyPhonePoint(null)
    } catch (cause) { if (!controller.signal.aborted) setError(cause instanceof Error ? cause.message : 'Could not identify your location.') }
    finally { if (pending.current === controller) pending.current = null; if (!controller.signal.aborted) setBusy(false) }
  }

  return <div ref={root} className={`field unified-location-picker ${kind}-location`}>
    {saved.length > 0 && <label className="field"><span>My {kind === 'pickup' ? 'pickup' : 'delivery'} addresses</span><select value={slot} onChange={(event) => chooseSaved(event.target.value)}><option value="">Use a new place</option>{saved.map((item) => <option key={item.slot} value={item.slot}>{item.label} — {item.address}</option>)}</select></label>}
    <label className="field"><span>{kind === 'pickup' ? 'Pickup place' : 'Drop-off place'}</span>
      <input className="location-single-search" type="search" autoComplete="off" aria-label={`${kind === 'pickup' ? 'Pickup' : 'Drop-off'} place search`} placeholder={`Search the closest known place to you in ${city || 'the selected city'}`} value={query} required onChange={(event) => { pending.current?.abort(); pending.current = null; setBusy(false); setSearching(event.target.value.trim().length >= 3); setSuggestions([]); setGoogleOptions([]); setQuery(event.target.value); setCustomerQuery(event.target.value); setAddress(event.target.value); setFix(null); setPoint(null); setNote(''); setSlot(''); setError(''); setNeedsPin(false); setProviderOnly(false); setOfferProvider(false); setUserMovedPin(false); setNearbyPhonePoint(null) }} />
    </label>
    {searching && <small role="status" className="address-search-status"><span className="address-search-spinner" aria-hidden="true" />Searching places...</small>}
    {suggestions.length > 0 && <div className="address-suggestions" role="group" aria-label={`${kind} place suggestions`}>{suggestions.map((item, index) => <button type="button" key={`${item.latitude}-${item.longitude}-${index}`} onClick={() => chooseResult(item)}><strong>{item.address}</strong><small>{item.city}, {item.state}{item.distanceMetres === null ? '' : ` · ${Math.round(item.distanceMetres)} m from your phone`}</small></button>)}</div>}
    {googleOptions.length > 0 && <div className="address-suggestions" role="group" aria-label={`${kind} place suggestions`}>{googleOptions.map((item) => <button type="button" key={item.placeId} disabled={busy} onClick={() => void chooseGoogleOption(item)}><strong>{item.address}</strong><small>{item.detail}</small></button>)}<small className="google-maps-attribution" translate="no">Google Maps</small></div>}
    {nearbyPhonePoint && <button type="button" className="text-button" disabled={busy} onClick={() => void choosePhonePointInstead()}>Use my phone point instead</button>}
    {offerProvider && !fix && <button type="button" className="text-button" onClick={() => { setProviderOnly(true); setOfferProvider(false); setSuggestions([]); setNearbyPhonePoint(null); setError(''); setSearching(true) }}>Search more places</button>}
    <div className="field-row"><button type="button" className="secondary-button" disabled={busy || query.trim().length < 3} onClick={() => void find()}>{busy ? 'Finding location...' : 'Find location'}</button><button type="button" className="text-button" disabled={busy} onClick={() => void findCurrentPosition()}>I'm here — use GPS</button></div>
    {error && <small role="alert">{error}</small>}
    {fix && point && <><small role="status">{note || 'Confirm this location.'}</small>
      <PinCorrection key={pinVersion} supabase={supabase} initial={point} compactMap hideSearch requireMove={needsPin} onChoose={(evidence, _address, movedPin) => { setFix(evidence); setPoint(evidence); setUserMovedPin(!!movedPin); setNeedsPin(false); setNote('Pin chosen by you. Confirm this point.') }} />
      {!needsPin && <label className="recipient-location-confirm"><input type="checkbox" name={`${kind}_location_confirmed`} value="yes" required />This is the {kind} location.</label>}
      {slot && kind === 'pickup' && <input type="hidden" name="pickup_saved_slot" value={slot} />}
      <input type="hidden" name={`${kind}_latitude`} value={fix.latitude} /><input type="hidden" name={`${kind}_longitude`} value={fix.longitude} />
      <input type="hidden" name={`${kind}_accuracy_metres`} value={fix.accuracyMetres ?? ''} /><input type="hidden" name={`${kind}_location_source`} value={fix.source} />
      <input type="hidden" name={`${kind}_captured_at`} value={new Date(fix.capturedAt).toISOString()} />
    </>}
    <input type="hidden" name={`${kind}_address`} value={address} /><input type="hidden" name={`${kind}_community`} value="" />
    <input type="hidden" name={`${kind}_customer_query`} value={customerQuery.trim()} /><input type="hidden" name={`${kind}_user_moved_pin`} value={userMovedPin ? 'yes' : 'no'} />
  </div>
}
