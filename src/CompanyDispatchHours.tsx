import { useCallback, useEffect, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import './company-dispatch-hours.css'

type Hours = { closes_at: string | null; source: 'today' | 'registration' | 'unset'; online_riders: number; rough_extra_rides: number | null }

export default function CompanyDispatchHours({ supabase, partnerId, onError, onNotice }: {
  supabase: SupabaseClient; partnerId: string; onError: (message: string) => void; onNotice: (message: string) => void
}) {
  const [hours, setHours] = useState<Hours | null>(null)
  const [todayLagos] = useState(() => new Date(Date.now() + 60 * 60_000).toISOString().slice(0, 10))
  const [saving, setSaving] = useState(false)
  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc('my_company_dispatch_hours', { p_partner: partnerId })
    if (error) onError(error.message)
    else setHours((data as Hours[] | null)?.[0] ?? null)
  }, [supabase, partnerId, onError])
  useEffect(() => { const timer = window.setTimeout(() => { void load() }, 0); return () => window.clearTimeout(timer) }, [load])

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const data = new FormData(event.currentTarget)
    const time = String(data.get('closing_time') ?? '')
    if (!/^\d{2}:\d{2}$/.test(time)) return
    setSaving(true)
    const { error } = await supabase.rpc('set_my_company_closing_time', {
      p_partner: partnerId, p_time: time, p_next_day: data.get('next_day') === 'on',
    })
    if (error) onError(error.message)
    else { onNotice('Today\'s closing time saved. New rider matches will respect it.'); await load() }
    setSaving(false)
  }

  const closeLabel = hours?.closes_at
    ? new Intl.DateTimeFormat('en-NG', { timeZone: 'Africa/Lagos', weekday: 'short', hour: 'numeric', minute: '2-digit' }).format(new Date(hours.closes_at))
    : 'Not set'
  const localClose = hours?.closes_at ? new Date(Date.parse(hours.closes_at) + 60 * 60_000).toISOString() : null
  const nextDay = !!localClose && localClose.slice(0, 10) > todayLagos
  return <section className="company-dispatch-hours form-card" aria-label="Company closing time">
    <div><p className="eyebrow">TODAY'S DISPATCH HOURS</p><h2>Closing time</h2>
      <strong className="company-dispatch-close">{closeLabel}</strong>
      <p>{hours?.source === 'registration' ? 'From registered vehicle hours.' : hours?.source === 'unset' ? 'Set a closing time for reliable matching.' : 'Set by your company.'}</p>
      {hours && <p><strong>{hours.rough_extra_rides ?? '—'}</strong> roughly possible additional rides across {hours.online_riders} online riders.</p>}
      <small>Estimate uses 45 minutes per ride and reserves 20 minutes before closing. Actual routes and traffic vary.</small>
    </div>
    <form key={hours?.closes_at ?? 'unset'} onSubmit={(event) => void save(event)}>
      <label className="field"><span>Change closing time</span><input type="time" name="closing_time" required defaultValue={localClose?.slice(11, 16) ?? '18:00'} /></label>
      <label className="company-dispatch-next"><input type="checkbox" name="next_day" defaultChecked={nextDay} /> Tomorrow</label>
      <button className="secondary-button" disabled={saving}>{saving ? 'Saving…' : 'Save closing time'}</button>
    </form>
  </section>
}
