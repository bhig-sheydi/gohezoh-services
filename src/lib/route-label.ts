export function routePoint(address: string | null | undefined, city: string): string {
  return address?.trim() || city
}

export function routeLabel(pickupAddress: string | null | undefined, pickupCity: string, deliveryAddress: string | null | undefined, deliveryCity: string): string {
  return `${routePoint(pickupAddress, pickupCity)} → ${routePoint(deliveryAddress, deliveryCity)}`
}
