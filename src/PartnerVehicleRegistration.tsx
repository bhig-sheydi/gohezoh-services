import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import './partner-vehicles.css'
import DocumentPreview, { type PreviewDocument } from './DocumentPreview'

const vehicleTypes = ['motorcycle', 'tricycle', 'car', 'van', 'bus', 'truck'] as const
const extensions: Record<string, string> = { 'application/pdf': 'pdf', 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' }
type Vehicle = { id: string; vehicle_type: string; registration_number: string; registered_company_name: string; driver_full_name: string; driver_nin: string; opening_time: string; closing_time: string; vehicle_document_path: string; licence_document_path: string }
type Props = { supabase: SupabaseClient; applicationId: string; userId?: string; companyName?: string | null; readOnly?: boolean; onError: (message: string) => void; onNotice?: (message: string) => void; onCountChange?: (count: number) => void; onBusyChange?: (busy: boolean) => void; onDraftChange?: (dirty: boolean) => void }

export default function PartnerVehicleRegistration({ supabase, applicationId, userId, companyName, readOnly = false, onError, onNotice, onCountChange, onBusyChange, onDraftChange }: Props) {
  const [vehicles, setVehicles] = useState<Vehicle[]>([])
  const [busy, setBusy] = useState(false)
  const [loading, setLoading] = useState(true)
  const [failed, setFailed] = useState(false)
  const [adding, setAdding] = useState(false)
  const [preview, setPreview] = useState<PreviewDocument | null>(null)
  const formRef = useRef<HTMLFormElement>(null)
  const submitting = useRef(false)
  const load = useCallback(async () => {
    setLoading(true)
    try {
      const { data, error } = await supabase.from('partner_application_vehicles').select('id,vehicle_type,registration_number,registered_company_name,driver_full_name,driver_nin,opening_time,closing_time,vehicle_document_path,licence_document_path').eq('application_id', applicationId).order('created_at')
      if (error) throw error
      setVehicles((data ?? []) as Vehicle[]); setFailed(false); onCountChange?.((data ?? []).length)
    } catch { setFailed(true); onCountChange?.(0); onError('Could not load vehicle registrations. Refresh to try again.') }
    finally { setLoading(false) }
  }, [supabase, applicationId, onError, onCountChange])
  useEffect(() => { const timer = window.setTimeout(() => { void load() }, 0); return () => window.clearTimeout(timer) }, [load])

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (submitting.current || !userId) return
    const form = event.currentTarget
    const values = new FormData(form)
    const vehicleFile = (form.elements.namedItem('vehicle_papers') as HTMLInputElement).files?.[0]
    const licenceFile = (form.elements.namedItem('licence') as HTMLInputElement).files?.[0]
    if ([vehicleFile, licenceFile].some((file) => !file || !file.size || file.size > 5242880 || !extensions[file.type])) {
      onError('Choose vehicle papers and a driver licence as PDF or images, each under 5 MB.'); return
    }
    const text = (name: string) => String(values.get(name) ?? '').trim()
    if (!/^\d{11}$/.test(text('driver_nin'))) { onError('Enter the driver\'s 11-digit NIN.'); return }
    if (text('opening_time') === text('closing_time')) { onError('Choose different opening and closing times.'); return }
    submitting.current = true; setBusy(true); onBusyChange?.(true); onError('')
    const bucket = supabase.storage.from('partner-vehicles')
    const paths: string[] = []
    let saved = false
    try {
      for (const file of [vehicleFile!, licenceFile!]) {
        const path = `${userId}/${applicationId}/${crypto.randomUUID()}.${extensions[file.type]}`
        const { error } = await bucket.upload(path, file, { contentType: file.type, upsert: false })
        if (error) throw error
        paths.push(path)
      }
      const { error } = await supabase.rpc('register_partner_vehicle', {
        p_application_id: applicationId, p_vehicle_type: text('vehicle_type'), p_registration_number: text('registration_number'),
        p_registered_company_name: text('registered_company_name'), p_vehicle_document_path: paths[0], p_driver_full_name: text('driver_full_name'),
        p_driver_nin: text('driver_nin'), p_licence_document_path: paths[1], p_opening_time: text('opening_time'), p_closing_time: text('closing_time'),
      })
      if (error) throw error
      saved = true; form.reset(); setAdding(false); onDraftChange?.(false); onNotice?.('Vehicle submitted for Super Admin review.'); await load()
    } catch (error) {
      if (!saved && paths.length) await bucket.remove(paths).catch(() => undefined)
      onError(error && typeof error === 'object' && 'message' in error ? String(error.message) : 'Vehicle registration failed. Try again.')
    } finally { submitting.current = false; setBusy(false); onBusyChange?.(false) }
  }

  async function remove(vehicle: Vehicle) {
    if (submitting.current) return
    submitting.current = true; setBusy(true); onBusyChange?.(true)
    try {
      const { error } = await supabase.rpc('remove_pending_partner_vehicle', { p_vehicle_id: vehicle.id })
      if (error) throw error
      await supabase.storage.from('partner-vehicles').remove([vehicle.vehicle_document_path, vehicle.licence_document_path])
      await load()
    } catch { onError('Could not remove the vehicle. Refresh before trying again.') }
    finally { submitting.current = false; setBusy(false); onBusyChange?.(false) }
  }

  function view(path: string) {
    setPreview({ bucket: 'partner-vehicles', path, title: path === vehicles.find((vehicle) => vehicle.vehicle_document_path === path)?.vehicle_document_path ? 'Vehicle papers' : 'Driver licence' })
  }

  return <section className="partner-vehicle-registration form-grid" aria-label="Company vehicle registration">
    {preview && <DocumentPreview key={preview.path} supabase={supabase} document={preview} onClose={() => setPreview(null)} />}
    <h3>{readOnly ? 'Company vehicles' : `${vehicles.length} registered`}</h3>
    {loading ? <p>Loading vehicles...</p> : failed ? <button className="secondary-button" type="button" onClick={() => void load()}>Retry vehicles</button> : vehicles.length === 0 ? <p>No vehicles submitted yet.</p> : <ul className="partner-vehicle-list">{vehicles.map((vehicle) => <li key={vehicle.id}>
      <strong>{vehicle.registration_number} - {vehicle.vehicle_type}</strong>
      <p>{vehicle.registered_company_name}</p><p>{vehicle.driver_full_name}</p>
      <details><summary>Driver NIN</summary><span>{vehicle.driver_nin}</span></details>
      <p>{vehicle.opening_time.slice(0, 5)} to {vehicle.closing_time.slice(0, 5)}{vehicle.closing_time < vehicle.opening_time ? ' (next day)' : ''} WAT</p>
      <div className="parcel-pal-actions"><button className="secondary-button" type="button" onClick={() => void view(vehicle.vehicle_document_path)}>Vehicle papers</button><button className="secondary-button" type="button" onClick={() => void view(vehicle.licence_document_path)}>Driver licence</button>{!readOnly && <button className="text-button" disabled={busy} type="button" onClick={() => void remove(vehicle)}>Remove</button>}</div>
    </li>)}</ul>}
    {!readOnly && vehicles.length > 0 && !adding && <button className="secondary-button" type="button" disabled={busy || loading || failed} onClick={() => { setAdding(true); window.requestAnimationFrame(() => formRef.current?.querySelector<HTMLSelectElement>('select')?.focus()) }}>Add another vehicle</button>}
    {!readOnly && <form ref={formRef} className="form-grid" hidden={vehicles.length > 0 && !adding} onChange={() => onDraftChange?.(true)} onSubmit={(event) => void submit(event)}>
      <p className="section-intro">Company-owned vehicles only. Documents: PDF or image, up to 5 MB each.</p>
      <fieldset className="delivery-address-fields partner-vehicle-fields" disabled={busy || loading || failed}>
        <label className="field"><span>Vehicle type</span><select name="vehicle_type" required><option value="">Choose vehicle</option>{vehicleTypes.map((type) => <option key={type} value={type}>{type.charAt(0).toUpperCase() + type.slice(1)}</option>)}</select></label>
        <label className="field"><span>Registration / plate number</span><input name="registration_number" required minLength={4} maxLength={20} pattern="[A-Za-z0-9 -]{4,20}" /></label>
        <label className="field"><span>Registered company name</span><input name="registered_company_name" required minLength={2} maxLength={200} defaultValue={companyName ?? ''} readOnly={!!companyName?.trim()} /></label>
        <label className="field"><span>Vehicle papers</span><input name="vehicle_papers" type="file" required accept=".pdf,.jpg,.jpeg,.png,.webp" /><small>Registration must show the company name. PDF or image, up to 5 MB.</small></label>
        <label className="field"><span>Driver full name</span><input name="driver_full_name" required minLength={3} maxLength={200} autoComplete="off" /></label>
        <label className="field"><span>Driver NIN</span><input name="driver_nin" required inputMode="numeric" pattern="[0-9]{11}" minLength={11} maxLength={11} autoComplete="off" /></label>
        <label className="field"><span>Driver licence</span><input name="licence" type="file" required accept=".pdf,.jpg,.jpeg,.png,.webp" /><small>Required for all listed motor vehicles. PDF or image, up to 5 MB.</small></label>
        <div className="field-row"><label className="field"><span>Opening time</span><input type="time" name="opening_time" required defaultValue="08:00" /></label><label className="field"><span>Closing time</span><input type="time" name="closing_time" required defaultValue="18:00" /></label></div>
        <small className="partner-field-wide">Hours are WAT. Closing before opening means the next day.</small>
        <label className="location-confirm partner-field-wide"><input type="checkbox" required />The vehicle papers show this company as the registered owner.</label>
        <button className="primary-button" disabled={busy}>{busy ? 'Submitting vehicle...' : 'Submit vehicle'}</button>
      </fieldset>
    </form>}
  </section>
}
