import { useEffect, useRef, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { validUuid } from './lib/ride-alerts'

type Kind = 'customer' | 'company' | 'rider'
type RidePushEvent = { type?: string; available?: boolean; registeredUserId?: string; deviceId?: string; fcmToken?: string }
export default function RideAlerts({ supabase, userId, kind }: {
  supabase: SupabaseClient; userId: string; kind: Kind
}) {
  const supported = typeof window.KwikParselNative?.postMessage === 'function'
  const [enabled, setEnabled] = useState(false)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')
  const refreshed = useRef(false)

  useEffect(() => {
    const native = window.KwikParselNative
    if (!native?.postMessage) return
    const listener = (event: Event) => {
      const detail = (event as CustomEvent<RidePushEvent>).detail
      if (detail?.type === 'ride:status') {
        const active = detail.registeredUserId === userId && detail.available === true
        setEnabled(active)
        if (active && !refreshed.current) {
          refreshed.current = true
          native.postMessage(JSON.stringify({ type: 'ride:register' }))
        }
      }
      if (detail?.type === 'ride:token' && validUuid(detail.deviceId)
        && typeof detail.fcmToken === 'string') {
        setBusy(true)
        try { window.localStorage.setItem('kwik-parsel-ride-device-id', detail.deviceId) }
        catch { /* Native device identity remains stable. */ }
        void supabase.rpc('register_ride_push_device', {
          p_device_id: detail.deviceId, p_token: detail.fcmToken, p_kind: kind,
        }).then(({ error }) => {
          if (error) { setMessage(error.message); setEnabled(false) }
          else {
            native.postMessage(JSON.stringify({ type: 'ride:registered', userId }))
            setEnabled(true); setMessage('')
          }
          setBusy(false)
        })
      }
    }
    window.addEventListener('kwik-parsel:ride-push', listener)
    native.postMessage(JSON.stringify({ type: 'ride:status' }))
    return () => window.removeEventListener('kwik-parsel:ride-push', listener)
  }, [kind, supabase, userId])

  if (!supported) return null
  return <div className="ride-alert-control">
    <button type="button" className="secondary-button" disabled={busy || enabled}
      onClick={() => { setBusy(true); setMessage(''); window.KwikParselNative?.postMessage(JSON.stringify({ type: 'ride:register' }));
        window.setTimeout(() => setBusy(false), 8000) }}>
      {enabled ? 'Phone ride alerts on' : busy ? 'Enabling alerts…' : 'Enable phone ride alerts'}
    </button>
    {message && <small role="alert">{message}</small>}
  </div>
}
