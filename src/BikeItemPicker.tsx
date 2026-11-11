import { useEffect, useMemo, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'

export type BikeItem = { code: string; category: string; label: string; length_cm: number; width_cm: number; height_cm: number; estimated_weight_kg: number; measurement: 'unit' | 'pages' }

export default function BikeItemPicker({ supabase, defaultCode, defaultPages, onSelected }: {
  supabase: SupabaseClient; defaultCode?: string | null; defaultPages?: number | null;
  onSelected?: (item: BikeItem | null) => void
}) {
  const [items, setItems] = useState<BikeItem[]>([])
  const [query, setQuery] = useState('')
  const [code, setCode] = useState(defaultCode ?? '')
  const [pages, setPages] = useState(defaultPages ?? 1)
  const [error, setError] = useState('')
  useEffect(() => {
    let active = true
    void supabase.from('bike_item_catalogue').select('code,category,label,length_cm,width_cm,height_cm,estimated_weight_kg,measurement')
      .order('category').order('label').then(({ data, error: loadError }) => {
        if (!active) return
        if (loadError) setError('Could not load item choices. Please try again.')
        else setItems((data ?? []) as BikeItem[])
      })
    return () => { active = false }
  }, [supabase])
  const selected = items.find((item) => item.code === code) ?? null
  const matches = useMemo(() => items.filter((item) =>
    `${item.category} ${item.label}`.toLowerCase().includes(query.trim().toLowerCase())).slice(0, 80), [items, query])
  const estimatedHeight = selected?.measurement === 'pages' ? Math.round((0.5 + pages * 0.01) * 10) / 10 : selected?.height_cm
  return <div className="bike-item-picker">
    <label className="field"><span>Search what you are sending</span><input type="search" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="e.g. wig, phone, meal, documents" /></label>
    <label className="field"><span>Item type</span><select name="catalog_code" value={code} required onChange={(event) => {
      setCode(event.target.value); onSelected?.(items.find((item) => item.code === event.target.value) ?? null)
    }}><option value="">Choose an item</option>{matches.map((item) => <option key={item.code} value={item.code}>{item.label} · {item.category}</option>)}
      {selected && !matches.some((item) => item.code === code) && <option value={code}>{selected.label} · {selected.category}</option>}</select></label>
    {selected?.measurement === 'pages' && <label className="field"><span>Pages per envelope</span><input name="parcel_pages" type="number" min="1" max="500" step="1" required value={pages} onChange={(event) => setPages(Number(event.target.value))} /></label>}
    {selected && <p className="parcel-capacity-help">Estimated packed size: {selected.length_cm} × {selected.width_cm} × {estimatedHeight} cm. Approximate weight: {selected.measurement === 'pages' ? (0.02 + pages * 0.005).toFixed(2) : selected.estimated_weight_kg} kg. Check the actual packaging before pickup.</p>}
    {error && <p role="alert">{error}</p>}
  </div>
}
