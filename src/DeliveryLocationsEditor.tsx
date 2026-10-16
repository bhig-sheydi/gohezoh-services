import { useEffect, useRef, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { ParcelDestination } from './ParcelPalsPanel'
import { getAddressFromCurrentPosition, suggestAddresses, type AddressSuggestion, type LocationEvidence } from './lib/geoapify-geocoding'
import PinCorrection from './PinCorrection'

type Props = { supabase: SupabaseClient; userId: string; destinations: ParcelDestination[]; onSaved: () => Promise<void>; onClose?: () => void; onError: (message: string) => void; onNotice: (message: string) => void }
const fieldValue = (form: HTMLFormElement, name: string) => (form.elements.namedItem(name) as HTMLInputElement | null)?.value.trim() ?? ''

export default function DeliveryLocationsEditor({ supabase, userId, destinations, onSaved, onClose, onError, onNotice }: Props) {
  const [busy, setBusy] = useState<{ slot: number; kind: 'lookup' | 'save' | 'remove' } | null>(null)
  const [feedback, setFeedback] = useState<{ slot: number; message: string; error: boolean } | null>(null)
  const [suggestion, setSuggestion] = useState<{ slot: number; at: number } | null>(null)
  const [options, setOptions] = useState<{ slot: number; results: AddressSuggestion[] } | null>(null)
  const [pinSlot, setPinSlot] = useState<number | null>(null)
  const [pinInitial, setPinInitial] = useState<LocationEvidence | null>(null)
  const operation = useRef<AbortController | null>(null)
  const forms = useRef(new Map<number, HTMLFormElement>())
  const coordinates = useRef(new Map<number, LocationEvidence>())
  useEffect(() => () => { operation.current?.abort() }, [userId])

  function apply(slot: number, result: AddressSuggestion) {
    const form = forms.current.get(slot)
    if (!form?.isConnected) return
    for (const name of ['address', 'city', 'state'] as const) {
      const input = form.elements.namedItem(name)
      if (input instanceof HTMLInputElement && result[name]) input.value = result[name]
    }
    setSuggestion({ slot, at: result.evidence.capturedAt })
    coordinates.current.set(slot, result.evidence)
    setOptions(null)
    const approximate = result.specificity !== 'building' || (result.evidence.accuracyMetres ?? 0) > 100 || (result.distanceMetres ?? 0) > 100 || (result.confidence !== null && result.confidence < 0.8)
    setFeedback({ slot, message: approximate ? 'Approximate address. Edit any incorrect details.' : 'Address filled. Check before saving.', error: false })
  }
  async function findOptions(slot: number) {
    if (operation.current) return
    const form = forms.current.get(slot)
    if (!form) return
    const address = fieldValue(form, 'address'), city = fieldValue(form, 'city')
    if (address.length < 5 || !city) { setFeedback({ slot, message: 'Enter the street, building or landmark and city first.', error: true }); return }
    const controller = new AbortController(); operation.current = controller
    setBusy({ slot, kind: 'lookup' }); setOptions(null); setFeedback(null)
    try {
      const results = await suggestAddresses(supabase, `${address}, ${city}, Nigeria`, controller.signal)
      if (!controller.signal.aborted) setOptions({ slot, results: results.filter((result) => result.specificity !== 'area') })
    } catch (cause) { if (!controller.signal.aborted) setFeedback({ slot, message: cause instanceof Error ? cause.message : 'Address search failed.', error: true }) }
    finally { if (operation.current === controller) { operation.current = null; setBusy(null) } }
  }
  async function detect(slot: number) {
    if (operation.current) return
    const controller = new AbortController(); operation.current = controller
    setBusy({ slot, kind: 'lookup' }); setFeedback(null)
    try {
      const result = await getAddressFromCurrentPosition(supabase, { signal: controller.signal })
      if (!controller.signal.aborted) apply(slot, result)
    } catch (error) {
      if (!controller.signal.aborted) setFeedback({ slot, message: error instanceof Error ? error.message : 'Location could not be detected. Enter the address manually.', error: true })
    } finally {
      if (operation.current === controller) { operation.current = null; if (!controller.signal.aborted) setBusy(null) }
    }
  }
  async function save(event: FormEvent<HTMLFormElement>, slot: number) {
    event.preventDefault()
    if (operation.current) return
    const form = event.currentTarget
    const point = coordinates.current.get(slot)
    const saved = destinations.find((destination) => destination.slot === slot)
    const unchanged = saved && ['address', 'city', 'state'].every((key) => fieldValue(form, key) === saved[key as 'address' | 'city' | 'state'])
    const payload = { user_id: userId, slot, label: slot === 1 ? 'Work' : slot === 2 ? 'Home' : 'Other', address: fieldValue(form, 'address'), city: fieldValue(form, 'city'), state: fieldValue(form, 'state'), secondary_phone: fieldValue(form, 'secondary_phone') || null,
      latitude: point && (point.accuracyMetres === null || point.accuracyMetres <= 100) ? point.latitude : unchanged ? saved.latitude ?? null : null,
      longitude: point && (point.accuracyMetres === null || point.accuracyMetres <= 100) ? point.longitude : unchanged ? saved.longitude ?? null : null,
      location_source: point && (point.accuracyMetres === null || point.accuracyMetres <= 100) ? point.source : unchanged ? saved.location_source ?? null : null,
      location_accuracy_metres: point && (point.accuracyMetres === null || point.accuracyMetres <= 100) ? point.accuracyMetres : unchanged ? saved.location_accuracy_metres ?? null : null,
    }
    const controller = new AbortController(); operation.current = controller
    setBusy({ slot, kind: 'save' }); onError(''); onNotice('')
    try {
      const { error } = await supabase.from('customer_parcel_destinations').upsert(payload, { onConflict: 'user_id,slot' }).abortSignal(controller.signal)
      if (controller.signal.aborted) return
      if (error) throw new Error(error.message)
      onNotice(`${payload.label} delivery location saved.`)
      setSuggestion(null); setFeedback(null); setOptions(null); setPinSlot(null)
      await onSaved()
    } catch (error) { if (!controller.signal.aborted) onError(error instanceof Error ? error.message : 'Could not save this delivery location.') }
    finally { if (operation.current === controller) { operation.current = null; if (!controller.signal.aborted) setBusy(null) } }
  }
  async function remove(slot: number) {
    if (operation.current) return
    const controller = new AbortController(); operation.current = controller
    setBusy({ slot, kind: 'remove' }); onError(''); onNotice('')
    try {
      const { error } = await supabase.from('customer_parcel_destinations').delete().eq('user_id', userId).eq('slot', slot).abortSignal(controller.signal)
      if (controller.signal.aborted) return
      if (error) throw new Error(error.message)
      const form = forms.current.get(slot)
      if (form) for (const name of ['address', 'city', 'state', 'secondary_phone']) { const input = form.elements.namedItem(name); if (input instanceof HTMLInputElement) input.value = '' }
      setSuggestion(null); setFeedback(null); setOptions(null); setPinSlot(null); coordinates.current.delete(slot)
      onNotice('Delivery location removed.'); await onSaved()
    } catch (error) { if (!controller.signal.aborted) onError(error instanceof Error ? error.message : 'Could not remove this delivery location.') }
    finally { if (operation.current === controller) { operation.current = null; if (!controller.signal.aborted) setBusy(null) } }
  }

  return <section className="parcel-pal-destinations" aria-labelledby="parcel-pal-destinations-heading">
    <div className="history-heading"><h3 id="parcel-pal-destinations-heading" tabIndex={-1}>Delivery addresses</h3><button className="text-button" type="button" onClick={onClose}>Done</button></div>
    <p className="location-consent">At this address? Get address shares your location with Geoapify. You can edit the result.</p>
    <div className="parcel-pal-destination-grid">{[1, 2, 3].map((slot) => {
      const saved = destinations.find((item) => item.slot === slot)
      return <form className="parcel-pal-destination-card" key={slot} ref={(form) => { if (form) forms.current.set(slot, form); else forms.current.delete(slot) }} onChange={(event) => { if (['address','city','state'].includes((event.target as HTMLElement).getAttribute('name') ?? '')) coordinates.current.delete(slot) }} onSubmit={(event) => void save(event, slot)}>
        <strong>{slot === 1 ? 'Work' : slot === 2 ? 'Home' : 'Other'}</strong>
        <input type="hidden" name="slot" value={slot} />
        <fieldset className="delivery-address-fields" disabled={!!busy}>
          <label className="field"><span>Address</span><input name="address" defaultValue={saved?.address ?? ''} required maxLength={500} /></label>
          <div className="field-row"><label className="field"><span>City</span><input name="city" defaultValue={saved?.city ?? ''} required maxLength={100} /></label><label className="field"><span>State</span><input name="state" defaultValue={saved?.state ?? ''} required maxLength={100} /></label></div>
          <label className="field"><span>Second phone (optional)</span><input name="secondary_phone" type="tel" defaultValue={saved?.secondary_phone ?? ''} /></label>
        </fieldset>
        <div className="parcel-pal-actions"><button className="secondary-button" type="button" disabled={!!busy} onClick={() => void detect(slot)}>{busy?.kind === 'lookup' && busy.slot === slot ? 'Getting address...' : 'Get address'}</button><button className="secondary-button" type="button" disabled={!!busy} onClick={() => void findOptions(slot)}>Find options</button></div>
        {options?.slot === slot && <div className="address-suggestions" role="group" aria-label={`${saved?.label ?? 'Delivery'} address suggestions`}>{options.results.map((result, index) => <button type="button" key={`${result.latitude}-${result.longitude}-${index}`} onClick={() => apply(slot, result)}><strong>{result.address}</strong><small>{result.city}, {result.state} · {result.specificity} match</small></button>)}</div>}
        {feedback?.slot === slot && <p className="parcel-pal-location-quality" role={feedback.error ? 'alert' : 'status'}>{feedback.message}</p>}
        {suggestion?.slot === slot && <button className="text-button" type="button" onClick={() => { setPinInitial(coordinates.current.get(slot) ?? null); setPinSlot(slot) }}>Adjust pin</button>}
        {pinSlot === slot && pinInitial && <PinCorrection supabase={supabase} initial={pinInitial} onClose={() => setPinSlot(null)} onChoose={(point, address) => { coordinates.current.set(slot, point); if (address) apply(slot, { ...address, evidence: point }); setPinSlot(null); setSuggestion({ slot, at: point.capturedAt }) }} />}
        {suggestion?.slot === slot && <label className="location-confirm" key={suggestion.at}><input type="checkbox" required />Address is correct.</label>}
        <div className="parcel-pal-actions"><button className="primary-button" disabled={!!busy}>{busy?.slot === slot && busy.kind === 'save' ? 'Saving...' : 'Save location'}</button>{saved && <button className="text-button" type="button" disabled={!!busy} onClick={() => void remove(slot)}>{busy?.slot === slot && busy.kind === 'remove' ? 'Removing...' : 'Remove'}</button>}</div>
        <small className="location-attribution">Address suggestions by <a href="https://www.geoapify.com/" target="_blank" rel="noreferrer">Geoapify</a> and <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noreferrer">OpenStreetMap contributors</a></small>
      </form>
    })}</div>
  </section>
}
