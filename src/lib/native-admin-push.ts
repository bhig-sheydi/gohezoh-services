const deviceKey = 'kwik-parsel-admin-push-device-id'
const preferenceKey = 'kwik-parsel-admin-push-enabled'

export type NativeAdminPushState = {
  status: 'token' | 'disabled' | 'unavailable' | 'error'
  token?: string
  message: string
}

export function hasNativeAdminPush(): boolean {
  return typeof window.KwikParselNative?.postMessage === 'function'
}

export function nativeAdminPushPreferred(): boolean {
  try { return window.localStorage.getItem(preferenceKey) === '1' }
  catch { return false }
}

export function setNativeAdminPushPreferred(enabled: boolean): void {
  try { window.localStorage.setItem(preferenceKey, enabled ? '1' : '0') }
  catch { /* Notifications still work during this session. */ }
}

export function getNativeAdminPushDeviceId(create = true): string | null {
  try {
    const current = window.localStorage.getItem(deviceKey)
    if (current && /^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i.test(current)) return current
    if (!create) return null
    const deviceId = crypto.randomUUID()
    window.localStorage.setItem(deviceKey, deviceId)
    return deviceId
  } catch { return null }
}

export function requestNativeAdminPush(enable: boolean): void {
  window.KwikParselNative?.postMessage(JSON.stringify({ type: enable ? 'admin:enable-push' : 'admin:push-status' }))
}

export function disableNativeAdminPush(): void {
  window.KwikParselNative?.postMessage(JSON.stringify({ type: 'admin:disable-push' }))
}

export function listenNativeAdminPush(callback: (state: NativeAdminPushState) => void): () => void {
  const listener = (event: Event) => {
    const value = (event as CustomEvent).detail as Partial<NativeAdminPushState> & { type?: string }
    if (value?.type !== 'admin:push-state' || !['token', 'disabled', 'unavailable', 'error'].includes(value.status ?? '')) return
    callback({ status: value.status as NativeAdminPushState['status'], token: value.token,
      message: typeof value.message === 'string' ? value.message : 'Phone alerts are unavailable.' })
  }
  window.addEventListener('kwik-parsel:admin-push', listener)
  return () => window.removeEventListener('kwik-parsel:admin-push', listener)
}
