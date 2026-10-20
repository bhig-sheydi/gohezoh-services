import { useEffect, useRef, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { requestAddressPosition } from './lib/proximity'
import { searchAddress, suggestAddresses, type AddressSuggestion, type LocationEvidence } from './lib/geoapify-geocoding'
import type { ParcelDestination } from './ParcelPalsPanel'
import PinCorrection from './PinCorrection'
type PickupFix = Omit<LocationEvidence, 'source'> & { source: LocationEvidence['source'] | 'saved' }

export default function PickupLocation({ supabase, userId, onCitySelected }: {
  supabase: SupabaseClient; userId: string; onCitySelected: (city: string) => void
}) {
  const [fix, setFix] = useState<PickupFix | null>(null)
  const [saved, setSaved] = useState<ParcelDestination[]>([])
  const [slot, setSlot] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [matched, setMatched] = useState('')
  const [communityQuery, setCommunityQuery] = useState('')
  const [communityPlaceId, setCommunityPlaceId] = useState('')
  const [communitySuggestions, setCommunitySuggestions] = useState<AddressSuggestion[]>([])
  const [communityReady, setCommunityReady] = useState(false)
  const [communityStatus, setCommunityStatus] = useState<'idle' | 'loading' | 'empty'>('idle')
  const [mapPoint, setMapPoint] = useState({ latitude: 9.082, longitude: 8.6753 })
  const [mapVersion, setMapVersion] = useState(0)
  const [streetSeed, setStreetSeed] = useState('')
  const streetDraft = useRef('')
  const [needsPin, setNeedsPin] = useState(false)
  const container = useRef<HTMLDivElement>(null)
  const pending = useRef<AbortController | null>(null)
  useEffect(() => {
    let active = true
    void supabase.from('customer_parcel_destinations').select('slot,label,address,city,state,latitude,longitude,location_source,location_accuracy_metres')
      .eq('user_id', userId).order('slot').then(({ data, error: loadError }) => {
        if (active) { setSaved((data ?? []) as ParcelDestination[]); if (loadError) setError(loadError.message) }
      })
    return () => { active = false }
  }, [supabase, userId])
  useEffect(() => {
    const form = container.current?.closest('form')
    const clear = () => { pending.current?.abort(); pending.current = null; setFix(null); setMatched(''); setBusy(false); setCommunitySuggestions([]); setNeedsPin(false); setCommunityReady(false) }
    const changed = (event: Event) => {
      const target = event.target as HTMLInputElement
      if (target.name === 'pickup_address') return
      if (event.type === 'change' && target.name === 'pickup_community') return
      if (event.type === 'input' && ['pickup_city', 'service_id'].includes(target.name)) return
      if (['pickup_community', 'pickup_city', 'service_id'].includes(target.name)) {
        if (target.name === 'pickup_community') target.required = true
        const street = form?.elements.namedItem('pickup_address')
        if (target.name !== 'pickup_community' || street instanceof HTMLInputElement && street.value) setMapVersion((value) => value + 1)
        streetDraft.current = ''; setStreetSeed('')
        clear(); setSlot('')
        setCommunityPlaceId('')
        setCommunityQuery(target.name === 'pickup_community' ? target.value.trim() : '')
        setCommunityStatus(target.name === 'pickup_community' && target.value.trim().length >= 3 ? 'loading' : 'idle')
      }
    }
    const reset = () => { clear(); setCommunityStatus('idle'); streetDraft.current = ''; setStreetSeed(''); setMapPoint({ latitude: 9.082, longitude: 8.6753 }); setMapVersion((value) => value + 1) }
    form?.addEventListener('change', changed); form?.addEventListener('input', changed); form?.addEventListener('reset', reset)
    return () => { pending.current?.abort(); form?.removeEventListener('change', changed); form?.removeEventListener('input', changed); form?.removeEventListener('reset', reset) }
  }, [])
  useEffect(() => {
    if (communityQuery.length < 3) return
    const controller = new AbortController()
    const timer = window.setTimeout(() => {
      const city = (container.current?.closest('form')?.elements.namedItem('pickup_city') as HTMLSelectElement | null)?.value ?? ''
      void suggestAddresses(supabase, [communityQuery, city, 'Nigeria'].filter(Boolean).join(', '), controller.signal, undefined, 'locality')
        .then((results) => { if (!controller.signal.aborted) { const communities = results.filter((result) => ['suburb', 'district', 'city', 'county'].includes(result.resultType)); setCommunitySuggestions(communities); setCommunityStatus(communities.length ? 'idle' : 'empty') } })
        .catch(() => { if (!controller.signal.aborted) { setCommunitySuggestions([]); setCommunityStatus('empty') } })
    }, 400)
    return () => { window.clearTimeout(timer); controller.abort() }
  }, [communityQuery, supabase])
  function chooseCommunity(result: AddressSuggestion) {
    const input = container.current?.closest('form')?.elements.namedItem('pickup_community')
    if (input instanceof HTMLInputElement) input.value = result.address.split(',')[0].trim()
    if (result.city) onCitySelected(result.city)
    streetDraft.current = ''; setStreetSeed('')
    setMapPoint({ latitude: result.latitude, longitude: result.longitude }); setMapVersion((value) => value + 1)
    setCommunityPlaceId(result.placeId ?? '')
    setCommunitySuggestions([]); setCommunityQuery(''); setCommunityStatus('idle'); setCommunityReady(true); setError('')
  }
  function choose(value: string) {
    pending.current?.abort(); pending.current = null; setBusy(false); setFix(null); setError(''); setSlot(value); setMatched(''); setCommunitySuggestions([]); setCommunityQuery(''); setCommunityPlaceId(''); setNeedsPin(false); setCommunityReady(!!value); setCommunityStatus('idle')
    const community = container.current?.closest('form')?.elements.namedItem('pickup_community')
    if (community instanceof HTMLInputElement) { community.required = !value; if (value) community.value = '' }
    const item = saved.find((address) => String(address.slot) === value)
    streetDraft.current = item?.address ?? ''; setStreetSeed(streetDraft.current); setMapVersion((version) => version + 1)
    if (!item) return
    onCitySelected(item.city)
    if (item.latitude != null && item.longitude != null && item.location_source) {
      setMapPoint({ latitude: item.latitude, longitude: item.longitude })
      setFix({ latitude: item.latitude, longitude: item.longitude, accuracyMetres: null,
        source: 'saved', capturedAt: Date.now() })
      setMatched(`${item.address}, ${item.city}`)
    }
  }
  async function locate(gps: boolean) {
    if (pending.current) return
    setBusy(true); setError(''); setFix(null); setMatched(''); setNeedsPin(false)
    const controller = new AbortController(); pending.current = controller
    try {
      if (gps) {
        const result = await requestAddressPosition({ signal: controller.signal })
        if (result.accuracyMetres > 100) throw new Error('GPS is too imprecise. Find your typed address instead, or try outdoors.')
        if (!controller.signal.aborted) { setMapPoint(result); setStreetSeed(streetDraft.current); setMapVersion((value) => value + 1); setFix(result); setMatched('Current phone location') }
      } else {
        const form = container.current!.closest('form')!
        const values = new FormData(form)
        const address = String(values.get('pickup_address') ?? '').trim()
        const community = String(values.get('pickup_community') ?? '').trim()
        const city = String(values.get('pickup_city') ?? '').trim()
        if (!community || !address || !city) throw new Error('Enter the pickup community and street, then choose its city.')
        const result = await searchAddress(supabase, communityPlaceId ? address : `${address}, ${community}, ${city}, ${values.get('pickup_state') || ''}, Nigeria`, controller.signal, communityPlaceId || undefined)
        if (result.city && result.city.toLowerCase() !== city.toLowerCase()) throw new Error('The mapped address is in another city. Check the pickup city and try again.')
        const broad = result.specificity === 'area' || (result.confidence !== null && result.confidence < 0.7)
        if (!controller.signal.aborted) { setMapPoint(result.evidence); setStreetSeed(streetDraft.current); setMapVersion((value) => value + 1); setFix(result.evidence); setMatched(broad ? 'Only a broad area was found. Adjust its pin to confirm pickup.' : `${result.address}, ${result.city}, ${result.state}`); setNeedsPin(broad) }
      }
    } catch (cause) { if (!controller.signal.aborted) setError(cause instanceof Error ? cause.message : 'Location unavailable') }
    finally { if (pending.current === controller) { pending.current = null; if (!controller.signal.aborted) setBusy(false) } }
  }
  return <div ref={container} className="field pickup-location">
    {saved.length > 0 && <label className="field"><span>My pickup addresses</span><select value={slot} onChange={(event) => choose(event.target.value)}>
      <option value="">Use a new address</option>{saved.map((address) => <option key={address.slot} value={address.slot}>{address.label} — {address.address}</option>)}
    </select></label>}
    {communitySuggestions.length > 0 && <div className="address-suggestions" role="group" aria-label="Pickup community suggestions">{communitySuggestions.map((result, index) => <button type="button" key={`${result.latitude}-${result.longitude}-${index}`} onClick={() => chooseCommunity(result)}><strong>{result.address}</strong><small>{result.city}, {result.state}</small></button>)}</div>}
    {!communityReady && <small className="address-search-hint">Type at least 3 letters above, then tap your community from the suggestions.</small>}
    {communityStatus === 'loading' && <small role="status" className="address-search-status"><span className="address-search-spinner" aria-hidden="true" />Searching communities — please wait for suggestions.</small>}
    {communityStatus === 'empty' && <div className="address-search-fallback"><small>No mapped community found. Check spelling or continue with the typed community.</small><button type="button" className="text-button" onClick={() => { setCommunityReady(true); setCommunityStatus('idle') }}>Use typed community</button></div>}
    {communityReady && <><div className="field-row"><button type="button" className="secondary-button" disabled={busy} onClick={() => void locate(false)}>{busy ? 'Finding pickup…' : 'Find pickup address'}</button>
      <button type="button" className="text-button" disabled={busy} onClick={() => void locate(true)}>I’m here — use GPS</button></div>
    {error && <small role="alert">{error}</small>}
    <PinCorrection key={mapVersion} supabase={supabase} initial={mapPoint} initialStreet={streetSeed} streetInputName="pickup_address" requireMove={needsPin} compactMap autoSelectSuggestion
      onStreetChange={(street) => { streetDraft.current = street; setFix(null); setMatched(''); setSlot('') }}
      onPointChange={() => { setFix(null); setMatched('') }}
      onChoose={(evidence, address) => { setMapPoint(evidence); setFix(evidence); setMatched(address?.address ? `${address.address}, ${address.city} · selected` : 'Pin selected'); setNeedsPin(false) }} /></>}
    {fix && <>
      {slot && <input type="hidden" name="pickup_saved_slot" value={slot} />}
      <small role="status">{matched}{fix.source === 'search' ? ' · approximate address match' : fix.source === 'saved' ? ' · saved location' : ` · GPS ±${Math.round(fix.accuracyMetres ?? 0)} m`}</small>
      {!needsPin && <label key={`${fix.latitude}:${fix.longitude}:${fix.capturedAt}`}><input type="checkbox" name="pickup_location_confirmed" value="yes" required />This is the pickup location.</label>}
      <input type="hidden" name="pickup_latitude" value={fix.latitude} />
      <input type="hidden" name="pickup_longitude" value={fix.longitude} />
      <input type="hidden" name="pickup_accuracy_metres" value={fix.accuracyMetres ?? ''} />
      <input type="hidden" name="pickup_location_source" value={fix.source} />
      <input type="hidden" name="pickup_captured_at" value={new Date(fix.capturedAt).toISOString()} />
    </>}
  </div>
}
