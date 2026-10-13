import { useCallback, useEffect, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'

type HubJob = { id: string; job_number: string; status: string; pickup_city: string; delivery_city: string }
type Warehouse = { id: string; name: string; city: string }
type Partner = { id: string; partner_name: string }
export default function PortHarcourtHubPanel({ supabase, onError, onNotice }: { supabase: SupabaseClient; onError: (message: string) => void; onNotice: (message: string) => void }) {
  const [jobs, setJobs] = useState<HubJob[]>([])
  const [partners, setPartners] = useState<Partner[]>([])
  const [warehouses, setWarehouses] = useState<Warehouse[]>([])
  const [busy, setBusy] = useState('')
  const load = useCallback(async () => {
    const [jobsResult, warehouseResult, partnerResult] = await Promise.all([
      supabase.from('jobs').select('id, job_number, status, pickup_city, delivery_city').ilike('delivery_city', 'Port Harcourt').not('status', 'in', '(closed,cancelled)').limit(50),
      supabase.from('warehouses').select('id, name, city').ilike('city', 'Port Harcourt'),
      supabase.from('logistics_partners').select('id, partner_name').eq('status', 'active').order('partner_name'),
    ])
    if (jobsResult.error || warehouseResult.error || partnerResult.error) onError((jobsResult.error ?? warehouseResult.error ?? partnerResult.error)?.message ?? 'Could not load hub records.')
    else { setJobs((jobsResult.data ?? []) as HubJob[]); setWarehouses((warehouseResult.data ?? []) as Warehouse[]); setPartners((partnerResult.data ?? []) as Partner[]) }
  }, [supabase, onError])
  useEffect(() => { const timer = window.setTimeout(() => { void load() }, 0); return () => clearTimeout(timer) }, [load])
  async function receipt(event: FormEvent<HTMLFormElement>, job: HubJob) {
    event.preventDefault()
    const form = new FormData(event.currentTarget)
    setBusy(job.id)
    const { error } = await supabase.rpc('record_port_harcourt_hub_receipt', { p_inbound_job_id: job.id, p_warehouse_id: String(form.get('warehouse_id')), p_scan_reference: String(form.get('scan_reference')).trim(), p_parcel_condition: String(form.get('parcel_condition')).trim() })
    if (error) onError(error.message)
    else { onNotice(`Hub receipt saved for ${job.job_number}.`); await load() }
    setBusy('')
  }
  async function assign(event: FormEvent<HTMLFormElement>, job: HubJob) {
    event.preventDefault()
    const form = new FormData(event.currentTarget)
    setBusy(job.id)
    const { data, error } = await supabase.rpc('assign_port_harcourt_last_mile', { p_job_id: job.id, p_partner_id: String(form.get('partner_id')) })
    if (error) onError(error.message)
    else onNotice(`Last-mile leg assigned for ${job.job_number}${data?.leg_number ? ` (${data.leg_number})` : ''}.`)
    setBusy('')
  }
  return <section className="history-panel"><div className="history-heading"><div><p className="eyebrow">PORT HARCOURT HUB</p><h2>Inbound custody and last mile</h2></div><button className="secondary-button" onClick={() => void load()}>Refresh</button></div><p className="section-intro">Record Kwik-Parsel's receipt, then assign the onward last-mile leg on the same job. Recipient OTP is still required for final delivery.</p>{jobs.length === 0 ? <p className="notification-empty">No active Port Harcourt inbound jobs.</p> : <div className="request-list">{jobs.map((job) => <article className="request-item" key={job.id}><div className="request-item-top"><strong>{job.job_number}</strong><span>{job.status.replaceAll('_', ' ')}</span></div><p>{job.pickup_city} to {job.delivery_city}</p><form className="form-grid" onSubmit={(event) => void receipt(event, job)}><div className="field-row"><label className="field"><span>Receiving warehouse</span><select name="warehouse_id" required defaultValue=""><option value="">Choose warehouse</option>{warehouses.map((warehouse) => <option key={warehouse.id} value={warehouse.id}>{warehouse.name}</option>)}</select></label><label className="field"><span>Parcel scan reference</span><input name="scan_reference" required /></label></div><label className="field"><span>Parcel condition</span><input name="parcel_condition" required placeholder="For example: sealed, no visible damage" /></label><button className="secondary-button" disabled={busy === job.id || warehouses.length === 0}>Record hub receipt</button></form><form className="form-grid" onSubmit={(event) => void assign(event, job)}><label className="field"><span>Last-mile partner</span><select name="partner_id" required defaultValue=""><option value="">Choose an approved partner</option>{partners.map((partner) => <option key={partner.id} value={partner.id}>{partner.partner_name}</option>)}</select></label><button className="secondary-button" disabled={busy === job.id || partners.length === 0}>Assign last-mile leg</button></form></article>)}</div>}</section>
}
