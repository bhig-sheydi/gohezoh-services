import { useCallback, useEffect, useRef, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { confirmNativeAdminPushRegistration, disableNativeAdminPush, getNativeAdminPushDeviceId,
  hasNativeAdminPush, listenNativeAdminPush, nativeAdminPushPreferred, openNativeAdminAlarmSettings,
  rememberNativeAdminPushDeviceId, requestNativeAdminAlarmTest, requestNativeAdminPush,
  setNativeAdminPushPreferred } from './lib/native-admin-push'
import AdminCostMonitor from './AdminCostMonitor'
import './AdminTrafficSpikePanel.css'

type TrafficMetric = {
  key: string
  label: string
  current: number
  baseline: number
  unit: string
  status: string
}

type TrafficAlert = {
  id: string
  severity: string
  source: string
  cause: string
  observed: number
  baseline: number
  threshold: number
  detected_at: string
  resolved_at: string | null
  acknowledged_at: string | null
}

type TrafficSnapshot = {
  checked_at: string
  window_minutes: number
  metrics: TrafficMetric[]
  alerts: TrafficAlert[]
  alerts_total?: number
  active_alerts_total?: number
  alerts_page?: number
}

function isTrafficSnapshot(value: unknown): value is TrafficSnapshot {
  if (!value || typeof value !== 'object') return false
  const row = value as Partial<TrafficSnapshot>
  return typeof row.checked_at === 'string' && typeof row.window_minutes === 'number' &&
    Array.isArray(row.metrics) && Array.isArray(row.alerts)
}

function formatted(value: number | null | undefined) {
  return typeof value === 'number' && Number.isFinite(value)
    ? new Intl.NumberFormat('en-NG', { maximumFractionDigits: 1 }).format(value)
    : 'Unavailable'
}

function timestamp(value: string) {
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? 'Unknown time' : new Intl.DateTimeFormat('en-NG', {
    dateStyle: 'medium', timeStyle: 'short',
  }).format(date)
}

function alarmTone(context: AudioContext, sound: AudioBuffer) {
  if (context.state !== 'running') return
  const source = context.createBufferSource()
  source.buffer = sound
  source.connect(context.destination)
  source.start()
}

export default function AdminTrafficSpikePanel({ supabase }: { supabase: SupabaseClient }) {
  const [snapshot, setSnapshot] = useState<TrafficSnapshot | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [soundEnabled, setSoundEnabled] = useState(false)
  const [acknowledging, setAcknowledging] = useState<string | null>(null)
  const [phoneStatus, setPhoneStatus] = useState<'disabled' | 'requesting' | 'enabled' | 'unavailable'>('disabled')
  const [phoneError, setPhoneError] = useState('')
  const [phoneMessage, setPhoneMessage] = useState('')
  const [checkedNow, setCheckedNow] = useState(0)
  const [costRefreshKey, setCostRefreshKey] = useState(0)
  const [costAlarm, setCostAlarm] = useState(false)
  const [alertPage, setAlertPage] = useState(1)
  const requestInFlight = useRef(false)
  const audioContext = useRef<AudioContext | null>(null)
  const audioBuffer = useRef<AudioBuffer | null>(null)

  const load = useCallback(async () => {
    if (requestInFlight.current || document.visibilityState === 'hidden') return
    requestInFlight.current = true
    try {
      const { data, error: rpcError } = await supabase.rpc('admin_traffic_spike_snapshot_page',
        { p_page: alertPage, p_page_size: 8 })
      if (rpcError) throw rpcError
      if (!isTrafficSnapshot(data)) throw new Error('Monitoring returned an invalid response.')
      setSnapshot(data)
      setError('')
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Traffic monitoring is unavailable.')
    } finally {
      requestInFlight.current = false
      setLoading(false)
      setCheckedNow(Date.now())
    }
  }, [supabase, alertPage])

  useEffect(() => {
    const initial = window.setTimeout(() => void load(), 0)
    const timer = window.setInterval(() => void load(), 30_000)
    const onVisibilityChange = () => { if (document.visibilityState === 'visible') void load() }
    document.addEventListener('visibilitychange', onVisibilityChange)
    return () => {
      window.clearTimeout(initial)
      window.clearInterval(timer)
      document.removeEventListener('visibilitychange', onVisibilityChange)
    }
  }, [load])

  useEffect(() => () => { void audioContext.current?.close() }, [])

  useEffect(() => {
    if (!hasNativeAdminPush()) return
    let mounted = true
    const stopListening = listenNativeAdminPush((state) => {
      if (!mounted) return
      if (state.status === 'enabled') {
        setPhoneStatus('enabled'); setPhoneError(''); setPhoneMessage(state.message); return
      }
      if (state.status !== 'credentials') {
        setPhoneStatus(state.status === 'unavailable' ? 'unavailable' : 'disabled')
        setPhoneMessage('')
        if (state.status === 'error' || state.status === 'unavailable') setPhoneError(state.message)
        return
      }
      if (!nativeAdminPushPreferred() || !state.deviceId || !state.deviceSecret) return
      rememberNativeAdminPushDeviceId(state.deviceId)
      void supabase.rpc('admin_register_alarm_device', {
        p_device_id: state.deviceId, p_secret: state.deviceSecret,
      }).then(({ error: registrationError }) => {
        if (!mounted) return
        if (registrationError) { setPhoneStatus('disabled'); setPhoneError(registrationError.message) }
        else { confirmNativeAdminPushRegistration(); setPhoneStatus('enabled'); setPhoneError('') }
      })
    })
    requestNativeAdminPush(false)
    return () => { mounted = false; stopListening() }
  }, [supabase])

  function enablePhonePush() {
    if (!hasNativeAdminPush()) return
    setNativeAdminPushPreferred(true)
    setPhoneError('')
    setPhoneMessage('')
    setPhoneStatus('requesting')
    requestNativeAdminPush(true)
  }

  async function disablePhonePush() {
    setNativeAdminPushPreferred(false)
    disableNativeAdminPush()
    setPhoneStatus('disabled')
    setPhoneMessage('')
    const deviceId = getNativeAdminPushDeviceId(false)
    if (deviceId) {
      const { error: unregisterError } = await supabase.rpc('admin_unregister_alarm_device', { p_device_id: deviceId })
      if (unregisterError) setPhoneError(unregisterError.message)
    }
  }

  const activeAlerts = snapshot?.alerts.filter((alert) => !alert.acknowledged_at && !alert.resolved_at) ?? []
  const activeAlertCount = snapshot?.active_alerts_total ?? activeAlerts.length
  const alertPageCount = Math.max(1, Math.ceil((snapshot?.alerts_total ?? snapshot?.alerts.length ?? 0) / 8))
  const stale = snapshot ? checkedNow - new Date(snapshot.checked_at).getTime() > 180_000 : false
  const activeAlertIds = `${activeAlertCount}:${activeAlerts.map((alert) => alert.id).sort().join(',')}`
  useEffect(() => {
    if (!soundEnabled || (activeAlertCount === 0 && !costAlarm) || (error && !costAlarm) || (stale && !costAlarm)) return
    const ring = () => {
      if (document.visibilityState === 'visible' && audioContext.current && audioBuffer.current)
        alarmTone(audioContext.current, audioBuffer.current)
    }
    ring()
    const timer = window.setInterval(ring, 30_000)
    return () => window.clearInterval(timer)
  }, [soundEnabled, activeAlertIds, activeAlertCount, costAlarm, error, stale])

  async function toggleSound() {
    if (soundEnabled) {
      setSoundEnabled(false)
      await audioContext.current?.close()
      audioContext.current = null
      audioBuffer.current = null
      return
    }
    let context: AudioContext | null = null
    try {
      if (typeof AudioContext === 'undefined') throw new Error('This browser cannot play the alarm.')
      context = new AudioContext()
      await context.resume()
      const response = await fetch('/sounds/admin_alarm.wav', { cache: 'force-cache' })
      if (!response.ok) throw new Error('The alarm sound could not be loaded.')
      const sound = await context.decodeAudioData(await response.arrayBuffer())
      audioContext.current = context
      audioBuffer.current = sound
      setSoundEnabled(true)
    } catch (cause) {
      await context?.close()
      setError(cause instanceof Error ? cause.message : 'The browser could not enable sound.')
    }
  }

  async function acknowledge(id: string) {
    setAcknowledging(id)
    try {
      const { error: rpcError } = await supabase.rpc('admin_acknowledge_traffic_spike', { p_alert_id: id })
      if (rpcError) throw rpcError
      setSnapshot((current) => current && ({
        ...current,
        alerts: current.alerts.map((alert) => alert.id === id ? { ...alert, acknowledged_at: new Date().toISOString() } : alert),
        active_alerts_total: Math.max(0,(current.active_alerts_total ?? current.alerts.filter((item) => !item.acknowledged_at && !item.resolved_at).length)-1),
      }))
      setError('')
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not acknowledge this alert.')
    } finally {
      setAcknowledging(null)
    }
  }

  return <section className="traffic-panel" aria-labelledby="traffic-panel-title">
    <header className="traffic-panel-heading">
      <div><p className="eyebrow">SERVICE HEALTH</p><h2 id="traffic-panel-title">Traffic and spending</h2></div>
      <div className="traffic-panel-actions">
        <button type="button" className="secondary-button" aria-pressed={soundEnabled} onClick={() => void toggleSound()}>{soundEnabled ? 'Mute alarm' : 'Enable alarm'}</button>
        <button type="button" className="secondary-button" onClick={() => { void load(); setCostRefreshKey((value) => value + 1) }}>Refresh</button>
      </div>
    </header>
    {hasNativeAdminPush() && <div className="traffic-phone-alerts">
      <div><strong>Android background alarm</strong><small>{phoneStatus === 'enabled' ? phoneMessage || 'Enabled. Android checks about every 15 minutes; battery saving may delay alerts.'
        : phoneStatus === 'requesting' ? 'Connecting phone notifications...'
          : 'Enable alerts for spikes and the 10% margin threshold, including with the screen off.'}</small></div>
      <button type="button" className="secondary-button"
        disabled={phoneStatus === 'requesting'}
        onClick={() => phoneStatus === 'enabled' ? void disablePhonePush() : enablePhonePush()}>
        {phoneStatus === 'enabled' ? 'Disable phone alerts' : 'Enable phone alerts'}
      </button>
      {phoneStatus === 'enabled' && <button type="button" className="secondary-button"
        onClick={() => { setPhoneMessage('Test alarm scheduled. Lock your phone now.'); requestNativeAdminAlarmTest() }}>
        Test phone alarm
      </button>}
      <button type="button" className="secondary-button" onClick={openNativeAdminAlarmSettings}>Sound settings</button>
    </div>}
    {phoneError && <p className="traffic-monitor-error" role="alert">{phoneError}</p>}
    {error && <p className="traffic-monitor-error" role="alert">Monitoring unavailable: {error}. Last successful figures may be stale.</p>}
    {stale && <p className="traffic-monitor-error" role="alert">Traffic readings are more than 3 minutes old. The sampler may be delayed.</p>}
    <h3 className="traffic-subheading">Traffic spikes</h3>
    {loading && !snapshot ? <p className="traffic-monitor-empty">Checking traffic...</p> : !snapshot ? <p className="traffic-monitor-empty">No traffic readings available.</p> : <>
      <div className={`traffic-health ${activeAlertCount > 0 ? 'traffic-health-alert' : ''}`} role="status" aria-live="polite">
        <strong>{stale ? 'Monitoring is delayed' : activeAlertCount > 0 ? `${activeAlertCount} spike${activeAlertCount === 1 ? '' : 's'} need attention` : 'No active spikes detected'}</strong>
        <span>Last check: {timestamp(snapshot.checked_at)} | {formatted(snapshot.window_minutes)}-minute window</span>
      </div>
      <div className="traffic-metrics">
        {snapshot.metrics.map((metric) => <div className={`traffic-metric traffic-metric-${metric.status === 'critical' ? 'critical' : metric.status === 'warning' ? 'warning' : 'normal'}`} key={metric.key}>
          <span>{metric.label}</span><strong>{formatted(metric.current)} <small>{metric.unit}</small></strong>
          <small>Typical: {formatted(metric.baseline)} {metric.unit}</small>
        </div>)}
      </div>
      <div className="traffic-alert-list">
        <h3>Recent alerts</h3>
        {snapshot.alerts.length === 0 ? <p className="traffic-monitor-empty">No spikes recorded in this period.</p> : snapshot.alerts.map((alert) => <article className={`traffic-alert traffic-alert-${alert.severity === 'critical' ? 'critical' : 'warning'} ${alert.acknowledged_at || alert.resolved_at ? 'traffic-alert-acknowledged' : ''}`} key={alert.id}>
          <div><div className="traffic-alert-title"><strong>{alert.source.replaceAll('_', ' ')}</strong><span>{alert.resolved_at ? 'Resolved' : alert.acknowledged_at ? 'Acknowledged' : alert.severity === 'critical' ? 'Critical spike' : 'Spike'}</span></div>
            <p><b>Likely cause:</b> {alert.cause}</p>
            <small>{formatted(alert.observed)} observed | {formatted(alert.baseline)} typical | alarm level {formatted(alert.threshold)} | {timestamp(alert.detected_at)}</small>
          </div>
          {!alert.acknowledged_at && !alert.resolved_at && <button type="button" className="secondary-button" disabled={acknowledging === alert.id} onClick={() => void acknowledge(alert.id)}>Acknowledge</button>}
        </article>)}
        {alertPageCount > 1 && <nav className="traffic-alert-pagination" aria-label="Spike alert pages">
          <button type="button" className="secondary-button" disabled={alertPage <= 1} onClick={() => setAlertPage((page) => page-1)}>Previous</button>
          <span>Page {alertPage} of {alertPageCount}</span>
          <button type="button" className="secondary-button" disabled={alertPage >= alertPageCount} onClick={() => setAlertPage((page) => page+1)}>Next</button>
        </nav>}
      </div>
    </>}
    <AdminCostMonitor supabase={supabase} refreshKey={costRefreshKey} onMarginAlarm={setCostAlarm} />
    <p className="traffic-monitor-footnote">Browser sound works while this dashboard is open. Android background alerts require phone notifications and a network connection.</p>
  </section>
}
