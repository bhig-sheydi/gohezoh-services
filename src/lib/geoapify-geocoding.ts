import type { SupabaseClient } from '@supabase/supabase-js'
import { requestAddressPosition, type PositionFix } from './proximity'

export type LocationPoint = { latitude: number; longitude: number }
export type LocationEvidence = LocationPoint & { accuracyMetres: number | null; capturedAt: number; source: 'browser' | 'native' | 'map' | 'search' | 'saved' }
export type AddressResult = LocationPoint & {
  address: string; city: string; state: string
  specificity: 'building' | 'street' | 'area'; resultType: string
  distanceMetres: number | null; confidence: number | null
}
export type AddressSuggestion = AddressResult & { evidence: LocationEvidence; qualityNote: string }
export class AddressLookupError extends Error {
  readonly status: number
  readonly retryAfter: number | null
  readonly fix?: PositionFix
  constructor(message: string, status = 0, retryAfter: number | null = null, fix?: PositionFix) {
    super(message); this.name = 'AddressLookupError'; this.status = status; this.retryAfter = retryAfter; this.fix = fix
  }
}

// Only concurrent requests share work. Neither results nor location histories are cached.
const flights = new WeakMap<SupabaseClient, Map<string, { signal?: AbortSignal; promise: Promise<unknown> }>>()
async function invoke(client: SupabaseClient, body: object, signal?: AbortSignal): Promise<unknown> {
  signal?.throwIfAborted()
  let entries = flights.get(client)
  if (!entries) { entries = new Map(); flights.set(client, entries) }
  const key = JSON.stringify(body)
  const existing = entries.get(key)
  if (existing && existing.signal === signal) return existing.promise
  const promise = (async () => {
    const { data, error } = await client.functions.invoke('location-address', { body, signal, timeout: 20_000 })
    signal?.throwIfAborted()
    if (error) {
      const response = 'context' in error && error.context instanceof Response ? error.context : null
      const status = response?.status ?? 0
      const retrySeconds = Number(response?.headers.get('Retry-After'))
      const retryAfter = retrySeconds > 0 && Number.isFinite(retrySeconds) ? retrySeconds : null
      const message = status === 401 ? 'Sign in again to use address lookup.'
        : status === 429 ? `Address lookup is busy. ${retryAfter ? `Try again in ${retryAfter} seconds.` : 'Wait a moment before trying again.'} You can enter the address manually.`
        : status === 404 ? 'No address found. Type your address below.'
        : 'Address lookup is temporarily unavailable. You can enter the address manually and try again later.'
      throw new AddressLookupError(message, status, retryAfter)
    }
    return data
  })()
  const entry = { signal, promise }
  entries.set(key, entry)
  try { return await promise }
  finally { if (entries.get(key) === entry) entries.delete(key) }
}

function addressResult(value: unknown): AddressResult {
  if (!value || typeof value !== 'object') throw new AddressLookupError('The address service returned an invalid result. Enter the address manually.')
  const result = value as AddressResult
  if (![result.address, result.city, result.state, result.resultType].every((part) => typeof part === 'string') ||
    !['building', 'street', 'area'].includes(result.specificity) ||
    !Number.isFinite(result.latitude) || Math.abs(result.latitude) > 90 ||
    !Number.isFinite(result.longitude) || Math.abs(result.longitude) > 180 ||
    !(result.distanceMetres === null || (Number.isFinite(result.distanceMetres) && result.distanceMetres >= 0)) ||
    !(result.confidence === null || (Number.isFinite(result.confidence) && result.confidence >= 0 && result.confidence <= 1))) {
    throw new AddressLookupError('The address service returned an invalid result. Enter the address manually.')
  }
  return result
}

function suggestion(result: AddressResult, evidence: LocationEvidence): AddressSuggestion {
  const detail = result.specificity === 'building' ? 'Building-level suggestion; check the building and street.'
    : result.specificity === 'street' ? 'Street-level suggestion; add the building or house number.'
    : 'Only an area was found; enter the exact building and street.'
  const qualityNote = [detail,
    evidence.accuracyMetres === null ? 'User-selected map point; device accuracy is not available.' : `Device-reported accuracy: about ${Math.round(evidence.accuracyMetres)} m.`,
    result.distanceMetres === null ? '' : `Mapped result is ${Math.round(result.distanceMetres)} m from the requested point.`,
    result.confidence !== null && result.confidence < 0.8 ? 'The provider reports low confidence.' : '',
    result.distanceMetres !== null && result.distanceMetres > 100 ? 'The mapped address is far from this point; verify it carefully.' : '',
  ].filter(Boolean).join(' ')
  return { ...result, evidence, qualityNote }
}

export async function reverseAddress(client: SupabaseClient, evidence: LocationEvidence, signal?: AbortSignal): Promise<AddressSuggestion> {
  const result = addressResult(await invoke(client, { action: 'reverse', latitude: evidence.latitude, longitude: evidence.longitude }, signal))
  return suggestion(result, evidence)
}

/** Explicit address lookup; geocoder coordinates are not a GPS accuracy measurement. */
export async function searchAddress(client: SupabaseClient, text: string, signal?: AbortSignal): Promise<AddressSuggestion> {
  const result = addressResult(await invoke(client, { action: 'search', text }, signal))
  return suggestion(result, { latitude: result.latitude, longitude: result.longitude, accuracyMetres: null, capturedAt: Date.now(), source: 'search' })
}

export async function suggestAddresses(client: SupabaseClient, text: string, signal?: AbortSignal): Promise<AddressSuggestion[]> {
  const payload = await invoke(client, { action: 'suggest', text }, signal)
  return suggestionPayload(payload, 5)
}

function suggestionPayload(payload: unknown, maximum: number): AddressSuggestion[] {
  if (!payload || typeof payload !== 'object' || !('suggestions' in payload) || !Array.isArray(payload.suggestions) || payload.suggestions.length > maximum)
    throw new AddressLookupError('Address suggestions are unavailable. Enter the full address and try again.')
  return payload.suggestions.map((candidate: unknown) => {
    const result = addressResult(candidate)
    return suggestion(result, { latitude: result.latitude, longitude: result.longitude, accuracyMetres: null, capturedAt: Date.now(), source: 'search' })
  })
}

export async function suggestNearby(client: SupabaseClient, text: string, kind: 'street' | 'amenity', point: LocationPoint, signal?: AbortSignal, street?: string): Promise<AddressSuggestion[]> {
  async function search(query: string): Promise<AddressSuggestion[]> {
    try { return suggestionPayload(await invoke(client, { action: 'nearby_suggest', text: query, kind, ...point, ...(street ? { street } : {}) }, signal), 8) }
    catch (error) { if (error instanceof AddressLookupError && error.status === 404) return []; throw error }
  }
  const results = await search(text)
  if (results.length) return results
  // Common directions such as "school gate" are not usually part of a mapped name.
  const simpler = text.trim().replace(/(?:\s+(?:main\s+)?(?:gate|entrance|junction|bus\s+stop|roundabout))$/i, '').trim()
  return simpler.length >= 2 && simpler !== text.trim() ? search(simpler) : results
}

export async function nearbyPlaces(client: SupabaseClient, point: LocationPoint, street: string, signal?: AbortSignal): Promise<AddressSuggestion[]> {
  return suggestionPayload(await invoke(client, { action: 'nearby_places', ...point, street }, signal), 12)
}

export async function staticPinMap(client: SupabaseClient, latitude: number, longitude: number, zoom: number, signal?: AbortSignal): Promise<Blob> {
  const data = await invoke(client, { action: 'map', latitude, longitude, zoom }, signal)
  // Supabase FunctionsClient decodes application/octet-stream as a Blob.
  const blob = data instanceof Blob ? data : data instanceof ArrayBuffer ? new Blob([data]) : null
  if (!blob || blob.size < 3 || blob.size > 512 * 1024) throw new AddressLookupError('Pin map unavailable. You can still confirm the address.')
  const bytes = new Uint8Array(await blob.slice(0, 3).arrayBuffer())
  if (bytes[0] !== 255 || bytes[1] !== 216 || bytes[2] !== 255) throw new AddressLookupError('Pin map returned an invalid image.')
  return new Blob([blob], { type: 'image/jpeg' })
}

/** A labeled 256px map tile; tile coordinates are validated by the server. */
export async function mapTile(client: SupabaseClient, z: number, x: number, y: number, signal?: AbortSignal): Promise<Blob> {
  // Keep imagery from occupying every connection while an address search is running.
  const slot = nextTileSlot++ % tileSlots.length
  const task = tileSlots[slot].then(() => invoke(client, { action: 'tile', z, x, y }, signal))
  tileSlots[slot] = task.then(() => {}, () => {})
  const data = await task
  const blob = data instanceof Blob ? data : data instanceof ArrayBuffer ? new Blob([data]) : null
  if (!blob || blob.size < 8 || blob.size > 512 * 1024) throw new AddressLookupError('Map tile unavailable.')
  const bytes = new Uint8Array(await blob.slice(0, 8).arrayBuffer())
  if (![137, 80, 78, 71, 13, 10, 26, 10].every((byte, index) => bytes[index] === byte)) throw new AddressLookupError('Map tile returned an invalid image.')
  return new Blob([blob], { type: 'image/png' })
}

const tileSlots: Promise<void>[] = [Promise.resolve(), Promise.resolve(), Promise.resolve()]
let nextTileSlot = 0

/** Called only by an explicit user action. A device fix never guarantees a particular sensor or building. */
export async function getAddressFromCurrentPosition(client: SupabaseClient, options: { signal?: AbortSignal; onPosition?: (fix: PositionFix) => void } = {}): Promise<AddressSuggestion> {
  const fix = await requestAddressPosition({ signal: options.signal })
  options.signal?.throwIfAborted()
  options.onPosition?.(fix)
  return reverseAddress(client, fix, options.signal)
}
