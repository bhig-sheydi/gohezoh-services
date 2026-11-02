export type NativeRiderState = { active: boolean; onDuty: boolean; message: string }
type NativeRiderEvent = { type: 'rider:status'; active: boolean; onDuty?: boolean; message: string }

declare global {
  interface Window {
    KwikParselNative?: { postMessage: (message: string) => void }
  }
}

export function hasNativeRiderTracking(): boolean {
  return typeof window.KwikParselNative?.postMessage === 'function'
}

function send(message: object) {
  window.KwikParselNative?.postMessage(JSON.stringify(message))
}

export function askNativeRiderStatus() { send({ type: 'rider:status' }) }
export function openRiderBackgroundSettings() { send({ type: 'rider:background-settings' }) }

export function startNativeRiderTracking(trackingToken: string) {
  if (!hasNativeRiderTracking()) throw new Error('The phone location service is unavailable.')
  send({
    type: 'rider:start',
    trackingToken,
  })
}

export function stopNativeRiderTracking() { send({ type: 'rider:stop' }) }
export function setNativeRiderDuty(onDuty: boolean) { send({ type: 'rider:set-duty', onDuty }) }

export function listenNativeRiderStatus(callback: (state: NativeRiderState) => void): () => void {
  const listener = (event: Event) => {
    const detail = (event as CustomEvent<NativeRiderEvent>).detail
    if (detail?.type === 'rider:status' && typeof detail.active === 'boolean' && typeof detail.message === 'string') {
      callback({ active: detail.active, onDuty: detail.onDuty ?? detail.active, message: detail.message })
    }
  }
  window.addEventListener('kwik-parsel:native', listener)
  return () => window.removeEventListener('kwik-parsel:native', listener)
}
