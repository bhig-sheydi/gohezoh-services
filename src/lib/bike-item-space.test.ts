import { expect, it } from 'vitest'
import { bikeItemEstimate, bikeSpaceSurcharge } from './bike-item-space'
import type { BikeItem } from '../BikeItemPicker'

const textbook: BikeItem = { code: 'textbook', category: 'Documents', label: 'Textbook', length_cm: 29,
  width_cm: 23, height_cm: 6, estimated_weight_kg: 1.2, measurement: 'unit' }

it('prices occupied litres and repeated units, not linear inches', () => {
  const one = bikeItemEstimate(textbook, 1)
  const two = bikeItemEstimate(textbook, 2)
  expect(one.fits).toBe(true)
  expect(two.volume).toBe(one.volume * 2)
  expect(bikeSpaceSurcharge(one.volume)).toBe(50)
  expect(bikeSpaceSurcharge(two.volume)).toBe(250)
})

it('uses page count to estimate document thickness and surcharge', () => {
  const documents: BikeItem = { ...textbook, code: 'documents', measurement: 'pages', length_cm: 32,
    width_cm: 24, height_cm: 1, estimated_weight_kg: 0.1 }
  expect(bikeItemEstimate(documents, 1, 10).height).toBe(0.6)
  expect(bikeItemEstimate(documents, 1, 500).height).toBe(5.5)
  expect(bikeSpaceSurcharge(bikeItemEstimate(documents, 1, 500).volume, 500)).toBe(300)
})

it('rejects a repeated item that cannot fit the bike box', () => {
  expect(bikeItemEstimate(textbook, 10).fits).toBe(false)
})
