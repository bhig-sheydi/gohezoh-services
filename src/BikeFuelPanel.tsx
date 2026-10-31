import { useCallback, useEffect, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import './bike-fuel-panel.css'

type Gauge = { rider_id: string; rider_name: string; registration_number: string; purchased_litres: number;
  purchased_amount_ngn: number; estimated_used_litres: number; estimated_remaining_litres: number }
const money = (value: number) => new Intl.NumberFormat('en-NG', { style: 'currency', currency: 'NGN' }).format(value)

export default function BikeFuelPanel({ supabase, onError, onNotice }: { supabase: SupabaseClient;
  onError: (message: string) => void; onNotice: (message: string) => void }) {
  const [rows, setRows] = useState<Gauge[]>([])
  const [busy, setBusy] = useState(false)
  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc('list_my_bike_fuel_gauges')
    if (error) onError(error.message)
    else setRows((data ?? []) as Gauge[])
  }, [supabase, onError])
  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer) }, [load])

  async function addFuel(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (busy) return
    const form = new FormData(event.currentTarget)
    const litres = Number(form.get('litres'))
    const amount = Number(form.get('amount'))
    if (!Number.isFinite(litres) || litres <= 0 || litres > 100 || !Number.isFinite(amount) || amount <= 0) {
      onError('Enter valid litres and the amount paid.'); return
    }
    setBusy(true)
    const { error } = await supabase.rpc('record_bike_fuel_purchase', {
      p_rider_id: String(form.get('rider')), p_litres: litres, p_amount_ngn: amount,
    })
    if (error) onError(error.message)
    else { onNotice('Fuel purchase recorded.'); event.currentTarget.reset(); await load() }
    setBusy(false)
  }

  return <section className="bike-fuel-panel" aria-label="Estimated bike fuel">
    <header><div><p className="eyebrow">BIKE FUEL</p><h2>Estimated tank gauge</h2></div><button className="secondary-button" type="button" onClick={() => void load()}>Refresh</button></header>
    <p className="bike-fuel-caution">Estimate only, not a tank reading. It deducts modeled pickup-to-drop-off fuel after completed deliveries. Detours, idling, riding to pickup, leaks and bike condition can change actual fuel. Check each tank before dispatch.</p>
    {rows.length === 0 ? <p>No approved registered motorcycles are ready for fuel tracking.</p> : <>
      <div className="bike-fuel-grid">{rows.map((row) => <article className="bike-fuel-card" key={row.rider_id}>
        <strong>{row.rider_name}</strong><small>{row.registration_number}</small>
        <div className="bike-fuel-readout"><span>Estimated remaining</span><strong>{Number(row.estimated_remaining_litres).toFixed(2)} L</strong></div>
        <meter min="0" max={Math.max(Number(row.purchased_litres), 1)} value={Math.min(Number(row.estimated_remaining_litres), Number(row.purchased_litres))} aria-label={`${row.rider_name} estimated fuel remaining`} />
        <small>Bought {Number(row.purchased_litres).toFixed(2)} L · {money(Number(row.purchased_amount_ngn))} · modeled use {Number(row.estimated_used_litres).toFixed(2)} L</small>
      </article>)}</div>
      <form className="bike-fuel-form" onSubmit={(event) => void addFuel(event)}>
        <h3>Record fuel bought</h3>
        <label className="field"><span>Bike / rider</span><select name="rider" required><option value="">Choose bike</option>{rows.map((row) => <option key={row.rider_id} value={row.rider_id}>{row.rider_name} · {row.registration_number}</option>)}</select></label>
        <label className="field"><span>Approximate litres</span><input name="litres" type="number" min="0.01" max="100" step="0.01" required /></label>
        <label className="field"><span>Amount paid (NGN)</span><input name="amount" type="number" min="1" step="0.01" required /></label>
        <button className="primary-button" disabled={busy}>{busy ? 'Saving…' : 'Add fuel purchase'}</button>
      </form>
    </>}
  </section>
}
