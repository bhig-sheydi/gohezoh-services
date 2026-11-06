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

type CachedTextSearch = {
  results?: AddressSuggestion[]
  expiresAt?: number
  pending?: Promise<AddressSuggestion[]>
}

// Only customer-contributed place results are kept in memory. Provider results
// and device coordinates are never cached here. The small, short-lived cache
// also coalesces a Find click with an autocomplete request for the same text.
const textSearches = new WeakMap<SupabaseClient, Map<string, CachedTextSearch>>()
const TEXT_CACHE_LIMIT = 64
const TEXT_CACHE_MS = 10_000
const EMPTY_CACHE_MS = 2_000
const REQUEST_TIMEOUT_MS = 6_000

function searchKey(query: string, city: string): string {
  return `${city.trim().toLowerCase().replace(/\s+/g, ' ')}\u0000${query.trim().toLowerCase().replace(/\s+/g, ' ')}`
}

function awaitWithSignal<T>(promise: Promise<T>, signal?: AbortSignal): Promise<T> {
  if (!signal) return promise
  signal.throwIfAborted()
  return new Promise<T>((resolve, reject) => {
    const aborted = () => { signal.removeEventListener('abort', aborted); reject(signal.reason ?? new DOMException('Aborted', 'AbortError')) }
    signal.addEventListener('abort', aborted, { once: true })
    promise.then(
      (value) => { signal.removeEventListener('abort', aborted); resolve(value) },
      (error) => { signal.removeEventListener('abort', aborted); reject(error) },
    )
  })
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
  const fetchResults = async (requestSignal?: AbortSignal): Promise<AddressSuggestion[]> => {
    const request = client.rpc('search_shared_delivery_places', {
      p_query: query.trim(), p_city: city.trim(),
      p_latitude: point?.latitude ?? null, p_longitude: point?.longitude ?? null,
      p_limit: 8,
    })
    const { data, error } = await (requestSignal ? request.abortSignal(requestSignal) : request)
    if (error) throw new Error('Saved places are unavailable right now.')
    if (!Array.isArray(data)) throw new Error('Saved places returned an invalid response.')
    return data.flatMap((row: unknown) => {
      if (!row || typeof row !== 'object') return []
      const suggestion = asSuggestion(row as SharedPlaceRow)
      return suggestion ? [suggestion] : []
    })
  }

  if (point) {
    const results = await fetchResults(signal)
    signal?.throwIfAborted()
    return results
  }

  let cache = textSearches.get(client)
  if (!cache) {
    cache = new Map(); textSearches.set(client, cache)
    const sessionCache = cache
    // A Supabase client can be reused after sign-out or account switching.
    // Never serve a prior customer's cached results into the next session.
    client.auth?.onAuthStateChange?.((event) => {
      if (event === 'SIGNED_OUT' || event === 'SIGNED_IN' || event === 'USER_UPDATED') sessionCache.clear()
    })
  }
  const key = searchKey(query, city)
  const entry = cache.get(key)
  if (entry?.results && (entry.expiresAt ?? 0) > Date.now()) return awaitWithSignal(Promise.resolve(entry.results), signal)
  if (entry?.pending) return awaitWithSignal(entry.pending, signal)

  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS)
  const current: CachedTextSearch = {}
  const pending = fetchResults(controller.signal).then((results) => {
    current.results = results
    current.expiresAt = Date.now() + (results.length ? TEXT_CACHE_MS : EMPTY_CACHE_MS)
    return results
  }).finally(() => {
    clearTimeout(timeout)
    current.pending = undefined
    if (!current.results && cache?.get(key) === current) cache.delete(key)
  })
  current.pending = pending
  cache.set(key, current)
  while (cache.size > TEXT_CACHE_LIMIT) cache.delete(cache.keys().next().value!)
  return awaitWithSignal(pending, signal)
}
