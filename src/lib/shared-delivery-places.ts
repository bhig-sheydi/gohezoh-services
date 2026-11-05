import type { SupabaseClient } from '@supabase/supabase-js'
import type { AddressSuggestion, LocationPoint } from './geoapify-geocoding'

type SharedPlaceRow = {
  id: unknown
  label: unknown
  city: unknown
  state: unknown
  latitude: unknown
  longitude: unknown
  distance_metres: unknown
}

const validPoint = (latitude: unknown, longitude: unknown): latitude is number =>
  typeof latitude === 'number' && Number.isFinite(latitude) && Math.abs(latitude) <= 90 &&
  typeof longitude === 'number' && Number.isFinite(longitude) && Math.abs(longitude) <= 180

function asSuggestion(row: SharedPlaceRow): AddressSuggestion | null {
  if (typeof row.label !== 'string' || !row.label.trim() || row.label.length > 300 ||
    typeof row.city !== 'string' || row.city.length > 100 ||
    typeof row.state !== 'string' || row.state.length > 100 ||
    !validPoint(row.latitude, row.longitude) ||
    !(row.distance_metres === null || (typeof row.distance_metres === 'number' && Number.isFinite(row.distance_metres) && row.distance_metres >= 0))) return null

  return {
    address: row.label.trim(), city: row.city, state: row.state,
    latitude: row.latitude, longitude: row.longitude as number,
    specificity: 'street', resultType: 'confirmed_delivery_point',
    confidence: null, distanceMetres: row.distance_metres,
    evidence: { latitude: row.latitude, longitude: row.longitude as number,
      accuracyMetres: null, capturedAt: Date.now(), source: 'saved' },
    qualityNote: 'Previously saved delivery point. Check the address and pin before confirming.',
  }
}

/** Search customer-confirmed places; no provider content or personal contact data is returned. */
export async function searchSharedDeliveryPlaces(
  client: SupabaseClient,
  query: string,
  city: string,
  point?: LocationPoint,
  signal?: AbortSignal,
): Promise<AddressSuggestion[]> {
  signal?.throwIfAborted()
  if (!point && query.trim().length < 3) return []
  const request = client.rpc('search_shared_delivery_places', {
    p_query: query.trim(), p_city: city.trim(),
    p_latitude: point?.latitude ?? null, p_longitude: point?.longitude ?? null,
    p_limit: 8,
  })
  const { data, error } = await (signal ? request.abortSignal(signal) : request)
  signal?.throwIfAborted()
  if (error) throw new Error('Saved places are unavailable right now.')
  if (!Array.isArray(data)) throw new Error('Saved places returned an invalid response.')
  return data.flatMap((row: unknown) => {
    if (!row || typeof row !== 'object') return []
    const suggestion = asSuggestion(row as SharedPlaceRow)
    return suggestion ? [suggestion] : []
  })
}
