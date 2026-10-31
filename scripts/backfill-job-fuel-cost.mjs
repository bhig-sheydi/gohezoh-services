import { readFileSync } from 'node:fs'

const PROJECT_REF = 'yejiqfocqmdxjeajoexd'
const CONSUMPTION_L_PER_KM = 0.025
const FUEL_PRICE_NGN_PER_LITRE = 1400
const MAX_JOBS_PER_RUN = 100

export function fuelCostNgn(distanceMetres, consumption = CONSUMPTION_L_PER_KM, price = FUEL_PRICE_NGN_PER_LITRE) {
  if (![distanceMetres, consumption, price].every((value) => Number.isFinite(value) && value >= 0))
    throw new Error('Invalid fuel estimate input')
  return Math.round(distanceMetres / 1000 * consumption * price * 100) / 100
}

export function validPoint(latitude, longitude) {
  return Number.isFinite(latitude) && Number.isFinite(longitude) &&
    Math.abs(latitude) <= 90 && Math.abs(longitude) <= 180
}

export async function googleRoadDistanceMetres(origin, destination, apiKey, fetcher = fetch) {
  if (!apiKey || !validPoint(origin.latitude, origin.longitude) || !validPoint(destination.latitude, destination.longitude))
    throw new Error('Google Routes key and valid coordinates are required')
  const response = await fetcher('https://routes.googleapis.com/directions/v2:computeRoutes', {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'X-Goog-Api-Key': apiKey,
      'X-Goog-FieldMask': 'routes.distanceMeters' },
    body: JSON.stringify({ origin: { location: { latLng: origin } },
      destination: { location: { latLng: destination } }, travelMode: 'DRIVE',
      routingPreference: 'TRAFFIC_UNAWARE' }),
    signal: AbortSignal.timeout(15000),
  })
  if (!response.ok) {
    const body = await response.json().catch(() => ({}))
    throw new Error(`Google Routes HTTP ${response.status}: ${body?.error?.message ?? 'request failed'}`)
  }
  const body = await response.json()
  const distance = body?.routes?.[0]?.distanceMeters
  if (!Number.isFinite(distance) || distance < 0) throw new Error('Google returned no valid driving route')
  return distance
}

function localGoogleKey() {
  const path = new URL('../.env.local', import.meta.url)
  const content = readFileSync(path, 'utf8')
  const line = content.split(/\r?\n/).find((entry) => entry.startsWith('VITE_GOOGLE_MAPS_DEMO_KEY='))
  return line?.slice('VITE_GOOGLE_MAPS_DEMO_KEY='.length).trim()
}

async function sql(query, parameters = [], readOnly = false) {
  const token = process.env.SUPABASE_ACCESS_TOKEN
  if (!token) throw new Error('SUPABASE_ACCESS_TOKEN is required')
  const response = await fetch(`https://api.supabase.com/v1/projects/${PROJECT_REF}/database/query`, {
    method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ query, parameters, read_only: readOnly }), signal: AbortSignal.timeout(20000),
  })
  if (!response.ok) throw new Error(`Supabase SQL HTTP ${response.status}: ${(await response.text()).slice(0, 300)}`)
  return response.json()
}

async function main() {
  const apply = process.argv.includes('--apply')
  const limit = Math.min(MAX_JOBS_PER_RUN, Number(process.argv.find((arg) => arg.startsWith('--limit='))?.split('=')[1] ?? MAX_JOBS_PER_RUN))
  if (!Number.isInteger(limit) || limit < 1) throw new Error('Invalid --limit')
  const apiKey = process.env.GOOGLE_ROUTES_API_KEY || localGoogleKey()
  if (!apiKey) throw new Error('GOOGLE_ROUTES_API_KEY or local demo key is required')
  if (process.argv.includes('--check-google')) {
    const metres = await googleRoadDistanceMetres(
      { latitude: 4.882269, longitude: 7.0096482 },
      { latitude: 4.89, longitude: 7.02 }, apiKey)
    console.log(`Google Routes returned a ${metres} m driving route.`)
    return
  }
  const rows = await sql(`select j.id, j.job_number, r.pickup_latitude, r.pickup_longitude,
    r.delivery_latitude, r.delivery_longitude
    from public.jobs j join public.orders o on o.id = j.order_id
    join public.service_requests r on r.id = o.service_request_id
    left join public.job_fuel_cost_estimates e on e.job_id = j.id
    where e.job_id is null and r.pickup_latitude is not null and r.pickup_longitude is not null
      and r.delivery_latitude is not null and r.delivery_longitude is not null
    order by j.created_at, j.id limit ${limit}`, [], true)
  console.log(`${rows.length} jobs eligible for fuel estimation${apply ? '' : ' (preview; Google route requests still count toward usage)'}`)
  let saved = 0
  for (const row of rows) {
    try {
      const distance = await googleRoadDistanceMetres(
        { latitude: row.pickup_latitude, longitude: row.pickup_longitude },
        { latitude: row.delivery_latitude, longitude: row.delivery_longitude }, apiKey)
      const cost = fuelCostNgn(distance)
      console.log(`${row.job_number}: ${Math.round(distance / 100) / 10} km, estimated fuel ₦${cost}`)
      if (apply) {
        await sql(`insert into public.job_fuel_cost_estimates
          (job_id, estimated_fuel_cost_ngn, fuel_consumption_l_per_km, fuel_price_ngn_per_litre, source)
          values ($1::uuid, $2::numeric, $3::numeric, $4::numeric, 'google_routes_drive')
          on conflict (job_id) do nothing`, [row.id, cost, CONSUMPTION_L_PER_KM, FUEL_PRICE_NGN_PER_LITRE])
        saved++
      }
    } catch (error) {
      console.error(`${row.job_number}: ${error.message}`)
    }
  }
  console.log(`Saved ${saved} estimates.`)
}

if (process.argv[1] && new URL(`file:///${process.argv[1].replaceAll('\\', '/')}`).href === import.meta.url)
  main().catch((error) => { console.error(error.message); process.exitCode = 1 })
