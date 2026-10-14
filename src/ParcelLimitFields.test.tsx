import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { ParcelMeasureFields, ParcelWeightField } from './ParcelLimitFields'
import { assessParcelCapacity } from './lib/parcel-capacity'

describe('parcel limit selectors', () => {
  it('offers only bounded dimension choices and retains a saved exact measurement', () => {
    render(<ParcelMeasureFields names={{ length: 'length_cm', width: 'width_cm', height: 'height_cm' }} defaults={{ length: 12.3 }} />)
    const length = screen.getByRole('combobox', { name: /length/i }) as HTMLSelectElement
    const width = screen.getByRole('combobox', { name: /width/i }) as HTMLSelectElement
    const height = screen.getByRole('combobox', { name: /height/i }) as HTMLSelectElement
    expect(length.value).toBe('12.3')
    expect(Number(length.options[length.options.length - 1].value)).toBe(99)
    expect(Number(width.options[width.options.length - 1].value)).toBe(60)
    expect(Number(height.options[height.options.length - 1].value)).toBe(70.5)
    expect(screen.queryByRole('spinbutton')).toBeNull()
  })

  it('offers bounded weight choices and keeps customer request weight in kilograms', () => {
    render(<ParcelWeightField name="parcel_weight" defaultValue={2.4} />)
    const weight = screen.getByRole('combobox', { name: /weight/i }) as HTMLSelectElement
    expect(weight.value).toBe('2.4')
    expect(Number(weight.options[weight.options.length - 1].value)).toBe(9.9)
    expect(screen.getByDisplayValue('kg')).toHaveAttribute('type', 'hidden')
    expect(screen.queryByRole('spinbutton')).toBeNull()
  })

  it('estimates combined item weight and packed size using selectable rotations', () => {
    expect(assessParcelCapacity(2, { length: 50, width: 30, height: 30, weight: 4 })).toEqual({ ready: true, fitsWeight: true, fitsDimensions: true })
    expect(assessParcelCapacity(2, { length: 99, width: 60, height: 70.5, weight: 5 })).toEqual({ ready: true, fitsWeight: false, fitsDimensions: false })
  })
})
