import { afterEach, describe, expect, it, vi } from 'vitest'
import { LocationError, requestAddressPosition, requestPosition } from './proximity'

function position(accuracy = 18, timestamp = Date.now()): GeolocationPosition {
  return { coords: { latitude: 6.45, longitude: 3.4, accuracy }, timestamp } as GeolocationPosition
}

function installBrowser(getCurrentPosition: ReturnType<typeof vi.fn>) {
  vi.stubGlobal('navigator', { geolocation: { getCurrentPosition } })
  vi.stubGlobal('isSecureContext', true)
}

function nativeReply(requestId: string, overrides: Record<string, unknown> = {}) {
  window.dispatchEvent(new CustomEvent('gohezoh:position', { detail: {
    type: 'gohezoh:position:result', requestId, latitude: 4.8, longitude: 7.0,
    accuracyMetres: 8, capturedAt: Date.now(), ...overrides,
  } }))
}

afterEach(() => {
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
  vi.useRealTimers()
  delete window.GohezohLocation
  delete window.ReactNativeWebView
})

describe('requestPosition', () => {
  it('uses one fresh browser reading with high accuracy and records its timestamp', async () => {
    const capturedAt = Date.now()
    const getCurrentPosition = vi.fn((success: PositionCallback) => success(position(18, capturedAt)))
    installBrowser(getCurrentPosition)
    await expect(requestPosition()).resolves.toEqual({ latitude: 6.45, longitude: 3.4, accuracyMetres: 18, capturedAt, source: 'browser' })
    expect(getCurrentPosition).toHaveBeenCalledExactlyOnceWith(expect.any(Function), expect.any(Function), { enableHighAccuracy: true, maximumAge: 0, timeout: 12_000 })
  })

  it('rejects an insecure context without invoking geolocation', async () => {
    const getCurrentPosition = vi.fn()
    installBrowser(getCurrentPosition)
    vi.stubGlobal('isSecureContext', false)
    await expect(requestPosition()).rejects.toMatchObject({ code: 'insecure' })
    expect(getCurrentPosition).not.toHaveBeenCalled()
  })

  it('handles a browser without geolocation', async () => {
    vi.stubGlobal('navigator', {})
    await expect(requestPosition()).rejects.toMatchObject({ code: 'unavailable' })
  })

  it('reports denied permission without exposing a browser error or retrying', async () => {
    const getCurrentPosition = vi.fn((_success: PositionCallback, failure: PositionErrorCallback) => failure({ code: 1, message: 'private internal error' } as GeolocationPositionError))
    installBrowser(getCurrentPosition)
    await expect(requestAddressPosition()).rejects.toMatchObject({ code: 'permission_denied', message: expect.stringContaining('permission was denied') })
    expect(getCurrentPosition).toHaveBeenCalledTimes(1)
  })

  it.each([
    { coords: { latitude: NaN, longitude: 3.4, accuracy: 10 }, timestamp: Date.now() },
    { coords: { latitude: 91, longitude: 3.4, accuracy: 10 }, timestamp: Date.now() },
    { coords: { latitude: 6.45, longitude: 181, accuracy: 10 }, timestamp: Date.now() },
    { coords: { latitude: 6.45, longitude: 3.4, accuracy: -1 }, timestamp: Date.now() },
    position(18, Date.now() - 120_000),
    position(18, Date.now() + 60_000),
  ])('rejects invalid, stale or implausibly future browser fixes', async (invalidPosition) => {
    const getCurrentPosition = vi.fn((success: PositionCallback) => success(invalidPosition as GeolocationPosition))
    installBrowser(getCurrentPosition)
    await expect(requestAddressPosition()).rejects.toMatchObject({ code: 'invalid' })
    expect(getCurrentPosition).toHaveBeenCalledTimes(1)
  })

  it('has a watchdog when the browser never replies', async () => {
    vi.useFakeTimers()
    installBrowser(vi.fn())
    const result = requestPosition()
    const assertion = expect(result).rejects.toMatchObject({ code: 'timeout' })
    await vi.advanceTimersByTimeAsync(12_000)
    await assertion
    expect(vi.getTimerCount()).toBe(0)
  })

  it('does not request location for an already cancelled operation', async () => {
    const getCurrentPosition = vi.fn()
    installBrowser(getCurrentPosition)
    const controller = new AbortController()
    controller.abort()
    await expect(requestPosition({ signal: controller.signal })).rejects.toMatchObject({ code: 'aborted' })
    expect(getCurrentPosition).not.toHaveBeenCalled()
  })

  it('cancels pending browser work and ignores a late callback', async () => {
    vi.useFakeTimers()
    let success!: PositionCallback
    installBrowser(vi.fn((callback: PositionCallback) => { success = callback }))
    const controller = new AbortController()
    const result = requestPosition({ signal: controller.signal })
    const assertion = expect(result).rejects.toMatchObject({ code: 'aborted' })
    controller.abort()
    success(position())
    await assertion
    expect(vi.getTimerCount()).toBe(0)
  })

  it('matches native replies and sends explicit accuracy options to the container', async () => {
    const requestNative = vi.fn((requestId: string) => {
      nativeReply('other-request', { latitude: 99 })
      queueMicrotask(() => nativeReply(requestId))
    })
    window.GohezohLocation = { requestPosition: requestNative }
    await expect(requestPosition()).resolves.toMatchObject({ latitude: 4.8, longitude: 7.0, accuracyMetres: 8, source: 'native' })
    expect(requestNative).toHaveBeenCalledWith(expect.any(String), { enableHighAccuracy: true, maximumAge: 0, timeout: 15_000 })
  })

  it.each([{ latitude: null }, { longitude: '7.0' }, { accuracyMetres: null }, { capturedAt: null }, { capturedAt: Date.now() - 120_000 }])('rejects invalid raw native fields without coercion', async (overrides) => {
    window.GohezohLocation = { requestPosition: (requestId) => queueMicrotask(() => nativeReply(requestId, overrides)) }
    await expect(requestPosition()).rejects.toMatchObject({ code: 'invalid' })
  })

  it('includes permission-based high accuracy options in the WebView bridge message', async () => {
    window.ReactNativeWebView = { postMessage: vi.fn((message) => {
      const request = JSON.parse(message)
      expect(request).toMatchObject({ type: 'gohezoh:position:request', options: { enableHighAccuracy: true, maximumAge: 0, timeout: 15_000 } })
      queueMicrotask(() => nativeReply(request.requestId))
    }) }
    await expect(requestPosition()).resolves.toMatchObject({ source: 'native' })
  })

  it('cancels native work, removes its listener and releases its watchdog', async () => {
    vi.useFakeTimers()
    window.GohezohLocation = { requestPosition: vi.fn() }
    const remove = vi.spyOn(window, 'removeEventListener')
    const controller = new AbortController()
    const result = requestPosition({ signal: controller.signal })
    const assertion = expect(result).rejects.toMatchObject({ code: 'aborted' })
    controller.abort()
    await assertion
    expect(remove).toHaveBeenCalledWith('gohezoh:position', expect.any(Function))
    expect(vi.getTimerCount()).toBe(0)
  })
})

describe('requestAddressPosition', () => {
  it('stops immediately for a usable reading', async () => {
    const getCurrentPosition = vi.fn((success: PositionCallback) => success(position(25)))
    installBrowser(getCurrentPosition)
    await expect(requestAddressPosition()).resolves.toMatchObject({ accuracyMetres: 25 })
    expect(getCurrentPosition).toHaveBeenCalledTimes(1)
  })

  it('refines a coarse reading once and returns the better fix', async () => {
    const getCurrentPosition = vi.fn()
      .mockImplementationOnce((success: PositionCallback) => success(position(500)))
      .mockImplementationOnce((success: PositionCallback) => success(position(20)))
    installBrowser(getCurrentPosition)
    await expect(requestAddressPosition()).resolves.toMatchObject({ accuracyMetres: 20 })
    expect(getCurrentPosition).toHaveBeenCalledTimes(2)
  })

  it('keeps a coarse reading honest when refinement is worse', async () => {
    const getCurrentPosition = vi.fn()
      .mockImplementationOnce((success: PositionCallback) => success(position(400)))
      .mockImplementationOnce((success: PositionCallback) => success(position(600)))
    installBrowser(getCurrentPosition)
    await expect(requestAddressPosition()).resolves.toMatchObject({ accuracyMetres: 400 })
    expect(getCurrentPosition).toHaveBeenCalledTimes(2)
  })

  it.each([2, 3])('retries a transient browser error only once', async (code) => {
    const getCurrentPosition = vi.fn()
      .mockImplementationOnce((_success: PositionCallback, failure: PositionErrorCallback) => failure({ code } as GeolocationPositionError))
      .mockImplementationOnce((success: PositionCallback) => success(position(20)))
    installBrowser(getCurrentPosition)
    await expect(requestAddressPosition()).resolves.toMatchObject({ accuracyMetres: 20 })
    expect(getCurrentPosition).toHaveBeenCalledTimes(2)
  })

  it('returns the available coarse fix after a refinement timeout', async () => {
    const getCurrentPosition = vi.fn()
      .mockImplementationOnce((success: PositionCallback) => success(position(500)))
      .mockImplementationOnce((_success: PositionCallback, failure: PositionErrorCallback) => failure({ code: 3 } as GeolocationPositionError))
    installBrowser(getCurrentPosition)
    await expect(requestAddressPosition()).resolves.toMatchObject({ accuracyMetres: 500 })
    expect(getCurrentPosition).toHaveBeenCalledTimes(2)
  })

  it('rejects after two transient failures rather than looping', async () => {
    const getCurrentPosition = vi.fn((_success: PositionCallback, failure: PositionErrorCallback) => failure({ code: 3 } as GeolocationPositionError))
    installBrowser(getCurrentPosition)
    await expect(requestAddressPosition()).rejects.toBeInstanceOf(LocationError)
    expect(getCurrentPosition).toHaveBeenCalledTimes(2)
  })
})
