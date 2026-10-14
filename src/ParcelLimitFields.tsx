import { PARCEL_LIMITS } from './lib/parcel-limits'

type ParcelSize = { length?: number; width?: number; height?: number; weight?: number }

function valuesTo(maximum: number, step: number, preferred?: number) {
  const values = new Set<number>()
  for (let value = step; value < maximum; value += step) values.add(Number(value.toFixed(3)))
  values.add(maximum)
  if (preferred !== undefined && Number.isFinite(preferred) && preferred > 0 && preferred <= maximum) values.add(preferred)
  return [...values].sort((left, right) => left - right)
}

export function ParcelMeasureFields({ names, defaults = {} }: { names: { length: string; width: string; height: string }; defaults?: ParcelSize }) {
  const fields = [
    { key: 'length', name: names.length, label: 'Length', maximum: PARCEL_LIMITS.lengthCm, preferred: defaults.length },
    { key: 'width', name: names.width, label: 'Width', maximum: PARCEL_LIMITS.widthCm, preferred: defaults.width },
    { key: 'height', name: names.height, label: 'Height', maximum: PARCEL_LIMITS.heightCm, preferred: defaults.height },
  ] as const
  return <div className="parcel-select-fields parcel-dimension-selects">{fields.map((field) => <label className="field" key={field.key}><span>{field.label} · cm · max {field.maximum}</span><select name={field.name} required defaultValue={field.preferred === undefined ? '' : String(field.preferred)}><option value="" disabled>Select size</option>{valuesTo(field.maximum, 0.5, field.preferred).map((value) => <option key={value} value={value}>{value} cm</option>)}</select></label>)}</div>
}

export function ParcelWeightField({ name, defaultValue }: { name: string; defaultValue?: number }) {
  return <>
    <label className="field"><span>Weight per item · kg · max {PARCEL_LIMITS.weightKg}</span><select name={name} required defaultValue={defaultValue === undefined ? '' : String(defaultValue)}><option value="" disabled>Select weight</option>{valuesTo(PARCEL_LIMITS.weightKg, 0.1, defaultValue).map((value) => <option key={value} value={value}>{value} kg</option>)}</select></label>
    {name === 'parcel_weight' && <input type="hidden" name="parcel_weight_unit" value="kg" />}
  </>
}
