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
  const [query, setQuery] = useState('')
  const [suggestions, setSuggestions] = useState<AddressSuggestion[]>([])
  const [pinOpen, setPinOpen] = useState(false)
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
    const clear = () => { pending.current?.abort(); pending.current = null; setFix(null); setMatched(''); setBusy(false); setSuggestions([]); setPinOpen(false); setNeedsPin(false) }
    const changed = (event: Event) => {
      if (['pickup_address', 'pickup_city', 'service_id'].includes((event.target as HTMLInputElement).name)) {
        clear(); setSlot(''); setQuery((event.target as HTMLInputElement).name === 'pickup_address' ? (event.target as HTMLInputElement).value.trim() : '')
      }
    }
    form?.addEventListener('change', changed); form?.addEventListener('input', changed); form?.addEventListener('reset', clear)
    return () => { pending.current?.abort(); form?.removeEventListener('change', changed); form?.removeEventListener('input', changed); form?.removeEventListener('reset', clear) }
  }, [])
  useEffect(() => {
    if (query.length < 5) return
    const controller = new AbortController()
    const timer = window.setTimeout(() => {
      const city = (container.current?.closest('form')?.elements.namedItem('pickup_city') as HTMLSelectElement | null)?.value ?? ''
      void suggestAddresses(supabase, `${query}${city ? `, ${city}` : ''}`, controller.signal)
        .then((results) => { if (!controller.signal.aborted) setSuggestions(results.filter((result) => result.specificity !== 'area' && (!city || result.city.toLowerCase() === city.toLowerCase()))) })
        .catch(() => { if (!controller.signal.aborted) setSuggestions([]) })
    }, 700)
    return () => { window.clearTimeout(timer); controller.abort() }
  }, [query, supabase])
  function chooseSuggestion(result: AddressSuggestion) {
    const input = container.current?.closest('form')?.elements.namedItem('pickup_address')
    if (input instanceof HTMLInputElement) input.value = result.address
    if (result.city) onCitySelected(result.city)
    setFix(result.evidence); setMatched(`${result.address}, ${result.city}`); setNeedsPin(false)
    setSuggestions([]); setQuery(''); setSlot(''); setError('')
  }
  function choose(value: string) {
    pending.current?.abort(); pending.current = null; setBusy(false); setFix(null); setError(''); setSlot(value); setMatched(''); setSuggestions([]); setQuery(''); setNeedsPin(false)
    const item = saved.find((address) => String(address.slot) === value)
    const input = container.current?.closest('form')?.elements.namedItem('pickup_address')
    if (!item || !(input instanceof HTMLInputElement)) return
    input.value = item.address; onCitySelected(item.city)
    if (item.latitude != null && item.longitude != null && item.location_source) {
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
        if (!controller.signal.aborted) { setFix(result); setMatched('Current phone location') }
      } else {
        const form = container.current!.closest('form')!
        const values = new FormData(form)
        const address = String(values.get('pickup_address') ?? '').trim()
        const city = String(values.get('pickup_city') ?? '').trim()
        if (!address || !city) throw new Error('Enter the pickup address and choose its city first.')
        const result = await searchAddress(supabase, `${address}, ${city}, ${values.get('pickup_state') || ''}, Nigeria`, controller.signal)
        if (result.city && result.city.toLowerCase() !== city.toLowerCase()) throw new Error('The mapped address is in another city. Check the pickup city and try again.')
        const broad = result.specificity === 'area' || (result.confidence !== null && result.confidence < 0.7)
        if (!controller.signal.aborted) { setFix(result.evidence); setMatched(broad ? 'Only a broad area was found. Adjust its pin to confirm pickup.' : `${result.address}, ${result.city}, ${result.state}`); setNeedsPin(broad) }
      }
    } catch (cause) { if (!controller.signal.aborted) setError(cause instanceof Error ? cause.message : 'Location unavailable') }
    finally { if (pending.current === controller) { pending.current = null; if (!controller.signal.aborted) setBusy(false) } }
  }
  return <div ref={container} className="field pickup-location">
    {saved.length > 0 && <label className="field"><span>My pickup addresses</span><select value={slot} onChange={(event) => choose(event.target.value)}>
      <option value="">Use a new address</option>{saved.map((address) => <option key={address.slot} value={address.slot}>{address.label} — {address.address}</option>)}
    </select></label>}
    {suggestions.length > 0 && <div className="address-suggestions" role="group" aria-label="Pickup address suggestions">{suggestions.map((result, index) => <button type="button" key={`${result.latitude}-${result.longitude}-${index}`} onClick={() => chooseSuggestion(result)}><strong>{result.address}</strong><small>{result.city}, {result.state} · {result.specificity} match</small></button>)}</div>}
    <div className="field-row"><button type="button" className="secondary-button" disabled={busy} onClick={() => void locate(false)}>{busy ? 'Finding pickup…' : 'Find pickup address'}</button>
      <button type="button" className="text-button" disabled={busy} onClick={() => void locate(true)}>I’m here — use GPS</button></div>
    {error && <small role="alert">{error}</small>}
    {fix && <>
      {slot && <input type="hidden" name="pickup_saved_slot" value={slot} />}
      <small role="status">{matched}{fix.source === 'search' ? ' · approximate address match' : fix.source === 'saved' ? ' · saved location' : ` · GPS ±${Math.round(fix.accuracyMetres ?? 0)} m`}</small>
      <button type="button" className="text-button" onClick={() => setPinOpen(true)}>Adjust pin</button>
      {!needsPin && <label key={`${fix.latitude}:${fix.longitude}:${fix.capturedAt}`}><input type="checkbox" name="pickup_location_confirmed" value="yes" required />This is the pickup location.</label>}
      <input type="hidden" name="pickup_latitude" value={fix.latitude} />
      <input type="hidden" name="pickup_longitude" value={fix.longitude} />
      <input type="hidden" name="pickup_accuracy_metres" value={fix.accuracyMetres ?? ''} />
      <input type="hidden" name="pickup_location_source" value={fix.source} />
      <input type="hidden" name="pickup_captured_at" value={new Date(fix.capturedAt).toISOString()} />
    </>}
    {pinOpen && fix && <PinCorrection supabase={supabase} initial={fix} requireMove={needsPin} onClose={() => setPinOpen(false)} onChoose={(evidence, address) => { setFix(evidence); setMatched(address?.address ? `${address.address}, ${address.city}` : 'Pin selected'); setNeedsPin(false); setPinOpen(false) }} />}
  </div>
}
