import type { SupabaseClient } from '@supabase/supabase-js'
import { requestAddressPosition, type PositionFix } from './proximity'

export type LocationPoint = { latitude: number; longitude: number }
export type LocationEvidence = LocationPoint & { accuracyMetres: number | null; capturedAt: number; source: 'browser' | 'native' | 'map' | 'search' }
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

/** Called only by an explicit user action. A device fix never guarantees a particular sensor or building. */
export async function getAddressFromCurrentPosition(client: SupabaseClient, options: { signal?: AbortSignal; onPosition?: (fix: PositionFix) => void } = {}): Promise<AddressSuggestion> {
  const fix = await requestAddressPosition({ signal: options.signal })
  options.signal?.throwIfAborted()
  options.onPosition?.(fix)
  return reverseAddress(client, fix, options.signal)
}
