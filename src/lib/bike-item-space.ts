import type { BikeItem } from '../BikeItemPicker'

export const BIKE_BOX = { lengthCm: 38, widthCm: 32, heightCm: 32, volumeCm3: 38912, safetyKg: 25 } as const
export const MAX_GOODS_VALUE_NGN = 70000

export function bikeItemEstimate(item: BikeItem, quantity: number, pages = 1) {
  const height = item.measurement === 'pages' ? Math.round((0.5 + pages * 0.01) * 10) / 10 : item.height_cm
  const weight = item.measurement === 'pages' ? 0.02 + pages * 0.005 : item.estimated_weight_kg
  const volume = item.length_cm * item.width_cm * height * quantity
  const dimensions = [item.length_cm, item.width_cm, height]
  const box = [BIKE_BOX.lengthCm, BIKE_BOX.widthCm, BIKE_BOX.heightCm]
  const fitsShape = [
    [0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0],
  ].some(([a, b, c]) => Math.floor(box[0] / dimensions[a])
    * Math.floor(box[1] / dimensions[b]) * Math.floor(box[2] / dimensions[c]) >= quantity)
  return { volume, weight: weight * quantity, height,
    fits: Number.isInteger(quantity) && quantity >= 1 && quantity <= 50 &&
      Number.isInteger(pages) && pages >= 1 && pages <= 500 &&
      volume <= BIKE_BOX.volumeCm3 && weight * quantity <= BIKE_BOX.safetyKg && fitsShape }
}

export function bikeSpaceSurcharge(volumeCm3: number, documentPages = 0) {
  return Math.ceil(Math.max(0, volumeCm3 - 3000) / 1000 * 40 / 50) * 50
    + Math.ceil(documentPages / 100) * 50
}
