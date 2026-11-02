import { useEffect, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { startRiderTracking } from './lib/rider-tracking'
import { askNativeRiderStatus, hasNativeRiderTracking, listenNativeRiderStatus, openRiderBackgroundSettings, setNativeRiderDuty, startNativeRiderTracking, stopNativeRiderTracking } from './lib/native-rider'

type LoadState = 'available' | 'almost_full' | 'full'
const loadOptions: { value: LoadState; label: string }[] = [
  { value: 'available', label: 'Available' },
  { value: 'almost_full', label: 'Almost full' },
  { value: 'full', label: 'Full' },
]

export default function RiderAvailability({ supabase }: { supabase: SupabaseClient }) {
  const [enabled, setEnabled] = useState(false)
  const [nativeOnDuty, setNativeOnDuty] = useState(false)
  const [status, setStatus] = useState('Offline')
  const [serverOnline, setServerOnline] = useState<boolean | null>(null)
  const [nativeBusy, setNativeBusy] = useState(false)
  const [loadState, setLoadState] = useState<LoadState | null>(null)
  const [loadBusy, setLoadBusy] = useState(false)
  const [loadError, setLoadError] = useState('')
  const nativeTracking = hasNativeRiderTracking()
  useEffect(() => {
    if (!nativeTracking) return
    const unsubscribe = listenNativeRiderStatus(({ active, onDuty, message }) => {
      setEnabled(active)
      setNativeOnDuty(onDuty)
      if (!active) setServerOnline(null)
      setStatus(message)
      setNativeBusy(false)
    })
    askNativeRiderStatus()
    const timer = window.setInterval(() => { if (!document.hidden) askNativeRiderStatus() }, 10_000)
    return () => { unsubscribe(); window.clearInterval(timer) }
  }, [nativeTracking])
  useEffect(() => {
    let active = true
    void supabase.rpc('my_rider_load_state').then(({ data, error }) => {
      if (!active) return
      if (error) setLoadError(error.message)
      else if (data === 'available' || data === 'almost_full' || data === 'full') setLoadState(data)
    })
    return () => { active = false }
  }, [supabase])
  async function chooseLoadState(next: LoadState) {
    if (loadBusy || next === loadState) return
    setLoadBusy(true); setLoadError('')
    const { data, error } = await supabase.rpc('set_rider_load_state', { p_state: next })
    if (error) setLoadError(error.message)
    else setLoadState(data as LoadState)
    setLoadBusy(false)
  }
  useEffect(() => {
    if (!enabled || nativeTracking) return
    return startRiderTracking({
      report: async (fix) => {
        const { error } = await supabase.rpc('report_rider_position', {
          p_latitude: fix.latitude, p_longitude: fix.longitude,
          p_accuracy_metres: fix.accuracyMetres, p_captured_at: new Date(fix.capturedAt).toISOString(),
        })
        if (error) throw new Error(error.message)
      },
      offline: async () => { await supabase.rpc('stop_rider_availability') },
      status: setStatus, failed: () => setEnabled(false),
    })
  }, [enabled, nativeTracking, supabase])
  useEffect(() => {
    if (!enabled || (nativeTracking && !nativeOnDuty)) return
    let active = true
    const check = async () => {
      if (document.hidden) return
      const { data, error } = await supabase.rpc('my_rider_online')
      if (active) setServerOnline(error ? null : data === true)
    }
    void check()
    const timer = window.setInterval(() => { void check() }, 30_000)
    document.addEventListener('visibilitychange', check)
    return () => { active = false; window.clearInterval(timer); document.removeEventListener('visibilitychange', check) }
  }, [enabled, nativeOnDuty, nativeTracking, supabase])
  async function toggleDuty() {
    setServerOnline(null)
    if (nativeTracking) {
      if (nativeBusy) return
      setNativeBusy(true)
      if (enabled) {
        setNativeRiderDuty(!nativeOnDuty)
        setNativeOnDuty(!nativeOnDuty)
        setStatus(nativeOnDuty ? 'Off duty · location sharing continues' : 'Going on duty…')
        setNativeBusy(false)
      } else {
        const { data, error } = await supabase.auth.getSession()
        if (error || !data.session) { setStatus('Sign in again to go online.'); setNativeBusy(false); return }
        try {
          const { data: token, error: tokenError } = await supabase.rpc('issue_rider_tracking_token')
          if (tokenError || typeof token !== 'string') throw new Error(tokenError?.message || 'Could not start phone tracking.')
          startNativeRiderTracking(token)
          setStatus('Starting phone location…')
        }
        catch (startError) { setStatus(startError instanceof Error ? startError.message : 'Phone location unavailable.'); setNativeBusy(false) }
      }
      return
    }
    setStatus(enabled ? 'Offline' : 'Getting your location…')
    setEnabled(!enabled)
  }
  const heading = nativeTracking && enabled && !nativeOnDuty ? 'Off duty · location shared'
    : enabled && serverOnline === true ? 'On duty'
    : enabled && serverOnline === false ? 'Location paused'
    : enabled || nativeBusy ? 'Connecting' : 'Off duty'
  const message = nativeTracking && enabled && !nativeOnDuty ? status
    : enabled && serverOnline === false
    ? 'No fresh location has reached the server. Check phone GPS and internet.'
    : enabled && serverOnline === null && status.startsWith('Online')
      ? 'Checking that your location is reaching the server…' : status
  return <section className="form-card rider-availability" aria-label="Rider availability">
    <div><h2>{heading}</h2><p role="status">{message}</p>
      <small>{nativeTracking ? <>Phone GPS is shared with your company, including while off duty; active delivery customers can check twice per hour. It may restart after a phone reboot if you enable background location. <a href="/rider-location-terms.html" target="_blank" rel="noreferrer">Rider location terms</a>.</> : 'Keep this screen open. Browser GPS pauses in the background.'}</small></div>
    <button type="button" className="primary-button" disabled={nativeBusy} onClick={() => void toggleDuty()}>{nativeTracking ? nativeOnDuty ? 'Go off duty' : 'Go on duty' : enabled ? 'Go offline' : 'Go online'}</button>
    {nativeTracking && enabled && <button type="button" className="secondary-button" onClick={() => stopNativeRiderTracking()}>Stop sharing location</button>}
    {nativeTracking && <button type="button" className="secondary-button" onClick={openRiderBackgroundSettings}>Allow location after reboot</button>}
    <div className="rider-load-control">
      <strong>Box space</strong>
      <div className="rider-load-options" role="group" aria-label="Box space">
        {loadOptions.map((option) => <button key={option.value} type="button"
          aria-pressed={loadState === option.value} disabled={loadBusy || loadState === null}
          className={`rider-load-option ${option.value === 'full' ? 'rider-load-full' : ''}`}
          onClick={() => void chooseLoadState(option.value)}>{option.label}</button>)}
      </div>
      {loadState === 'full' && <small>New orders are paused. Tracking and current deliveries continue.</small>}
      {loadState === 'almost_full' && <small>Your company will see a warning before bidding on another parcel.</small>}
      {loadError && <p className="error-message" role="alert">{loadError}</p>}
    </div>
  </section>
}
