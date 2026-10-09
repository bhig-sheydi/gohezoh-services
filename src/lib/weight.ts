export const weightUnits = [
  { value: 'kg', label: 'Kilograms (kg)', kilograms: 1 },
  { value: 'g', label: 'Grams (g)', kilograms: 0.001 },
  { value: 'mg', label: 'Milligrams (mg)', kilograms: 0.000001 },
  { value: 't', label: 'Metric tonnes (t)', kilograms: 1000 },
  { value: 'lb', label: 'Pounds (lb)', kilograms: 0.45359237 },
  { value: 'oz', label: 'Ounces (oz)', kilograms: 0.028349523125 },
] as const

export function weightInKilograms(raw: FormDataEntryValue | null, unit: string): number | null {
  if (raw === null || String(raw).trim() === '') return null
  const value = Number(raw)
  const selected = weightUnits.find((entry) => entry.value === unit)
  if (!selected || !Number.isFinite(value) || value < 0) throw new Error('Enter a valid, non-negative weight and unit.')
  const kilograms = Math.round(value * selected.kilograms * 1_000_000_000) / 1_000_000_000
  if (value > 0 && kilograms === 0) throw new Error('Weight is too small to record accurately.')
  if (kilograms >= 10_000_000) throw new Error('Weight is too large.')
  return kilograms
}
