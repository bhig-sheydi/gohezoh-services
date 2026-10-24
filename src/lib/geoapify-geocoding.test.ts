import { afterEach, describe, expect, it, vi } from 'vitest'
import type { SupabaseClient } from '@supabase/supabase-js'
import { getAddressFromCurrentPosition, identifyCurrentLocation, mapTile, reverseAddress, staticPinMap, suggestNearby, type AddressResult } from './geoapify-geocoding'
import { requestAddressPosition } from './proximity'

vi.mock('./proximity', () => ({ requestAddressPosition: vi.fn() }))
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals() })
const fix = { latitude: 6.45, longitude: 3.4, accuracyMetres: 18, capturedAt: Date.now(), source: 'browser' as const }
const address: AddressResult = { address: '10 Palm Street', city: 'Umuahia', state: 'Abia', latitude: 6.45, longitude: 3.4, specificity: 'building', resultType: 'building', distanceMetres: 12, confidence: null }
function setup(data: unknown = address, error: unknown = null) {
  const invoke = vi.fn(async (_name: string, _options: { body: Record<string, unknown> }) => ({ data, error }))
  return { invoke, client: { functions: { invoke } } as unknown as SupabaseClient }
}

describe('authenticated location lookup', () => {
  it('records the original device evidence and sends only requested coordinates to the proxy', async () => {
    vi.mocked(requestAddressPosition).mockResolvedValue(fix)
    const { client, invoke } = setup()
    const result = await getAddressFromCurrentPosition(client)
    expect(result.evidence).toEqual(fix)
    expect(result.qualityNote).toContain('Device-reported accuracy: about 18 m')
    expect(invoke).toHaveBeenCalledWith('location-address', expect.objectContaining({ body: { action: 'reverse', latitude: 6.45, longitude: 3.4 }, timeout: 20_000 }))
    expect(invoke).toHaveBeenCalledWith('location-address', expect.objectContaining({ body: { action: 'closest_landmark', latitude: 6.45, longitude: 3.4 }, timeout: 20_000 }))
    expect(JSON.stringify(invoke.mock.calls)).not.toContain('apiKey')
  })
  it('returns the best available address even with a coarse device fix', async () => {
    vi.mocked(requestAddressPosition).mockResolvedValue({ ...fix, accuracyMetres: 500 })
    const { client, invoke } = setup()
    const onPosition = vi.fn()
    await expect(getAddressFromCurrentPosition(client, { onPosition })).resolves.toMatchObject({ address: '10 Palm Street', evidence: expect.objectContaining({ accuracyMetres: 500 }) })
    expect(onPosition).toHaveBeenCalledOnce()
    expect(invoke).toHaveBeenCalledTimes(2)
  })
  it('never reverse geocodes after denied device permission', async () => {
    vi.mocked(requestAddressPosition).mockRejectedValueOnce(new Error('Location permission was denied.'))
    const { client, invoke } = setup()
    await expect(getAddressFromCurrentPosition(client)).rejects.toThrow('denied')
    expect(invoke).not.toHaveBeenCalled()
  })
  it('deduplicates identical concurrent requests but does not retain results', async () => {
    const { client, invoke } = setup()
    await Promise.all([reverseAddress(client, fix), reverseAddress(client, fix)])
    expect(invoke).toHaveBeenCalledTimes(1)
    await reverseAddress(client, fix)
    expect(invoke).toHaveBeenCalledTimes(2)
  })
  it.each([null, {}, { ...address, confidence: 10 }, { ...address, latitude: '6.45' }, { ...address, longitude: 190 }])('rejects an invalid normalized response %#', async (data) => {
    const { client } = setup(data)
    await expect(reverseAddress(client, fix)).rejects.toThrow('invalid result')
  })
  it('distinguishes coarse map data and missing confidence from physical accuracy', async () => {
    const { client } = setup({ ...address, address: '', specificity: 'area', resultType: 'city', distanceMetres: 272, confidence: 0.5 })
    const result = await reverseAddress(client, { ...fix, source: 'map', accuracyMetres: null })
    expect(result.qualityNote).toContain('Only an area')
    expect(result.qualityNote).toContain('device accuracy is not available')
    expect(result.qualityNote).toContain('low confidence')
    expect(result.qualityNote).toContain('far from this point')
  })
  it.each([401, 429, 502])('handles HTTP %i without automatic client retries', async (status) => {
    const { client, invoke } = setup(null, { context: new Response('{}', { status, headers: { 'Retry-After': '30' } }) })
    await expect(reverseAddress(client, fix)).rejects.toMatchObject({ status, retryAfter: 30 })
    expect(invoke).toHaveBeenCalledTimes(1)
  })
  it('does not start an aborted request', async () => {
    const { client, invoke } = setup()
    const controller = new AbortController(); controller.abort()
    await expect(reverseAddress(client, fix, controller.signal)).rejects.toBeDefined()
    expect(invoke).not.toHaveBeenCalled()
  })
  it('accepts the Blob returned by Supabase for a valid JPEG map', async () => {
    const { client } = setup(new Blob([new Uint8Array([255, 216, 255, 0])], { type: 'application/octet-stream' }))
    const result = await staticPinMap(client, 6.45, 3.4, 17)
    expect(result.type).toBe('image/jpeg')
    expect(Array.from(new Uint8Array(await result.arrayBuffer()))).toEqual([255, 216, 255, 0])
  })
  it('rejects invalid map bytes', async () => {
    const { client } = setup(new Blob(['not a JPEG']))
    await expect(staticPinMap(client, 6.45, 3.4, 17)).rejects.toThrow('invalid image')
  })
  it('accepts validated PNG map tiles through the authenticated function', async () => {
    const png = new Blob([new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10, 1])])
    const { client, invoke } = setup(png)
    await expect(mapTile(client, 17, 68178, 63094)).resolves.toMatchObject({ type: 'image/png' })
    expect(invoke).toHaveBeenCalledWith('location-address', expect.objectContaining({ body: { action: 'tile', z: 17, x: 68178, y: 63094 } }))
  })
  it('limits concurrent tile requests so street lookup has a free connection', async () => {
    const png = new Blob([new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10, 1])])
    const pending: Array<(value: { data: Blob; error: null }) => void> = []
    const invoke = vi.fn(() => new Promise<{ data: Blob; error: null }>((resolve) => pending.push(resolve)))
    const client = { functions: { invoke } } as unknown as SupabaseClient
    const requests = [1, 2, 3, 4].map((x) => mapTile(client, 3, x, 2))
    await vi.waitFor(() => expect(invoke).toHaveBeenCalledTimes(3))
    pending.splice(0).forEach((resolve) => resolve({ data: png, error: null }))
    await vi.waitFor(() => expect(invoke).toHaveBeenCalledTimes(4))
    pending.splice(0).forEach((resolve) => resolve({ data: png, error: null }))
    await expect(Promise.all(requests)).resolves.toHaveLength(4)
  })
  it('finds mapped schools when the customer calls one school gate', async () => {
    const { client, invoke } = setup()
    invoke.mockResolvedValueOnce({ data: null, error: { context: new Response('{}', { status: 404 }) } })
      .mockResolvedValueOnce({ data: { suggestions: [{ ...address, address: 'Umuawa-Alaocha Central School', resultType: 'amenity' }] }, error: null })
    const matches = await suggestNearby(client, 'school gate', 'amenity', fix, undefined, 'Market Road')
    expect(matches.map((match) => match.address)).toEqual(['Umuawa-Alaocha Central School'])
    expect(invoke.mock.calls.map((call) => call[1].body.text)).toEqual(['school gate', 'school'])
    expect(invoke.mock.calls[1][1].body.street).toBe('Market Road')
  })
  it('keeps an exact mapped result without a second request', async () => {
    const { client, invoke } = setup({ suggestions: [address] })
    await expect(suggestNearby(client, 'school gate', 'amenity', fix)).resolves.toHaveLength(1)
    expect(invoke).toHaveBeenCalledTimes(1)
  })
  it('prefers a nearby named place over a distant reverse-geocoded building', async () => {
    const invoke = vi.fn(async (_name: string, options: { body: { action: string } }) => ({
      data: options.body.action === 'reverse' ? { ...address, address: '2 Waga Ave', distanceMetres: 150 }
        : { landmark: { name: 'Divine Benevolent Care Organisation', distanceMetres: 29 } }, error: null,
    }))
    const client = { functions: { invoke } } as unknown as SupabaseClient
    const result = await identifyCurrentLocation(client, fix)
    expect(result).toMatchObject({ label: 'Near Divine Benevolent Care Organisation', landmarkDistanceMetres: 29 })
    expect(invoke).toHaveBeenCalledTimes(2)
  })
  it('keeps a close building address when the landmark is farther away', async () => {
    const invoke = vi.fn(async (_name: string, options: { body: { action: string } }) => ({
      data: options.body.action === 'reverse' ? { ...address, distanceMetres: 5 }
        : { landmark: { name: 'Nearby School', distanceMetres: 80 } }, error: null,
    }))
    const client = { functions: { invoke } } as unknown as SupabaseClient
    await expect(identifyCurrentLocation(client, fix)).resolves.toMatchObject({ label: '10 Palm Street', landmarkDistanceMetres: null })
  })
  it('does not retry a rate-limited landmark search with a simpler word', async () => {
    const { client, invoke } = setup(null, { context: new Response('{}', { status: 429 }) })
    await expect(suggestNearby(client, 'school gate', 'amenity', fix)).rejects.toMatchObject({ status: 429 })
    expect(invoke).toHaveBeenCalledTimes(1)
  })
})
