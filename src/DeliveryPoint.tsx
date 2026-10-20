import { useEffect, useRef, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { requestAddressPosition } from './lib/proximity'
import { searchAddress, suggestAreas, type AddressSuggestion, type LocationEvidence } from './lib/geoapify-geocoding'
import type { ParcelDestination } from './ParcelPalsPanel'
import PinCorrection from './PinCorrection'

export default function DeliveryPoint({ supabase, destination, onCitySelected }: {
  supabase: SupabaseClient; destination?: ParcelDestination | null; onCitySelected: (city: string) => void
}) {
  const [fix, setFix] = useState<LocationEvidence | null>(() => destination?.latitude != null && destination.longitude != null
    ? { latitude: destination.latitude, longitude: destination.longitude, accuracyMetres: null, capturedAt: Date.now(), source: 'saved' } : null)
  const [point, setPoint] = useState({ latitude: destination?.latitude ?? 9.082, longitude: destination?.longitude ?? 8.6753 })
  const [version, setVersion] = useState(0)
  const [streetSeed, setStreetSeed] = useState(destination?.address ?? '')
  const streetDraft = useRef(destination?.address ?? '')
  const [label, setLabel] = useState(destination?.latitude != null ? `${destination.address}, ${destination.city} · saved pin` : '')
  const [communityQuery, setCommunityQuery] = useState('')
  const [communityPlaceId, setCommunityPlaceId] = useState('')
  const [suggestions, setSuggestions] = useState<AddressSuggestion[]>([])
  const [communityReady, setCommunityReady] = useState(!!destination?.address)
  const [communityStatus, setCommunityStatus] = useState<'idle' | 'loading' | 'empty'>('idle')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const [needsPin, setNeedsPin] = useState(false)
  const element = useRef<HTMLDivElement>(null)
  const pending = useRef<AbortController | null>(null)

  useEffect(() => {
    const form = element.current?.closest('form')
    const changed = (event: Event) => {
      const target = event.target as HTMLInputElement
      if (target.name === 'delivery_address' || event.type === 'change' && target.name === 'delivery_community' ||
        event.type === 'input' && target.name === 'delivery_city') return
      if (!['delivery_community', 'delivery_city'].includes(target.name)) return
      if (target.name === 'delivery_community') target.required = true
      pending.current?.abort(); pending.current = null
      setFix(null); setLabel(''); setBusy(false); setNeedsPin(false); setCommunityPlaceId(''); setError('')
      setSuggestions([]); setCommunityQuery(target.name === 'delivery_community' ? target.value.trim() : '')
      setCommunityStatus(target.name === 'delivery_community' && target.value.trim().length >= 3 ? 'loading' : 'idle')
      setCommunityReady(false)
      const street = form?.elements.namedItem('delivery_address')
      if (target.name !== 'delivery_community' || street instanceof HTMLInputElement && street.value) setVersion((value) => value + 1)
      streetDraft.current = ''; setStreetSeed('')
    }
    const reset = () => {
      pending.current?.abort(); pending.current = null
      setFix(null); setLabel(''); setSuggestions([]); setCommunityQuery(''); setCommunityPlaceId('')
      streetDraft.current = ''; setStreetSeed(''); setPoint({ latitude: 9.082, longitude: 8.6753 }); setVersion((value) => value + 1)
      setBusy(false); setNeedsPin(false); setError(''); setCommunityReady(false); setCommunityStatus('idle')
    }
    form?.addEventListener('input', changed); form?.addEventListener('change', changed); form?.addEventListener('reset', reset)
    return () => { pending.current?.abort(); form?.removeEventListener('input', changed); form?.removeEventListener('change', changed); form?.removeEventListener('reset', reset) }
  }, [])

  useEffect(() => {
    if (communityQuery.length < 3) return
    const controller = new AbortController()
    const timer = window.setTimeout(() => {
      const city = (element.current?.closest('form')?.elements.namedItem('delivery_city') as HTMLSelectElement | null)?.value ?? ''
      void suggestAreas(supabase, communityQuery, city, controller.signal)
        .then((results) => { if (!controller.signal.aborted) { setSuggestions(results); setCommunityStatus(results.length ? 'idle' : 'empty') } })
        .catch(() => { if (!controller.signal.aborted) { setSuggestions([]); setCommunityStatus('empty') } })
    }, 400)
    return () => { window.clearTimeout(timer); controller.abort() }
  }, [communityQuery, supabase])

  function selectCommunity(result: AddressSuggestion) {
    const input = element.current?.closest('form')?.elements.namedItem('delivery_community')
    if (input instanceof HTMLInputElement) input.value = result.address.split(',')[0].trim()
    if (result.city) onCitySelected(result.city)
    streetDraft.current = ''; setStreetSeed('')
    setPoint({ latitude: result.latitude, longitude: result.longitude }); setVersion((value) => value + 1)
    setCommunityPlaceId(result.placeId ?? '')
    setFix(null); setLabel(''); setSuggestions([]); setCommunityQuery(''); setCommunityStatus('idle'); setCommunityReady(true); setError(''); setNeedsPin(false)
  }

  async function find(gps: boolean) {
    if (pending.current) return
    const controller = new AbortController(); pending.current = controller
    setBusy(true); setError(''); setFix(null); setLabel(''); setNeedsPin(false)
    try {
      if (gps) {
        const result = await requestAddressPosition({ signal: controller.signal })
        if (result.accuracyMetres > 100) throw new Error('GPS is too imprecise. Find the typed address instead, or try outdoors.')
        if (!controller.signal.aborted) {
          setPoint(result); setStreetSeed(streetDraft.current); setVersion((value) => value + 1)
          setFix(result); setLabel(`Current phone location · GPS ±${Math.round(result.accuracyMetres)} m`)
        }
      } else {
        const values = new FormData(element.current!.closest('form')!)
        const address = String(values.get('delivery_address') ?? '').trim()
        const community = String(values.get('delivery_community') ?? '').trim()
        const city = String(values.get('delivery_city') ?? '').trim()
        if (!address || !community || !city) throw new Error('Enter the delivery community and street, then choose its city.')
        const result = await searchAddress(supabase, communityPlaceId ? address : `${address}, ${community}, ${city}, ${values.get('delivery_state') || ''}, Nigeria`, controller.signal, communityPlaceId || undefined)
        if (result.city && result.city.toLowerCase() !== city.toLowerCase()) throw new Error('The mapped address is in another city. Check the city and try again.')
        const broad = result.specificity === 'area' || (result.confidence !== null && result.confidence < 0.7)
        if (!controller.signal.aborted) {
          setPoint(result.evidence); setStreetSeed(streetDraft.current); setVersion((value) => value + 1)
          setFix(result.evidence); setLabel(broad ? 'Only a broad area was found. Adjust its pin to confirm delivery.' : `${result.address}, ${result.city} · approximate map match`); setNeedsPin(broad)
        }
      }
    } catch (cause) { if (!controller.signal.aborted) setError(cause instanceof Error ? cause.message : 'Location unavailable') }
    finally { if (pending.current === controller) { pending.current = null; if (!controller.signal.aborted) setBusy(false) } }
  }

  return <div ref={element} className="field route-location-picker delivery-location">
    {suggestions.length > 0 && <div className="address-suggestions" role="group" aria-label="Delivery community suggestions">{suggestions.map((result, index) => <button type="button" key={`${result.latitude}-${result.longitude}-${index}`} onClick={() => selectCommunity(result)}><strong>{result.address}</strong><small>{result.city}, {result.state}</small></button>)}</div>}
    {!communityReady && <small className="address-search-hint">Type at least 3 letters above, then tap your community from the suggestions.</small>}
    {communityStatus === 'loading' && <small role="status" className="address-search-status"><span className="address-search-spinner" aria-hidden="true" />Searching communities — please wait for suggestions.</small>}
    {communityStatus === 'empty' && <div className="address-search-fallback"><small>No mapped community found. Check spelling or continue with the typed community.</small><button type="button" className="text-button" onClick={() => { setCommunityReady(true); setCommunityStatus('idle') }}>Use typed community</button></div>}
    {communityReady && <><div className="field-row"><button type="button" className="secondary-button" disabled={busy} onClick={() => void find(false)}>{busy ? 'Finding delivery…' : 'Find delivery address'}</button><button type="button" className="text-button" disabled={busy} onClick={() => void find(true)}>I’m here — use GPS</button></div>
    {error && <small role="alert">{error}</small>}
    <PinCorrection key={version} supabase={supabase} initial={point} initialStreet={streetSeed} streetInputName="delivery_address" requireMove={needsPin} compactMap autoSelectSuggestion streetSearchRadiusMetres={3000}
      onStreetChange={(street) => { streetDraft.current = street; setFix(null); setLabel('') }}
      onPointChange={() => { setFix(null); setLabel('') }}
      onChoose={(evidence, address) => { setPoint(evidence); setFix(evidence); setLabel(address?.address ? `${address.address}, ${address.city} · approximate mapped point` : 'Pin chosen by you'); setNeedsPin(false) }} /></>}
    {fix && <><small role="status">{label}</small>
      {!needsPin && <label key={`${fix.latitude}:${fix.longitude}:${fix.capturedAt}`}><input type="checkbox" name="delivery_location_confirmed" value="yes" required />This is the delivery location.</label>}
      <input type="hidden" name="delivery_latitude" value={fix.latitude} /><input type="hidden" name="delivery_longitude" value={fix.longitude} />
      <input type="hidden" name="delivery_accuracy_metres" value={fix.accuracyMetres ?? ''} /><input type="hidden" name="delivery_location_source" value={fix.source} />
      <input type="hidden" name="delivery_captured_at" value={new Date(fix.capturedAt).toISOString()} />
    </>}
  </div>
}
