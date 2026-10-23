export type PositionFix = { latitude: number; longitude: number; accuracyMetres: number; capturedAt: number; source: 'browser' | 'native' }
export type LocationErrorCode = 'permission_denied' | 'unavailable' | 'timeout' | 'invalid' | 'aborted' | 'insecure'
export type LocationRequestOptions = { signal?: AbortSignal; positionOptions?: PositionOptions }

export class LocationError extends Error {
  readonly code: LocationErrorCode

  constructor(code: LocationErrorCode, message: string) {
    super(message)
    this.name = 'LocationError'
    this.code = code
  }
}

type NativeReply = { type: 'gohezoh:position:result'; requestId: string; latitude?: unknown; longitude?: unknown; accuracyMetres?: unknown; capturedAt?: unknown; error?: string; errorCode?: LocationErrorCode | number }
const browserOptions: PositionOptions = { enableHighAccuracy: true, maximumAge: 0, timeout: 12_000 }
const nativeOptions: PositionOptions = { ...browserOptions, timeout: 15_000 }

declare global {
  interface Window {
    GohezohLocation?: { requestPosition?: (requestId: string, options?: PositionOptions) => void; postMessage?: (message: string) => void }
    ReactNativeWebView?: { postMessage: (message: string) => void }
  }
}

function validFix(value: { latitude?: unknown; longitude?: unknown; accuracyMetres?: unknown; capturedAt?: unknown }, source: PositionFix['source']): PositionFix | null {
  const { latitude, longitude, accuracyMetres, capturedAt } = value
  if (typeof latitude !== 'number' || !Number.isFinite(latitude) || Math.abs(latitude) > 90 ||
      typeof longitude !== 'number' || !Number.isFinite(longitude) || Math.abs(longitude) > 180 ||
      typeof accuracyMetres !== 'number' || !Number.isFinite(accuracyMetres) || accuracyMetres < 0 ||
      typeof capturedAt !== 'number' || !Number.isFinite(capturedAt) ||
      Date.now() - capturedAt > 60_000 || capturedAt - Date.now() > 5_000) return null
  return { latitude, longitude, accuracyMetres, capturedAt, source }
}

function invalidReading(): LocationError {
  return new LocationError('invalid', 'Location reading is stale or invalid. Try again.')
}

function aborted(): LocationError {
  return new LocationError('aborted', 'Location request was cancelled.')
}

function deviceError(code?: number | LocationErrorCode): LocationError {
  if (code === 1 || code === 'permission_denied') return new LocationError('permission_denied', 'Location permission was denied. Allow location in your browser or device settings, or enter the address manually.')
  if (code === 3 || code === 'timeout') return new LocationError('timeout', 'Location request timed out. Try again or enter the address manually.')
  return new LocationError('unavailable', 'Your device could not provide a location. Try again or enter the address manually.')
}

function browserPosition({ signal, positionOptions = browserOptions }: LocationRequestOptions): Promise<PositionFix> {
  if (signal?.aborted) return Promise.reject(aborted())
  if (window.isSecureContext === false) return Promise.reject(new LocationError('insecure', 'Location access requires HTTPS. Open the secure app or enter the address manually.'))
  if (!navigator.geolocation) return Promise.reject(deviceError('unavailable'))
  return new Promise((resolve, reject) => {
    let settled = false
    const timer = window.setTimeout(() => finish(deviceError('timeout')), positionOptions.timeout)
    const onAbort = () => finish(aborted())
    function finish(result: PositionFix | LocationError) {
      if (settled) return
      settled = true
      window.clearTimeout(timer)
      signal?.removeEventListener('abort', onAbort)
      if (result instanceof LocationError) reject(result)
      else resolve(result)
    }
    signal?.addEventListener('abort', onAbort, { once: true })
    try {
      navigator.geolocation.getCurrentPosition(
        (position) => finish(validFix({ latitude: position?.coords?.latitude, longitude: position?.coords?.longitude, accuracyMetres: position?.coords?.accuracy, capturedAt: position?.timestamp }, 'browser') ?? invalidReading()),
        (error) => finish(deviceError(error.code)),
        positionOptions,
      )
    } catch {
      finish(deviceError('unavailable'))
    }
  })
}

/** Call only after a user action. Browser permission controls and the native container authorize location access. */
export function requestPosition(options: LocationRequestOptions = {}): Promise<PositionFix> {
  if (options.signal?.aborted) return Promise.reject(aborted())
  if (!window.GohezohLocation && !window.ReactNativeWebView) return browserPosition(options)
  const requestId = crypto.randomUUID()
  return new Promise((resolve, reject) => {
    let settled = false
    const timer = window.setTimeout(() => finish(deviceError('timeout')), nativeOptions.timeout)
    const onAbort = () => finish(aborted())
    function finish(result: PositionFix | LocationError) {
      if (settled) return
      settled = true
      window.clearTimeout(timer)
      options.signal?.removeEventListener('abort', onAbort)
      window.removeEventListener('gohezoh:position', onPosition as EventListener)
      if (result instanceof LocationError) reject(result)
      else resolve(result)
    }
    function onPosition(event: Event) {
      const reply = (event as CustomEvent<NativeReply>).detail
      if (reply?.type !== 'gohezoh:position:result' || reply.requestId !== requestId) return
      if (reply.error || reply.errorCode !== undefined) { finish(deviceError(reply.errorCode)); return }
      finish(validFix(reply, 'native') ?? invalidReading())
    }
    options.signal?.addEventListener('abort', onAbort, { once: true })
    window.addEventListener('gohezoh:position', onPosition as EventListener)
    try {
      if (window.GohezohLocation?.postMessage) window.GohezohLocation.postMessage(JSON.stringify({ type: 'position:request', requestId }))
      else if (window.GohezohLocation?.requestPosition) window.GohezohLocation.requestPosition(requestId, nativeOptions)
      else window.ReactNativeWebView?.postMessage(JSON.stringify({ type: 'gohezoh:position:request', requestId, options: nativeOptions }))
    } catch {
      finish(deviceError('unavailable'))
    }
  })
}

/** At most two fresh, sequential readings; a coarse fix remains a coarse fix and can seed manual map correction. */
export async function requestAddressPosition(options: LocationRequestOptions = {}): Promise<PositionFix> {
  let best: PositionFix | undefined
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const fix = await requestPosition(options)
      if (!best || fix.accuracyMetres < best.accuracyMetres) best = fix
      if (best.accuracyMetres <= 50) return best
    } catch (error) {
      if (!(error instanceof LocationError) || !['timeout', 'unavailable'].includes(error.code)) throw error
      if (attempt === 1) {
        if (best) return best
        throw error
      }
    }
  }
  return best!
}
