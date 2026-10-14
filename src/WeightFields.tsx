import { weightUnits } from './lib/weight'

export default function WeightFields({ valueName, unitName, defaultValue }: { valueName: string; unitName: string; defaultValue?: number }) {
  return <>
    <label className="field"><span>Weight</span><input name={valueName} type="number" min="0" step="any" defaultValue={defaultValue} /></label>
    <label className="field"><span>Weight unit</span><select name={unitName} defaultValue="kg">{weightUnits.map((unit) => <option key={unit.value} value={unit.value}>{unit.label}</option>)}</select></label>
  </>
}
