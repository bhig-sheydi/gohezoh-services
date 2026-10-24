import type { AddressResult, AddressSuggestion, LocationEvidence, LocationPoint } from './geoapify-geocoding'
import { loadGoogleMaps, googlePoint, type GooglePlace } from './google-maps'

const component = (parts: Array<{ types: string[]; long_name?: string; longText?: string }> | undefined, type: string) =>
  parts?.find((part) => part.types.includes(type))?.long_name ?? parts?.find((part) => part.types.includes(type))?.longText ?? ''
const radians = Math.PI / 180
const distance = (a: LocationPoint, b: LocationPoint) => {
  const lat = (b.latitude - a.latitude) * radians, lon = (b.longitude - a.longitude) * radians
  return Math.round(6371000 * 2 * Math.asin(Math.sqrt(Math.min(1, Math.sin(lat / 2) ** 2 +
    Math.cos(a.latitude * radians) * Math.cos(b.latitude * radians) * Math.sin(lon / 2) ** 2))))
}
const evidence = (result: AddressResult): LocationEvidence => ({ latitude: result.latitude, longitude: result.longitude,
  accuracyMetres: null, capturedAt: Date.now(), source: 'search' })
const suggestion = (result: AddressResult, fix = evidence(result)): AddressSuggestion => ({ ...result, evidence: fix,
  qualityNote: result.specificity === 'building' ? 'Check the building and entrance.' : 'Check the point before saving.' })
type GeocodeV4 = { formattedAddress?: string; location?: { latitude: number; longitude: number }; granularity?: string;
  addressComponents?: Array<{ longText: string; types: string[] }>; placeId?: string; types?: string[] }
function fromGeocode(item: GeocodeV4): AddressResult {
  const point = item.location
  if (!point || !Number.isFinite(point.latitude) || !Number.isFinite(point.longitude)) throw new Error('Google returned an invalid location.')
  const parts = item.addressComponents
  const street = component(parts, 'route')
  const community = component(parts, 'sublocality') || component(parts, 'neighborhood')
  const city = component(parts, 'locality') || component(parts, 'administrative_area_level_2')
  const state = component(parts, 'administrative_area_level_1')
  const granularity = item.granularity
  const types = item.types ?? []
  const resultType = types.includes('locality') ? 'city' : types.includes('sublocality') || types.includes('neighborhood') ? 'suburb' : street ? 'street' : 'city'
  return { address: item.formattedAddress ?? '', city, state, street, community,
    latitude: point.latitude, longitude: point.longitude, resultType,
    specificity: granularity === 'ROOFTOP' ? 'building' : street ? 'street' : 'area',
    distanceMetres: null, confidence: null, placeId: item.placeId }
}
function fromPlace(item: GooglePlace): AddressResult {
  const point = item.location
  if (!point || !Number.isFinite(point.lat()) || !Number.isFinite(point.lng())) throw new Error('Google returned an invalid place.')
  const parts = item.addressComponents
  const street = component(parts, 'route')
  const community = component(parts, 'sublocality') || component(parts, 'neighborhood')
  const name = typeof item.displayName === 'string' ? item.displayName : item.displayName?.text
  const type = item.primaryType === 'route' || (!!street && /\b(?:street|road|avenue|close|lane|drive)\b/i.test(name ?? '')) ? 'street' :
    item.primaryType === 'locality' ? 'city' : item.primaryType === 'sublocality' ? 'suburb' : 'amenity'
  return { address: name || item.formattedAddress || '',
    city: component(parts, 'locality') || component(parts, 'administrative_area_level_2'),
    state: component(parts, 'administrative_area_level_1'), street, community,
    latitude: point.lat(), longitude: point.lng(),
    resultType: type,
    specificity: item.primaryType === 'street_address' ? 'building' : street ? 'street' : 'area',
    distanceMetres: null, confidence: null, placeId: item.id }
}
async function places(text: string, point?: LocationPoint, maximum = 5): Promise<AddressResult[]> {
  const google = await loadGoogleMaps()
  const { Place } = await google.importLibrary('places')
  const { places: matches } = await Place.searchByText({ textQuery: text, fields: ['displayName', 'formattedAddress', 'location', 'addressComponents', 'primaryType', 'id'],
    maxResultCount: maximum, region: 'ng', ...(point ? { locationBias: { center: googlePoint(point), radius: 10000 } } : {}) })
  return (matches ?? []).flatMap((item) => { try { return [fromPlace(item)] } catch { return [] } })
}
async function geocode(request: { location?: { lat: number; lng: number }; address?: string; placeId?: string }): Promise<AddressResult[]> {
  const path = request.location ? `location/${request.location.lat},${request.location.lng}`
    : request.placeId ? `places/${encodeURIComponent(request.placeId)}`
      : `address/${encodeURIComponent(request.address ?? '')}`
  const response = await fetch(`https://geocode.googleapis.com/v4/geocode/${path}`, {
    headers: { 'X-Goog-Api-Key': import.meta.env.VITE_GOOGLE_MAPS_DEMO_KEY },
    signal: AbortSignal.timeout(10_000),
  })
  if (!response.ok) throw new Error(`Google address lookup failed (${response.status}). You can enter the address manually.`)
  const payload = await response.json() as { results?: GeocodeV4[]; result?: GeocodeV4 }
  return (payload.results ?? (payload.result ? [payload.result] : [])).slice(0, 5).flatMap((item) => { try { return [fromGeocode(item)] } catch { return [] } })
}
export async function googleReverse(fix: LocationEvidence): Promise<AddressSuggestion> {
  const results = await geocode({ location: googlePoint(fix) })
  if (!results.length) throw new Error('Google could not identify this point. Keep the pin and enter the address.')
  // Reverse-geocoded buildings can be well away from the user's GPS point.
  const close = results.find((item) => distance(fix, item) <= 50) ?? results[0]
  return suggestion({ ...close, distanceMetres: distance(fix, close) }, fix)
}
export async function googleSearch(text: string, placeId?: string): Promise<AddressSuggestion> {
  const community = placeId ? (await geocode({ placeId }))[0] : null
  const query = community ? `${text}, ${community.address}` : text
  const results = await places(query, community ?? undefined).catch(() => [] as AddressResult[])
  const found = results[0] ?? (await geocode({ address: query }))[0]
  if (!found) throw new Error('Google found no matching place. Try another name or place a pin.')
  return suggestion(found)
}
export async function googleSuggest(text: string, kind?: 'locality'): Promise<AddressSuggestion[]> {
  const results = await places(text).catch(() => [] as AddressResult[])
  if (!kind) return results.map((item) => suggestion(item))
  const areas = results.filter((item) => ['city', 'suburb', 'district', 'street'].includes(item.resultType))
  if (areas.length) return areas.map((item) => suggestion(item))
  // Nigerian neighbourhoods are often indexed as a road or junction rather than
  // as a locality. Use that mapped point as an approximate search anchor.
  const contextual = await places(`${text}, Nigeria`).catch(() => [] as AddressResult[])
  const term = text.trim().toLowerCase()
  const anchors = contextual.filter((item) => item.resultType === 'street'
    && item.address.toLowerCase().startsWith(term)
    && item.city && item.state)
  if (anchors.length) return anchors.map((item) => suggestion({ ...item, address: text.trim(), resultType: 'suburb', specificity: 'area' }))
  try { return (await geocode({ address: `${text}, Nigeria` }))
    .filter((item) => ['city', 'suburb', 'district', 'street'].includes(item.resultType)).map((item) => suggestion(item)) }
  catch { return [] }
}
export async function googleNearby(text: string, point: LocationPoint, kind: 'street' | 'amenity', radius = 10000): Promise<AddressSuggestion[]> {
  const results = await places(text, point, 8).catch(() => [] as AddressResult[])
  return results.filter((item) => distance(point, item) <= radius && (kind !== 'street' || item.resultType === 'street' || !!item.street))
    .map((item) => suggestion({ ...item, distanceMetres: distance(point, item) }))
}
export async function googleClosestLandmark(point: LocationPoint): Promise<{ name: string; address?: string; distanceMetres: number } | null> {
  const response = await fetch('https://places.googleapis.com/v1/places:searchNearby', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Goog-Api-Key': import.meta.env.VITE_GOOGLE_MAPS_DEMO_KEY,
      'X-Goog-FieldMask': 'places.displayName,places.formattedAddress,places.location' },
    body: JSON.stringify({ maxResultCount: 20, rankPreference: 'DISTANCE', regionCode: 'NG',
      locationRestriction: { circle: { center: { latitude: point.latitude, longitude: point.longitude }, radius: 300 } } }),
    signal: AbortSignal.timeout(8_000),
  })
  if (!response.ok) throw new Error(`Google nearby search failed (${response.status}).`)
  const payload = await response.json() as { places?: Array<{ displayName?: { text?: string }; formattedAddress?: string;
    location?: { latitude?: number; longitude?: number } }> }
  const nearby = (payload.places ?? []).flatMap((place) => {
    const latitude = place.location?.latitude, longitude = place.location?.longitude
    const name = place.displayName?.text?.trim()
    if (!name || !Number.isFinite(latitude) || !Number.isFinite(longitude)) return []
    const metres = distance(point, { latitude: latitude!, longitude: longitude! })
    return metres <= 150 ? [{ name, address: place.formattedAddress, distanceMetres: metres }] : []
  }).sort((a, b) => a.distanceMetres - b.distanceMetres)[0]
  return nearby ?? null
}
