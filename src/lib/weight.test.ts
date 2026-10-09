import { describe, expect, it } from 'vitest'
import { weightInKilograms } from './weight'

describe('weight unit conversion', () => {
  it.each([
    ['kg', '1.25', 1.25],
    ['g', '1250', 1.25],
    ['mg', '1', 0.000001],
    ['t', '2', 2000],
    ['lb', '1', 0.45359237],
    ['oz', '1', 0.028349523],
  ])('converts %s to kilograms', (unit, value, kilograms) => {
    expect(weightInKilograms(value, unit)).toBe(kilograms)
  })

  it('keeps optional weight empty and rejects a value too small to store', () => {
    expect(weightInKilograms(null, 'kg')).toBeNull()
    expect(() => weightInKilograms('0.0001', 'mg')).toThrow('too small')
  })
})
