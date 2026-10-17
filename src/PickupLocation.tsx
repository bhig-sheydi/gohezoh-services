import { useEffect, useRef, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { requestAddressPosition } from './lib/proximity'
import { suggestAddresses, type AddressSuggestion, type LocationEvidence } from './lib/geoapify-geocoding'
import type { ParcelDestination } from './ParcelPalsPanel'
import PinCorrection from './PinCorrection'
type PickupFix = Omit<LocationEvidence, 'source'> & { source: LocationEvidence['source'] | 'saved' }
const cityCentres: Record<string, { latitude: number; longitude: number }> = {
  'port harcourt': { latitude: 4.8156, longitude: 7.0498 },
  lagos: { latitude: 6.5244, longitude: 3.3792 },
  umuahia: { latitude: 5.5333, longitude: 7.4833 },
}
const nigeriaCentre = { latitude: 9.082, longitude: 8.6753 }

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
  const [communitySuggestions, setCommunitySuggestions] = useState<AddressSuggestion[]>([])
  const [anchor, setAnchor] = useState(nigeriaCentre)
  const [streetSeed, setStreetSeed] = useState('')
  const [pinVersion, setPinVersion] = useState(0)
  const [contextCity, setContextCity] = useState('')
  const [contextCommunity, setContextCommunity] = useState('')
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
    const clear = () => { pending.current?.abort(); pending.current = null; setFix(null); setMatched(''); setBusy(false); setCommunitySuggestions([]); setStreetSeed('') }
    const changed = (event: Event) => {
      const target = event.target as HTMLInputElement
      if (event.type === 'change' && target.name === 'pickup_community') return
      if (event.type === 'input' && ['pickup_city', 'service_id'].includes(target.name)) return
      if (['pickup_community', 'pickup_city', 'service_id'].includes(target.name)) {
        const street = form?.elements.namedItem('pickup_address')
        if (target.name !== 'pickup_community' || street instanceof HTMLInputElement && street.value) setPinVersion((value) => value + 1)
        clear(); setSlot('')
        setCommunityQuery(target.name === 'pickup_community' ? target.value.trim() : '')
        if (target.name === 'pickup_community') setContextCommunity(target.value.trim())
        if (target.name === 'pickup_city') { setContextCity(target.value); setAnchor(cityCentres[target.value.toLowerCase()] ?? nigeriaCentre) }
      }
    }
    const reset = () => { clear(); setAnchor(nigeriaCentre); setCommunityQuery(''); setContextCommunity(''); setContextCity(''); setPinVersion((value) => value + 1) }
    form?.addEventListener('change', changed); form?.addEventListener('input', changed); form?.addEventListener('reset', reset)
    return () => { pending.current?.abort(); form?.removeEventListener('change', changed); form?.removeEventListener('input', changed); form?.removeEventListener('reset', reset) }
  }, [])
  useEffect(() => {
    if (communityQuery.length < 3) return
    const controller = new AbortController()
    const timer = window.setTimeout(() => {
      const city = (container.current?.closest('form')?.elements.namedItem('pickup_city') as HTMLSelectElement | null)?.value ?? ''
      void suggestAddresses(supabase, [communityQuery, city, 'Nigeria'].filter(Boolean).join(', '), controller.signal)
        .then((results) => { if (!controller.signal.aborted) setCommunitySuggestions(results.filter((result) => ['suburb', 'district', 'city', 'county'].includes(result.resultType))) })
        .catch(() => { if (!controller.signal.aborted) setCommunitySuggestions([]) })
    }, 400)
    return () => { window.clearTimeout(timer); controller.abort() }
  }, [communityQuery, supabase])
  function chooseCommunity(result: AddressSuggestion) {
    const input = container.current?.closest('form')?.elements.namedItem('pickup_community')
    if (input instanceof HTMLInputElement) input.value = result.address.split(',')[0].trim()
    if (result.city) onCitySelected(result.city)
    setContextCommunity(result.address.split(',')[0].trim()); setContextCity(result.city ?? '')
    setAnchor({ latitude: result.latitude, longitude: result.longitude })
    setFix(null); setMatched(''); setStreetSeed(''); setPinVersion((value) => value + 1)
    setCommunitySuggestions([]); setCommunityQuery(''); setError('')
  }
  function choose(value: string) {
    pending.current?.abort(); pending.current = null; setBusy(false); setFix(null); setError(''); setSlot(value); setMatched(''); setCommunitySuggestions([]); setCommunityQuery('')
    const item = saved.find((address) => String(address.slot) === value)
    setStreetSeed(item?.address ?? ''); setPinVersion((version) => version + 1)
    if (!item) return
    onCitySelected(item.city)
    setContextCity(item.city)
    const community = container.current?.closest('form')?.elements.namedItem('pickup_community')
    if (community instanceof HTMLInputElement && !community.value) {
      community.value = item.address.split(',').slice(1).join(',').trim()
      setContextCommunity(community.value)
    }
    setAnchor(item.latitude != null && item.longitude != null
      ? { latitude: item.latitude, longitude: item.longitude }
      : cityCentres[item.city.toLowerCase()] ?? nigeriaCentre)
    if (item.latitude != null && item.longitude != null && item.location_source) {
      setFix({ latitude: item.latitude, longitude: item.longitude, accuracyMetres: null,
        source: 'saved', capturedAt: Date.now() })
      setMatched(`${item.address}, ${item.city}`)
    }
  }
  async function locate() {
    if (pending.current) return
    setBusy(true); setError(''); setFix(null); setMatched('')
    const controller = new AbortController(); pending.current = controller
    try {
      const result = await requestAddressPosition({ signal: controller.signal })
      if (result.accuracyMetres > 100) throw new Error('GPS is too imprecise. Try outdoors or choose the pickup point on the map.')
      if (!controller.signal.aborted) { setAnchor(result); setPinVersion((value) => value + 1); setFix(result); setMatched('Current phone location') }
    } catch (cause) { if (!controller.signal.aborted) setError(cause instanceof Error ? cause.message : 'Location unavailable') }
    finally { if (pending.current === controller) { pending.current = null; if (!controller.signal.aborted) setBusy(false) } }
  }
  return <div ref={container} className="field pickup-location">
    {saved.length > 0 && <label className="field"><span>My pickup addresses</span><select value={slot} onChange={(event) => choose(event.target.value)}>
      <option value="">Use a new address</option>{saved.map((address) => <option key={address.slot} value={address.slot}>{address.label} — {address.address}</option>)}
    </select></label>}
    {communitySuggestions.length > 0 && <div className="address-suggestions" role="group" aria-label="Pickup community suggestions">{communitySuggestions.map((result, index) => <button type="button" key={`${result.latitude}-${result.longitude}-${index}`} onClick={() => chooseCommunity(result)}><strong>{result.address}</strong><small>{result.city}, {result.state}</small></button>)}</div>}
    <button type="button" className="text-button" disabled={busy} onClick={() => void locate()}>{busy ? 'Getting your location…' : 'I’m here — use GPS'}</button>
    {error && <small role="alert">{error}</small>}
    <PinCorrection key={pinVersion} supabase={supabase} initial={anchor} initialStreet={streetSeed} streetInputName="pickup_address" mapEnabled={!!contextCity}
      searchContext={[contextCommunity, contextCity, 'Nigeria'].filter(Boolean).join(', ')} expectedCity={contextCity}
      onStreetChange={() => { setFix(null); setMatched(''); setSlot('') }}
      onChoose={(evidence, address) => { setFix(evidence); setMatched(address?.address ? `${address.address}, ${address.city}` : 'Pin selected') }} />
    {fix && <>
      {slot && <input type="hidden" name="pickup_saved_slot" value={slot} />}
      <small role="status">{matched}{fix.source === 'saved' ? ' · saved location' : fix.source === 'browser' || fix.source === 'native' ? ` · GPS ±${Math.round(fix.accuracyMetres ?? 0)} m` : ' · chosen on map'}</small>
      <label key={`${fix.latitude}:${fix.longitude}:${fix.capturedAt}`}><input type="checkbox" name="pickup_location_confirmed" value="yes" required />This is the pickup location.</label>
      <input type="hidden" name="pickup_latitude" value={fix.latitude} />
      <input type="hidden" name="pickup_longitude" value={fix.longitude} />
      <input type="hidden" name="pickup_accuracy_metres" value={fix.accuracyMetres ?? ''} />
      <input type="hidden" name="pickup_location_source" value={fix.source} />
      <input type="hidden" name="pickup_captured_at" value={new Date(fix.capturedAt).toISOString()} />
    </>}
  </div>
}
