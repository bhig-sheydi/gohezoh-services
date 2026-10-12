export type PositionFix = { latitude: number; longitude: number; accuracyMetres: number; capturedAt: number; source: 'browser' | 'native' }

type NativeReply = { type: 'gohezoh:position:result'; requestId: string; latitude?: number; longitude?: number; accuracyMetres?: number; capturedAt?: number; error?: string }

declare global {
  interface Window {
    GohezohLocation?: { requestPosition: (requestId: string) => void }
    ReactNativeWebView?: { postMessage: (message: string) => void }
  }
}

function validFix(value: PositionFix): boolean {
  return Number.isFinite(value.latitude) && Math.abs(value.latitude) <= 90 &&
    Number.isFinite(value.longitude) && Math.abs(value.longitude) <= 180 &&
    Number.isFinite(value.accuracyMetres) && value.accuracyMetres >= 0 &&
    Number.isFinite(value.capturedAt) && Math.abs(Date.now() - value.capturedAt) <= 60_000
}

function browserPosition(): Promise<PositionFix> {
  return new Promise((resolve, reject) => {
    if (!navigator.geolocation) { reject(new Error('Location is unavailable in this browser.')); return }
    navigator.geolocation.getCurrentPosition(
      (position) => resolve({ latitude: position.coords.latitude, longitude: position.coords.longitude, accuracyMetres: position.coords.accuracy, capturedAt: position.timestamp, source: 'browser' }),
      (error) => reject(new Error(error.message || 'Could not get your location.')),
      { enableHighAccuracy: true, maximumAge: 0, timeout: 12_000 },
    )
  })
}

/** A one-shot GPS request. Native containers reply by page event; browsers use Geolocation. */
export async function requestPosition(): Promise<PositionFix> {
  const native = window.GohezohLocation ?? window.ReactNativeWebView
  if (!native) {
    const fix = await browserPosition()
    if (!validFix(fix)) throw new Error('Location reading is stale or invalid. Try again.')
    return fix
  }
  const requestId = crypto.randomUUID()
  return new Promise((resolve, reject) => {
    const timeout = window.setTimeout(() => finish(new Error('Location request timed out.')), 15_000)
    function finish(result: PositionFix | Error) {
      window.clearTimeout(timeout)
      window.removeEventListener('gohezoh:position', onPosition as EventListener)
      if (result instanceof Error) reject(result)
      else resolve(result)
    }
    function onPosition(event: Event) {
      const reply = (event as CustomEvent<NativeReply>).detail
      if (reply?.type !== 'gohezoh:position:result' || reply.requestId !== requestId) return
      if (reply.error) { finish(new Error(reply.error)); return }
      const fix: PositionFix = { latitude: Number(reply.latitude), longitude: Number(reply.longitude), accuracyMetres: Number(reply.accuracyMetres), capturedAt: Number(reply.capturedAt), source: 'native' }
      finish(validFix(fix) ? fix : new Error('Location reading is stale or invalid. Try again.'))
    }
    window.addEventListener('gohezoh:position', onPosition as EventListener)
    try {
      if (window.GohezohLocation) window.GohezohLocation.requestPosition(requestId)
      else window.ReactNativeWebView?.postMessage(JSON.stringify({ type: 'gohezoh:position:request', requestId }))
    } catch (error) { finish(error instanceof Error ? error : new Error('Location request failed.')) }
  })
}
