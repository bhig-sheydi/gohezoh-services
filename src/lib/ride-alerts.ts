import type { SupabaseClient } from '@supabase/supabase-js'

export const validUuid = (value: unknown): value is string => typeof value === 'string'
  && /^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i.test(value)

export async function clearRideAlerts(supabase: SupabaseClient): Promise<void> {
  const native = window.KwikParselNative
  if (!native?.postMessage) return
  try {
    const deviceId = window.localStorage.getItem('kwik-parsel-ride-device-id')
    if (validUuid(deviceId)) await supabase.rpc('unregister_ride_push_device', { p_device_id: deviceId })
  } catch { /* Native delivery is disabled below even if the network is unavailable. */ }
  native.postMessage(JSON.stringify({ type: 'ride:clear' }))
}
