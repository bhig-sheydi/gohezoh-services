import { LocationError, requestPosition, type PositionFix } from './proximity'

export function metresBetween(a: PositionFix, b: PositionFix) {
  const radians = Math.PI / 180
  const h = Math.sin((b.latitude - a.latitude) * radians / 2) ** 2 +
    Math.cos(a.latitude * radians) * Math.cos(b.latitude * radians) * Math.sin((b.longitude - a.longitude) * radians / 2) ** 2
  return 6371000 * 2 * Math.asin(Math.sqrt(Math.min(1, h)))
}

type Options = {
  report: (fix: PositionFix) => Promise<void>
  offline: () => Promise<void>
  status: (message: string) => void
  failed: () => void
  getPosition?: typeof requestPosition
}

/** Start only following the rider's Go online action. Never persist consent across sessions. */
export function startRiderTracking({ report, offline, status, failed, getPosition = requestPosition }: Options) {
  let stopped = false
  let failures = 0
  let timer: number | undefined
  let controller: AbortController | undefined
  let pending: Promise<void> = Promise.resolve()
  let lastSent: PositionFix | undefined
  let lastSentAt = 0
  let running = false
  const active = () => !document.hidden && navigator.onLine !== false
  const clear = () => { window.clearTimeout(timer); controller?.abort() }
  const clearPresence = () => { pending = pending.catch(() => {}).then(offline).catch(() => {}) }

  async function tick() {
    if (stopped || running || !active()) return
    running = true
    controller = new AbortController()
    try {
      const fix = await getPosition({ signal: controller.signal,
        positionOptions: { enableHighAccuracy: true, maximumAge: 15_000, timeout: 20_000 } })
      if (stopped || !active()) return
      if (fix.accuracyMetres > 100) throw new Error('GPS is too imprecise. Move outdoors and try again.')
      if (!lastSent || Date.now() - lastSentAt >= 60_000 || metresBetween(lastSent, fix) >= 50) {
        pending = pending.catch(() => {}).then(async () => { if (!stopped && active()) await report(fix) })
        await pending
        if (stopped || !active()) return
        lastSent = fix; lastSentAt = Date.now()
      }
      failures = 0
      status(`Online · GPS ±${Math.round(fix.accuracyMetres)} m`)
    } catch (error) {
      if (stopped || !active() || (error instanceof LocationError && error.code === 'aborted')) return
      failures++
      const fatal = error instanceof LocationError && ['permission_denied', 'insecure'].includes(error.code)
      status(error instanceof Error ? error.message : 'Location unavailable. Trying again.')
      if (fatal) { stopped = true; clearPresence(); failed(); return }
      // Let the server expire a stale fix rather than removing a still-valid one.
    } finally {
      running = false
      if (!stopped && active()) timer = window.setTimeout(() => void tick(), failures ? 10_000 : 30_000)
    }
  }
  function visibility() {
    clear()
    if (!active()) {
      lastSent = undefined
      status(document.hidden ? 'Paused while the app is in the background' : 'Offline · waiting for internet')
      // A brief app switch should not remove a valid fix; the server expires it.
    } else if (!stopped && !running) { status('Getting your location…'); void tick() }
  }
  document.addEventListener('visibilitychange', visibility)
  window.addEventListener('online', visibility)
  window.addEventListener('offline', visibility)
  status('Getting your location…')
  void tick()
  return () => {
    stopped = true; clear()
    document.removeEventListener('visibilitychange', visibility)
    window.removeEventListener('online', visibility)
    window.removeEventListener('offline', visibility)
    clearPresence()
  }
}
