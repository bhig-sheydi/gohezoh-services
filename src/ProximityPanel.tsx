import { useCallback, useEffect, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { requestPosition, type PositionFix } from './lib/proximity'

type Site = { id: string; name: string; kind: string; job_id: string | null; warehouse_id: string | null; radius_metres: number }
type Result = { status: 'in_range' | 'out_of_range' | 'uncertain'; distance_metres: number; radius_metres: number; accuracy_metres?: number }
type Target = { id: string; label: string }

export default function ProximityPanel({ supabase, canConfigure, jobId, onError, onNotice }: { supabase: SupabaseClient; canConfigure: boolean; jobId?: string; onError: (message: string) => void; onNotice: (message: string) => void }) {
  const [sites, setSites] = useState<Site[]>([])
  const [busy, setBusy] = useState(false)
  const [fix, setFix] = useState<PositionFix | null>(null)
  const [results, setResults] = useState<Record<string, Result>>({})
  const [kind, setKind] = useState<'pickup' | 'delivery' | 'hub'>('pickup')
  const [jobs, setJobs] = useState<Target[]>([])
  const [warehouses, setWarehouses] = useState<Target[]>([])
  const load = useCallback(async () => {
    const query = supabase.from('proximity_sites').select('id, name, kind, job_id, warehouse_id, radius_metres').eq('is_active', true).order('name')
    const { data, error } = jobId ? await query.eq('job_id', jobId) : await query.limit(50)
    if (error) onError(error.message)
    else setSites((data ?? []) as Site[])
  }, [supabase, jobId, onError])
  useEffect(() => { const timer = window.setTimeout(() => { void load() }, 0); return () => clearTimeout(timer) }, [load])
  useEffect(() => {
    if (!canConfigure || jobId) return
    let active = true
    void Promise.all([
      supabase.from('jobs').select('id, job_number').order('created_at', { ascending: false }).limit(50),
      supabase.from('warehouses').select('id, name').eq('is_active', true).order('name'),
    ]).then(([jobResult, warehouseResult]) => {
      if (!active) return
      if (jobResult.error) onError(jobResult.error.message)
      else setJobs((jobResult.data ?? []).map((row) => ({ id: row.id, label: row.job_number })))
      if (warehouseResult.error) onError(warehouseResult.error.message)
      else setWarehouses((warehouseResult.data ?? []).map((row) => ({ id: row.id, label: row.name })))
    })
    return () => { active = false }
  }, [supabase, canConfigure, jobId, onError])
  async function check(site: Site) {
    setBusy(true)
    try {
      const position = await requestPosition()
      setFix(position)
      const { data, error } = await supabase.rpc('verify_proximity', { p_site_id: site.id, p_latitude: position.latitude, p_longitude: position.longitude, p_accuracy_metres: position.accuracyMetres, p_captured_at: new Date(position.capturedAt).toISOString() })
      if (error) onError(error.message)
      else setResults((current) => ({ ...current, [site.id]: (Array.isArray(data) ? data[0] : data) as Result }))
    } catch (error) { onError(error instanceof Error ? error.message : 'Location check failed.') }
    setBusy(false)
  }
  async function configure(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setBusy(true)
    try {
      const position = await requestPosition()
      const form = new FormData(event.currentTarget)
      const targetId = String(form.get('target_id') ?? '')
      if (!jobId && !targetId) throw new Error('Select a job or warehouse first.')
      const { error } = await supabase.rpc('configure_proximity_site', { p_name: String(form.get('name')).trim(), p_kind: kind, p_job_id: kind === 'hub' ? null : (jobId ?? targetId), p_warehouse_id: kind === 'hub' ? targetId : null, p_latitude: position.latitude, p_longitude: position.longitude, p_radius_metres: Number(form.get('radius_metres')) })
      if (error) onError(error.message)
      else { onNotice('Proximity site saved from your current GPS reading.'); await load() }
    } catch (error) { onError(error instanceof Error ? error.message : 'Could not configure the location.') }
    setBusy(false)
  }
  return <section className="history-panel"><div className="history-heading"><div><p className="eyebrow">PROXIMITY CHECK</p><h2>Check a location</h2></div></div><p className="section-intro">Your location is requested only when you tap Check. This advisory distance check does not prove custody or replace recipient OTP.</p>{fix && <p className="form-footnote">Last reading: {fix.source === 'native' ? 'app GPS' : 'browser GPS'} · accuracy ±{Math.round(fix.accuracyMetres)} m · {new Date(fix.capturedAt).toLocaleTimeString('en-NG')}</p>}{sites.length === 0 && <p className="notification-empty">No proximity sites are configured for this workspace yet.</p>}{sites.map((site) => <div className="request-item" key={site.id}><div className="request-item-top"><strong>{site.name}</strong><span>{site.kind.replaceAll('_', ' ')}</span></div><p>Allowed radius: {Math.round(site.radius_metres)} m</p><button className="secondary-button" disabled={busy} onClick={() => void check(site)}>{busy ? 'Checking...' : 'Check proximity'}</button>{results[site.id] && <p role="status"><strong>{results[site.id].status === 'in_range' ? 'Within range' : results[site.id].status === 'out_of_range' ? 'Outside range' : 'Location uncertain'}</strong> · about {Math.round(results[site.id].distance_metres)} m away</p>}</div>)}{canConfigure && <form className="form-grid proximity-configure" onSubmit={(event) => void configure(event)}><h3>Add a site from this location</h3><label className="field"><span>Site name</span><input name="name" required /></label><label className="field"><span>Site type</span><select name="kind" value={kind} onChange={(event) => setKind(event.target.value as typeof kind)}><option value="pickup">Pickup</option><option value="delivery">Delivery</option>{!jobId && <option value="hub">Warehouse hub</option>}</select></label>{!jobId && <label className="field"><span>{kind === 'hub' ? 'Warehouse' : 'Job'}</span><select name="target_id" required defaultValue=""><option value="">Select {kind === 'hub' ? 'warehouse' : 'job'}</option>{(kind === 'hub' ? warehouses : jobs).map((target) => <option key={target.id} value={target.id}>{target.label}</option>)}</select></label>}<label className="field"><span>Allowed radius (metres)</span><input name="radius_metres" type="number" min="20" max="5000" defaultValue="150" required /></label><button className="secondary-button" disabled={busy}>{busy ? 'Saving...' : 'Use current GPS location'}</button></form>}</section>
}
