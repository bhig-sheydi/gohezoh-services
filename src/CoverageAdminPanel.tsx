import { useCallback, useEffect, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'

type Location = { id: string; name: string; state: string; is_enabled: boolean }
type Corridor = { id: string; origin_id: string; destination_id: string; service_code: string; is_enabled: boolean }
type Partner = { id: string; partner_name: string }
type Eligibility = { partner_id: string; corridor_id: string; is_enabled: boolean }

export default function CoverageAdminPanel({ supabase, onError, onNotice }: { supabase: SupabaseClient; onError: (message: string) => void; onNotice: (message: string) => void }) {
  const [locations, setLocations] = useState<Location[]>([])
  const [corridors, setCorridors] = useState<Corridor[]>([])
  const [partners, setPartners] = useState<Partner[]>([])
  const [eligibility, setEligibility] = useState<Eligibility[]>([])
  const [busy, setBusy] = useState(false)
  const load = useCallback(async () => {
    const [locationResult, corridorResult, partnerResult, eligibilityResult] = await Promise.all([
      supabase.from('coverage_locations').select('id, name, state, is_enabled').order('name'),
      supabase.from('coverage_corridors').select('id, origin_id, destination_id, service_code, is_enabled').order('created_at', { ascending: false }),
      supabase.from('logistics_partners').select('id, partner_name').eq('status', 'active').order('partner_name'),
      supabase.from('partner_corridor_coverage').select('partner_id, corridor_id, is_enabled'),
    ])
    if (locationResult.error || corridorResult.error || partnerResult.error || eligibilityResult.error) onError((locationResult.error ?? corridorResult.error ?? partnerResult.error ?? eligibilityResult.error)?.message ?? 'Could not load coverage.')
    else { setLocations((locationResult.data ?? []) as Location[]); setCorridors((corridorResult.data ?? []) as Corridor[]); setPartners((partnerResult.data ?? []) as Partner[]); setEligibility((eligibilityResult.data ?? []) as Eligibility[]) }
  }, [supabase, onError])
  useEffect(() => { const timer = window.setTimeout(() => { void load() }, 0); return () => clearTimeout(timer) }, [load])
  async function addLocation(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); const formElement = event.currentTarget; const form = new FormData(formElement); setBusy(true)
    const { error } = await supabase.rpc('configure_coverage_location', { p_name: String(form.get('name')).trim(), p_state: String(form.get('state')).trim(), p_enabled: true, p_reason: String(form.get('reason')).trim() })
    if (error) onError(error.message); else { onNotice('Coverage location saved.'); formElement.reset(); await load() }
    setBusy(false)
  }
  async function addCorridor(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); const formElement = event.currentTarget; const form = new FormData(formElement); setBusy(true)
    const { error } = await supabase.rpc('configure_coverage_corridor', { p_origin: String(form.get('origin')), p_destination: String(form.get('destination')), p_service_code: String(form.get('service_code')), p_enabled: true, p_reason: String(form.get('reason')).trim() })
    if (error) onError(error.message); else { onNotice('Coverage corridor saved.'); formElement.reset(); await load() }
    setBusy(false)
  }
  async function toggleCorridor(corridor: Corridor) {
    const reason = window.prompt(`Reason to ${corridor.is_enabled ? 'disable' : 'enable'} this corridor:`)?.trim()
    if (!reason) return
    setBusy(true)
    const { error } = await supabase.rpc('set_coverage_corridor', { p_corridor_id: corridor.id, p_enabled: !corridor.is_enabled, p_reason: reason })
    if (error) onError(error.message); else { onNotice('Corridor status updated. Existing jobs require separate Operations review.'); await load() }
    setBusy(false)
  }
  async function toggleLocation(location: Location) {
    const reason = window.prompt(`Reason to ${location.is_enabled ? 'disable' : 'enable'} ${location.name}:`)?.trim()
    if (!reason) return
    setBusy(true)
    const { error } = await supabase.rpc('configure_coverage_location', { p_name: location.name, p_state: location.state, p_enabled: !location.is_enabled, p_reason: reason })
    if (error) onError(error.message); else { onNotice('Location status updated.'); await load() }
    setBusy(false)
  }
  async function setPartnerCoverage(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); const formElement = event.currentTarget; const form = new FormData(formElement); setBusy(true)
    const { error } = await supabase.rpc('set_partner_corridor_coverage', { p_partner_id: String(form.get('partner_id')), p_corridor_id: String(form.get('corridor_id')), p_enabled: String(form.get('enabled')) === 'true' })
    if (error) onError(error.message); else { onNotice('Partner route eligibility updated.'); await load() }
    setBusy(false)
  }
  const label = (id: string) => locations.find((location) => location.id === id)?.name ?? 'Unknown location'
  return <section className="history-panel"><div className="history-heading"><div><p className="eyebrow">SERVICE COVERAGE</p><h2>Locations, corridors and partner routes</h2></div><button className="secondary-button" onClick={() => void load()}>Refresh</button></div><p className="form-footnote">Only enabled locations and exact corridors appear in customer requests. Disabling a route does not cancel an existing accepted job.</p><h3>Locations</h3><div className="request-list">{locations.map((location) => <div className="request-item" key={location.id}><strong>{location.name}, {location.state}</strong><span> ? {location.is_enabled ? 'Enabled' : 'Disabled'}</span><button className="secondary-button" disabled={busy} onClick={() => void toggleLocation(location)}>{location.is_enabled ? 'Disable' : 'Enable'}</button></div>)}</div><div className="dashboard-grid"><form className="form-grid form-card" onSubmit={(event) => void addLocation(event)}><h3>Add or update location</h3><label className="field"><span>City</span><input name="name" required /></label><label className="field"><span>State</span><input name="state" required /></label><label className="field"><span>Reason</span><input name="reason" required /></label><button className="secondary-button" disabled={busy}>Save location</button></form><form className="form-grid form-card" onSubmit={(event) => void addCorridor(event)}><h3>Enable a corridor</h3><label className="field"><span>Origin</span><select name="origin" required defaultValue=""><option value="">Choose origin</option>{locations.filter((row) => row.is_enabled).map((row) => <option key={row.id} value={row.name}>{row.name}</option>)}</select></label><label className="field"><span>Destination</span><select name="destination" required defaultValue=""><option value="">Choose destination</option>{locations.filter((row) => row.is_enabled).map((row) => <option key={row.id} value={row.name}>{row.name}</option>)}</select></label><label className="field"><span>Service</span><select name="service_code"><option value="SRV-0001">Local delivery</option><option value="SRV-0002">Interstate delivery</option></select></label><label className="field"><span>Reason</span><input name="reason" required /></label><button className="secondary-button" disabled={busy}>Save corridor</button></form></div><h3>Configured corridors</h3>{corridors.length === 0 ? <p className="notification-empty">No corridors configured.</p> : <div className="request-list">{corridors.map((row) => <div className="request-item" key={row.id}><div className="request-item-top"><strong>{label(row.origin_id)} to {label(row.destination_id)}</strong><span>{row.is_enabled ? 'Enabled' : 'Disabled'}</span></div><small>{row.service_code === 'SRV-0001' ? 'Local' : 'Interstate'} delivery</small><button className="secondary-button" disabled={busy} onClick={() => void toggleCorridor(row)}>{row.is_enabled ? 'Disable' : 'Enable'}</button></div>)}</div>}<form className="form-grid form-card" onSubmit={(event) => void setPartnerCoverage(event)}><h3>Partner eligibility</h3><label className="field"><span>Partner</span><select name="partner_id" required defaultValue=""><option value="">Choose approved partner</option>{partners.map((row) => <option value={row.id} key={row.id}>{row.partner_name}</option>)}</select></label><label className="field"><span>Corridor</span><select name="corridor_id" required defaultValue=""><option value="">Choose corridor</option>{corridors.filter((row) => row.is_enabled).map((row) => <option value={row.id} key={row.id}>{label(row.origin_id)} to {label(row.destination_id)} · {row.service_code === 'SRV-0001' ? 'Local' : 'Interstate'}</option>)}</select></label><label className="field"><span>Access</span><select name="enabled"><option value="true">Eligible</option><option value="false">Remove eligibility</option></select></label><button className="secondary-button" disabled={busy}>Update partner coverage</button></form><p className="form-footnote">{eligibility.filter((row) => row.is_enabled).length} active partner-route assignments.</p></section>
}
