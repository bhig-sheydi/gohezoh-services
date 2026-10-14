export const BASE_PARCEL_LIMITS = { lengthCm: 33, widthCm: 20, heightCm: 23.5, weightKg: 3.3 } as const
export const PARCEL_CAPACITY_MULTIPLIER = 3
export const PARCEL_LIMITS = {
  lengthCm: BASE_PARCEL_LIMITS.lengthCm * PARCEL_CAPACITY_MULTIPLIER,
  widthCm: BASE_PARCEL_LIMITS.widthCm * PARCEL_CAPACITY_MULTIPLIER,
  heightCm: BASE_PARCEL_LIMITS.heightCm * PARCEL_CAPACITY_MULTIPLIER,
  weightKg: Number((BASE_PARCEL_LIMITS.weightKg * PARCEL_CAPACITY_MULTIPLIER).toFixed(3)),
} as const
export const PARCEL_MAX_QUANTITY = 50
