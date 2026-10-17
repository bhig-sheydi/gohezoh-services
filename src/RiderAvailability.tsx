import { useEffect, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { startRiderTracking } from './lib/rider-tracking'

export default function RiderAvailability({ supabase }: { supabase: SupabaseClient }) {
  const [enabled, setEnabled] = useState(false)
  const [status, setStatus] = useState('Offline')
  useEffect(() => {
    if (!enabled) return
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
  }, [enabled, supabase])
  return <section className="form-card rider-availability" aria-label="Rider availability">
    <div><h2>{enabled && status.startsWith('Online') ? 'On duty' : enabled ? 'Connecting' : 'Off duty'}</h2><p role="status">{status}</p>
      <small>Keep this screen open. Nearby jobs go to your company for bidding.</small></div>
    <button type="button" className="primary-button" onClick={() => {
      setStatus(enabled ? 'Offline' : 'Getting your location…')
      setEnabled(!enabled)
    }}>{enabled ? 'Go offline' : 'Go online'}</button>
  </section>
}
