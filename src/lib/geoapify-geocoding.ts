import { requestPosition } from './proximity'

type GeoapifyFeature = {
  properties?: {
    formatted?: string
    street?: string
    housenumber?: string
    name?: string
    suburb?: string
    city?: string
    county?: string
    state?: string
    distance?: number
  }
}

type GeoapifyResponse = { features?: GeoapifyFeature[] }
const MAX_ADDRESS_FIX_ACCURACY_METRES = 100

/** Reverse-geocodes the device's current GPS location with Geoapify. Results are suggestions, not verified premises. */
export async function getAddressFromCurrentPosition(): Promise<{ address: string; city: string; state: string; qualityNote: string }> {
  const key = import.meta.env.VITE_GEOAPIFY_API_KEY?.trim()
  if (!key) throw new Error('Address lookup is not configured. Add VITE_GEOAPIFY_API_KEY to this app’s environment.')

  const position = await requestPosition()
  if (position.accuracyMetres > MAX_ADDRESS_FIX_ACCURACY_METRES) {
    throw new Error(`Your GPS is only accurate to about ±${Math.round(position.accuracyMetres)} m, which is too imprecise to suggest a delivery address. Turn on precise location, move near a window or outdoors, and try again, or enter the address manually.`)
  }
  const params = new URLSearchParams({ lat: String(position.latitude), lon: String(position.longitude), apiKey: key })
  const response = await fetch(`https://api.geoapify.com/v1/geocode/reverse?${params}`)
  if (!response.ok) throw new Error('Address lookup failed. Check the Geoapify key and try again.')

  const result = (await response.json()) as GeoapifyResponse
  const properties = result.features?.[0]?.properties
  if (!properties) throw new Error('No address was found at this location. Enter it manually.')

  const street = properties.street || properties.name || ''
  const address = [properties.housenumber, street].filter(Boolean).join(' ') || properties.suburb || ''
  const hasHouseNumber = Boolean(properties.housenumber)
  const distance = Number.isFinite(properties.distance) ? Math.round(properties.distance!) : null
  const qualityNote = [
    hasHouseNumber ? 'Suggested address; verify the house/building before saving.' : 'Only a nearby street or area was found; enter the exact house/building address before saving.',
    `Device GPS accuracy ±${Math.round(position.accuracyMetres)} m.`,
    distance === null ? '' : `Mapped result is about ${distance} m from your location.`,
  ].filter(Boolean).join(' ')
  return { address, city: properties.city || properties.county || '', state: properties.state || '', qualityNote }
}
