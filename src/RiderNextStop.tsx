type Stop = {
  plan_version: number
  job_id: string
  stop_kind: 'pickup' | 'dropoff'
  latitude: number
  longitude: number
  eta_at: string | null
  estimate_source: 'road' | 'cached_road' | 'idle_approximate'
}

type Job = { job_id: string; job_number: string; pickup_address: string; pickup_city: string; delivery_address: string; delivery_city: string }

export default function RiderNextStop({ stop, jobs }: { stop: Stop | null; jobs: Job[] }) {
  if (!stop) return null
  const job = jobs.find((item) => item.job_id === stop.job_id)
  if (!job) return null
  const pickup = stop.stop_kind === 'pickup'
  const address = pickup ? job.pickup_address : job.delivery_address
  const city = pickup ? job.pickup_city : job.delivery_city
  const eta = stop.eta_at && !Number.isNaN(Date.parse(stop.eta_at))
    ? new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' }).format(new Date(stop.eta_at)) : null
  const approximate = stop.estimate_source === 'idle_approximate'
  return <section className="form-card rider-next-stop" aria-label="Next stop">
    <p className="eyebrow">NEXT STOP · ROUTE {stop.plan_version}</p>
    <h2>{pickup ? 'Collect parcel' : 'Deliver parcel'}</h2>
    <p><strong>{job.job_number}</strong> · {address}, {city}</p>
    {eta && <p>Estimated arrival: {eta}{approximate ? ' (rough estimate)' : ''}</p>}
    <a className="secondary-button" href={`https://www.google.com/maps/search/?api=1&query=${stop.latitude},${stop.longitude}`} target="_blank" rel="noreferrer">Open directions</a>
    <p className="rider-next-stop-note">Use the pickup or delivery code on the job below to complete this stop.</p>
  </section>
}

export type { Stop as RiderRouteStop }
