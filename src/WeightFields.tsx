import { weightUnits } from './lib/weight'

export default function WeightFields({ valueName, unitName }: { valueName: string; unitName: string }) {
  return <>
    <label className="field"><span>Weight</span><input name={valueName} type="number" min="0" step="any" /></label>
    <label className="field"><span>Weight unit</span><select name={unitName} defaultValue="kg">{weightUnits.map((unit) => <option key={unit.value} value={unit.value}>{unit.label}</option>)}</select></label>
  </>
}
