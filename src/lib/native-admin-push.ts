const deviceKey = 'kwik-parsel-admin-alarm-device-id'
const preferenceKey = 'kwik-parsel-admin-alarm-enabled'

export type NativeAdminPushState = {
  status: 'credentials' | 'enabled' | 'disabled' | 'unavailable' | 'error'
  deviceId?: string
  deviceSecret?: string
  message: string
  lastPollAttemptAt?: number
  lastServerCheckAt?: number
  lastPollOutcome?: string
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
  catch { /* Native status still works during this session. */ }
}

export function getNativeAdminPushDeviceId(create = false): string | null {
  try {
    const current = window.localStorage.getItem(deviceKey)
    if (current && /^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i.test(current)) return current
  } catch { /* Browser storage can be unavailable. */ }
  return create ? crypto.randomUUID() : null
}

export function rememberNativeAdminPushDeviceId(deviceId: string): void {
  if (!/^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i.test(deviceId)) return
  try { window.localStorage.setItem(deviceKey, deviceId) } catch { /* Native retains its own identity. */ }
}

export function requestNativeAdminPush(enable: boolean): void {
  window.KwikParselNative?.postMessage(JSON.stringify({ type: enable ? 'admin:enable-poll' : 'admin:poll-status' }))
}

export function confirmNativeAdminPushRegistration(): void {
  window.KwikParselNative?.postMessage(JSON.stringify({ type: 'admin:poll-registered' }))
}

export function disableNativeAdminPush(): void {
  window.KwikParselNative?.postMessage(JSON.stringify({ type: 'admin:disable-poll' }))
}

export function requestNativeAdminAlarmTest(): void {
  window.KwikParselNative?.postMessage(JSON.stringify({ type: 'admin:test-notification' }))
}

export function openNativeAdminAlarmSettings(): void {
  window.KwikParselNative?.postMessage(JSON.stringify({ type: 'admin:open-notification-settings' }))
}

export function listenNativeAdminPush(callback: (state: NativeAdminPushState) => void): () => void {
  const listener = (event: Event) => {
    const value = (event as CustomEvent).detail as Partial<NativeAdminPushState> & { type?: string }
    if (value?.type !== 'admin:poll-state' || !['credentials', 'enabled', 'disabled', 'unavailable', 'error'].includes(value.status ?? '')) return
    callback({ status: value.status as NativeAdminPushState['status'],
      deviceId: typeof value.deviceId === 'string' ? value.deviceId : undefined,
      deviceSecret: typeof value.deviceSecret === 'string' ? value.deviceSecret : undefined,
      message: typeof value.message === 'string' ? value.message : 'Phone alerts are unavailable.',
      lastPollAttemptAt: typeof value.lastPollAttemptAt === 'number' && Number.isFinite(value.lastPollAttemptAt)
        ? value.lastPollAttemptAt : undefined,
      lastServerCheckAt: typeof value.lastServerCheckAt === 'number' && Number.isFinite(value.lastServerCheckAt)
        ? value.lastServerCheckAt : undefined,
      lastPollOutcome: typeof value.lastPollOutcome === 'string' ? value.lastPollOutcome.slice(0, 100) : undefined })
  }
  window.addEventListener('kwik-parsel:admin-push', listener)
  return () => window.removeEventListener('kwik-parsel:admin-push', listener)
}
