import { PARCEL_LIMITS } from './parcel-limits'

export function assessParcelCapacity(quantity: number, size: { length: number; width: number; height: number; weight: number }) {
  const { length, width, height, weight } = size
  if (![quantity, length, width, height, weight].every(Number.isFinite) || quantity < 1 || length <= 0 || width <= 0 || height <= 0 || weight <= 0) return { ready: false, fitsWeight: false, fitsDimensions: false }
  const fitsWeight = weight * quantity <= PARCEL_LIMITS.weightKg + 1e-9
  const dimensions = [[length, width, height], [length, height, width], [width, length, height], [width, height, length], [height, length, width], [height, width, length]]
  const fitsDimensions = dimensions.some(([itemLength, itemWidth, itemHeight]) =>
    Math.floor((PARCEL_LIMITS.lengthCm + 1e-9) / itemLength!) *
    Math.floor((PARCEL_LIMITS.widthCm + 1e-9) / itemWidth!) *
    Math.floor((PARCEL_LIMITS.heightCm + 1e-9) / itemHeight!) >= quantity)
  return { ready: true, fitsWeight, fitsDimensions }
}
