import { readFileSync } from 'node:fs'

const token = process.env.SUPABASE_ACCESS_TOKEN
const apiKey = process.env.GOOGLE_ROUTES_API_KEY || readFileSync(new URL('../.env.local', import.meta.url), 'utf8')
  .split(/\r?\n/).find((line) => line.startsWith('VITE_GOOGLE_MAPS_DEMO_KEY='))?.split('=')[1]
if (!token || !apiKey) throw new Error('Supabase token and Google Routes key are required')

const query = `select j.job_number, r.pickup_address, r.delivery_address,
  r.pickup_latitude, r.pickup_longitude, r.delivery_latitude, r.delivery_longitude
  from public.jobs j join public.orders o on o.id=j.order_id
  join public.service_requests r on r.id=o.service_request_id order by j.job_number`
const result = await fetch('https://api.supabase.com/v1/projects/yejiqfocqmdxjeajoexd/database/query', {
  method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
  body: JSON.stringify({ query, read_only: true }), signal: AbortSignal.timeout(20000),
})
if (!result.ok) throw new Error(`Database HTTP ${result.status}`)
const jobs = await result.json()
const routes = new Map()
for (const job of jobs) {
  const key = [job.pickup_latitude, job.pickup_longitude, job.delivery_latitude, job.delivery_longitude].join(',')
  if (routes.has(key)) continue
  const response = await fetch('https://routes.googleapis.com/directions/v2:computeRoutes', {
    method: 'POST', headers: { 'content-type': 'application/json', 'X-Goog-Api-Key': apiKey,
      'X-Goog-FieldMask': 'routes.distanceMeters,routes.duration,routes.legs.steps.navigationInstruction.instructions' },
    body: JSON.stringify({ origin: { location: { latLng: { latitude: job.pickup_latitude, longitude: job.pickup_longitude } } },
      destination: { location: { latLng: { latitude: job.delivery_latitude, longitude: job.delivery_longitude } } },
      travelMode: 'DRIVE', routingPreference: 'TRAFFIC_UNAWARE', languageCode: 'en' }),
    signal: AbortSignal.timeout(15000),
  })
  if (!response.ok) throw new Error(`Google Routes HTTP ${response.status}`)
  const data = await response.json()
  const route = data.routes?.[0]
  routes.set(key, route ? { distance_km: route.distanceMeters / 1000,
    minutes: Math.round(Number.parseFloat(route.duration) / 60),
    steps: route.legs?.flatMap((leg) => leg.steps?.map((step) => step.navigationInstruction?.instructions).filter(Boolean) ?? []) ?? [] } : null)
}
for (const job of jobs) {
  const key = [job.pickup_latitude, job.pickup_longitude, job.delivery_latitude, job.delivery_longitude].join(',')
  const maps = new URL('https://www.google.com/maps/dir/')
  maps.searchParams.set('api', '1')
  maps.searchParams.set('origin', `${job.pickup_latitude},${job.pickup_longitude}`)
  maps.searchParams.set('destination', `${job.delivery_latitude},${job.delivery_longitude}`)
  maps.searchParams.set('travelmode', 'driving')
  console.log(JSON.stringify({ job: job.job_number, pickup: job.pickup_address, dropoff: job.delivery_address,
    ...routes.get(key), maps: maps.toString() }))
}
