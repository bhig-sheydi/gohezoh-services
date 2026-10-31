import { useCallback, useEffect, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'

type Policy = { fuel_price_ngn: number; benchmark_charge_ngn: number; benchmark_distance_metres: number;
  benchmark_fuel_price_ngn: number; litres_per_km: number; updated_at: string }
const money = (value: number) => new Intl.NumberFormat('en-NG', { style: 'currency', currency: 'NGN' }).format(value)

export default function AdminBikePricePanel({ supabase, onError, onNotice }: { supabase: SupabaseClient;
  onError: (message: string) => void; onNotice: (message: string) => void }) {
  const [policy, setPolicy] = useState<Policy | null>(null)
  const [busy, setBusy] = useState(false)
  const load = useCallback(async () => {
    const { data, error } = await supabase.from('bike_price_policy')
      .select('fuel_price_ngn,benchmark_charge_ngn,benchmark_distance_metres,benchmark_fuel_price_ngn,litres_per_km,updated_at').eq('id', true).single()
    if (error) onError(error.message)
    else setPolicy(data as Policy)
  }, [supabase, onError])
  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer) }, [load])
  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const value = Number(new FormData(event.currentTarget).get('fuel_price'))
    if (!Number.isFinite(value) || value < 100 || value > 10000) { onError('Enter a price between ₦100 and ₦10,000 per litre.'); return }
    setBusy(true)
    const { error } = await supabase.rpc('set_bike_fuel_price', { p_price_ngn: value })
    if (error) onError(error.message)
    else { onNotice('Bike fuel price updated for new quotes. Existing quotes keep their original price.'); await load() }
    setBusy(false)
  }
  return <section className="form-card" aria-label="Bike delivery pricing">
    <p className="eyebrow">BIKE PRICING</p><h2>Fuel price per litre</h2>
    <p>Used when calculating new local motorcycle delivery prices. Existing offers and payments stay fixed.</p>
    {policy && <p>Reference trip: {money(Number(policy.benchmark_charge_ngn))} for {(Number(policy.benchmark_distance_metres) / 1000).toFixed(1)} km at {money(Number(policy.benchmark_fuel_price_ngn))}/L. Estimated use: {Number(policy.litres_per_km).toFixed(3)} L/km.</p>}
    <form className="form-grid" onSubmit={(event) => void save(event)}>
      <label className="field"><span>Current petrol price (NGN per litre)</span><input key={policy?.updated_at} name="fuel_price" type="number" min="100" max="10000" step="0.01" defaultValue={policy?.fuel_price_ngn} required /></label>
      <button className="primary-button" disabled={busy || !policy}>{busy ? 'Saving…' : 'Save fuel price'}</button>
    </form>
  </section>
}
