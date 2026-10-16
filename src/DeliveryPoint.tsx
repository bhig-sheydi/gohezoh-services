import { useEffect, useRef, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { requestAddressPosition } from './lib/proximity'
import { searchAddress, suggestAddresses, type AddressSuggestion, type LocationEvidence } from './lib/geoapify-geocoding'
import type { ParcelDestination } from './ParcelPalsPanel'
import PinCorrection from './PinCorrection'

export default function DeliveryPoint({ supabase, destination, onCitySelected }: {
  supabase: SupabaseClient; destination?: ParcelDestination | null; onCitySelected: (city: string) => void
}) {
  const [fix, setFix] = useState<LocationEvidence | null>(() => destination?.latitude != null && destination.longitude != null
    ? { latitude: destination.latitude, longitude: destination.longitude, accuracyMetres: null, capturedAt: Date.now(), source: 'saved' } : null)
  const [label, setLabel] = useState(destination?.latitude != null ? `${destination.address}, ${destination.city} · saved pin` : '')
  const [query, setQuery] = useState('')
  const [suggestions, setSuggestions] = useState<AddressSuggestion[]>([])
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const [pinOpen, setPinOpen] = useState(false)
  const [needsPin, setNeedsPin] = useState(false)
  const element = useRef<HTMLDivElement>(null)
  const pending = useRef<AbortController | null>(null)
  useEffect(() => {
    const form = element.current?.closest('form')
    const changed = (event: Event) => {
      const target = event.target as HTMLInputElement
      if (!['delivery_address', 'delivery_city'].includes(target.name)) return
      pending.current?.abort(); pending.current = null
      setFix(null); setLabel(''); setSuggestions([]); setPinOpen(false); setBusy(false); setNeedsPin(false)
      setQuery(target.name === 'delivery_address' ? target.value.trim() : '')
    }
    const reset = () => { pending.current?.abort(); setFix(null); setLabel(''); setSuggestions([]); setQuery(''); setPinOpen(false); setNeedsPin(false) }
    form?.addEventListener('input', changed); form?.addEventListener('change', changed); form?.addEventListener('reset', reset)
    return () => { pending.current?.abort(); form?.removeEventListener('input', changed); form?.removeEventListener('change', changed); form?.removeEventListener('reset', reset) }
  }, [])
  useEffect(() => {
    if (query.length < 5) return
    const controller = new AbortController()
    const timer = window.setTimeout(() => {
      const city = (element.current?.closest('form')?.elements.namedItem('delivery_city') as HTMLSelectElement | null)?.value ?? ''
      void suggestAddresses(supabase, `${query}${city ? `, ${city}` : ''}`, controller.signal)
        .then((results) => { if (!controller.signal.aborted) setSuggestions(results.filter((result) => result.specificity !== 'area' && (!city || result.city.toLowerCase() === city.toLowerCase()))) })
        .catch(() => { if (!controller.signal.aborted) setSuggestions([]) })
    }, 700)
    return () => { window.clearTimeout(timer); controller.abort() }
  }, [query, supabase])
  function select(result: AddressSuggestion) {
    const input = element.current?.closest('form')?.elements.namedItem('delivery_address')
    if (input instanceof HTMLInputElement) input.value = result.address
    if (result.city) onCitySelected(result.city)
    setFix(result.evidence); setLabel(`${result.address}, ${result.city} · approximate map match`)
    setSuggestions([]); setQuery(''); setError(''); setNeedsPin(false)
  }
  async function find(gps: boolean) {
    if (pending.current) return
    const controller = new AbortController(); pending.current = controller
    setBusy(true); setError(''); setFix(null); setSuggestions([]); setNeedsPin(false)
    try {
      if (gps) {
        const result = await requestAddressPosition({ signal: controller.signal })
        if (result.accuracyMetres > 100) throw new Error('GPS is too imprecise. Try outdoors, search the address, or adjust its pin.')
        if (!controller.signal.aborted) { setFix(result); setLabel(`Current phone location · GPS ±${Math.round(result.accuracyMetres)} m`) }
      } else {
        const form = element.current!.closest('form')!
        const values = new FormData(form)
        const address = String(values.get('delivery_address') ?? '').trim()
        const city = String(values.get('delivery_city') ?? '').trim()
        if (!address || !city) throw new Error('Enter the delivery address and choose its city first.')
        const result = await searchAddress(supabase, `${address}, ${city}, Nigeria`, controller.signal)
        if (result.city && result.city.toLowerCase() !== city.toLowerCase()) throw new Error('The mapped address is in another city. Check the city and try again.')
        const broad = result.specificity === 'area' || (result.confidence !== null && result.confidence < 0.7)
        if (!controller.signal.aborted) { setFix(result.evidence); setLabel(broad ? 'Only a broad area was found. Adjust its pin to confirm delivery.' : `${result.address}, ${result.city} · approximate map match`); setNeedsPin(broad) }
      }
    } catch (cause) { if (!controller.signal.aborted) setError(cause instanceof Error ? cause.message : 'Location unavailable') }
    finally { if (pending.current === controller) { pending.current = null; if (!controller.signal.aborted) setBusy(false) } }
  }
  return <div ref={element} className="field route-location-picker">
    {suggestions.length > 0 && <div className="address-suggestions" role="group" aria-label="Delivery address suggestions">{suggestions.map((result, index) => <button type="button" key={`${result.latitude}-${result.longitude}-${index}`} onClick={() => select(result)}><strong>{result.address}</strong><small>{result.city}, {result.state} · {result.specificity} match</small></button>)}</div>}
    <div className="field-row"><button type="button" className="secondary-button" disabled={busy} onClick={() => void find(false)}>{busy ? 'Finding…' : 'Find delivery address'}</button><button type="button" className="text-button" disabled={busy} onClick={() => void find(true)}>I’m here — use GPS</button></div>
    {error && <small role="alert">{error}</small>}
    {fix && <><small role="status">{label}</small><button type="button" className="text-button" onClick={() => setPinOpen(true)}>Adjust delivery pin</button>
      {!needsPin && <label key={`${fix.latitude}:${fix.longitude}:${fix.capturedAt}`}><input type="checkbox" name="delivery_location_confirmed" value="yes" required />This is the delivery location.</label>}
      <input type="hidden" name="delivery_latitude" value={fix.latitude} /><input type="hidden" name="delivery_longitude" value={fix.longitude} />
      <input type="hidden" name="delivery_accuracy_metres" value={fix.accuracyMetres ?? ''} /><input type="hidden" name="delivery_location_source" value={fix.source} />
      <input type="hidden" name="delivery_captured_at" value={new Date(fix.capturedAt).toISOString()} />
    </>}
    {pinOpen && fix && <PinCorrection supabase={supabase} initial={fix} requireMove={needsPin} onClose={() => setPinOpen(false)} onChoose={(evidence, address) => { setFix(evidence); setLabel(address?.address ? `${address.address}, ${address.city} · pin chosen by you` : 'Pin chosen by you'); setNeedsPin(false); setPinOpen(false) }} />}
  </div>
}
