import { afterEach, describe, expect, it, vi } from 'vitest'
import { requestPosition } from './proximity'

afterEach(() => {
  vi.restoreAllMocks()
  delete window.GohezohLocation
  delete window.ReactNativeWebView
})

describe('requestPosition', () => {
  it('uses one browser location reading', async () => {
    const getCurrentPosition = vi.fn((success: PositionCallback) => success({
      coords: { latitude: 6.45, longitude: 3.4, accuracy: 18 }, timestamp: Date.now(),
    } as GeolocationPosition))
    vi.stubGlobal('navigator', { ...navigator, geolocation: { getCurrentPosition } })
    const fix = await requestPosition()
    expect(fix).toMatchObject({ latitude: 6.45, longitude: 3.4, accuracyMetres: 18, source: 'browser' })
    expect(getCurrentPosition).toHaveBeenCalledTimes(1)
    vi.unstubAllGlobals()
  })

  it('matches the native reply to the request and rejects stale readings', async () => {
    window.GohezohLocation = { requestPosition: (requestId) => {
      queueMicrotask(() => window.dispatchEvent(new CustomEvent('gohezoh:position', { detail: {
        type: 'gohezoh:position:result', requestId, latitude: 4.8, longitude: 7.0,
        accuracyMetres: 8, capturedAt: Date.now() - 120_000,
      } })))
    } }
    await expect(requestPosition()).rejects.toThrow('stale or invalid')
  })
})
