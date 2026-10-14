import { afterEach, describe, expect, it, vi } from 'vitest'
import { getAddressFromCurrentPosition } from './geoapify-geocoding'
import { requestPosition } from './proximity'

vi.mock('./proximity', () => ({ requestPosition: vi.fn() }))

afterEach(() => {
  vi.unstubAllEnvs()
  vi.restoreAllMocks()
})

describe('Geoapify reverse geocoding', () => {
  it('does not geocode an imprecise GPS fix', async () => {
    vi.stubEnv('VITE_GEOAPIFY_API_KEY', 'test-key')
    vi.mocked(requestPosition).mockResolvedValue({ latitude: 6.45, longitude: 3.4, accuracyMetres: 500, capturedAt: Date.now(), source: 'browser' })
    const fetchSpy = vi.spyOn(globalThis, 'fetch')

    await expect(getAddressFromCurrentPosition()).rejects.toThrow('±500 m')
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it('returns the nearest address suggestion and its precision note for a good fix', async () => {
    vi.stubEnv('VITE_GEOAPIFY_API_KEY', 'test-key')
    vi.mocked(requestPosition).mockResolvedValue({ latitude: 6.45, longitude: 3.4, accuracyMetres: 18, capturedAt: Date.now(), source: 'browser' })
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: true, json: async () => ({ features: [{ properties: { housenumber: '10', street: 'Palm Street', city: 'Umuahia', state: 'Abia', distance: 12 } }] }) }))

    await expect(getAddressFromCurrentPosition()).resolves.toEqual({
      address: '10 Palm Street', city: 'Umuahia', state: 'Abia',
      qualityNote: 'Suggested address; verify the house/building before saving. Device GPS accuracy ±18 m. Mapped result is about 12 m from your location.',
    })
  })
})
