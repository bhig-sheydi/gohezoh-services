import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS' }
const reply = (body: unknown, status = 200) => Response.json(body, { status, headers: cors })
const uuid = (value: unknown) => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (request.method !== 'POST') return reply({ error: 'Method not allowed' }, 405)
  const key = Deno.env.get('GOOGLE_ROUTES_API_KEY')
  if (!key) return reply({ error: 'Road pricing is not configured' }, 503)
  let requestId: unknown
  try { requestId = (await request.json()).requestId } catch { return reply({ error: 'Invalid request' }, 400) }
  if (!uuid(requestId)) return reply({ error: 'Invalid request ID' }, 400)
  const url = Deno.env.get('SUPABASE_URL') ?? ''
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
  const authorization = request.headers.get('authorization') ?? ''
  if (!authorization.startsWith('Bearer ')) return reply({ error: 'Sign in required' }, 401)
  const userClient = createClient(url, anonKey, { global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false } })
  const { data: identity, error: authError } = await userClient.auth.getUser(authorization.slice(7))
  if (authError || !identity.user) return reply({ error: 'Sign in required' }, 401)
  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data: routeRequest, error: readError } = await admin.from('service_requests')
    .select('id,created_by,pickup_city,delivery_city,pickup_latitude,pickup_longitude,delivery_latitude,delivery_longitude')
    .eq('id', requestId).single()
  if (readError || !routeRequest || routeRequest.created_by !== identity.user.id) return reply({ error: 'Request unavailable' }, 403)
  if (routeRequest.pickup_city !== routeRequest.delivery_city) return reply({ error: 'Automatic bike pricing is for local deliveries only' }, 422)
  const { data: existing } = await admin.from('bike_route_prices').select('customer_price_ngn,distance_metres,duration_seconds,estimated_fuel_litres')
    .eq('request_id', requestId).maybeSingle()
  if (existing) return reply(existing)
  const point = (latitude: number, longitude: number) => ({ location: { latLng: { latitude, longitude } } })
  const coordinates = [routeRequest.pickup_latitude,routeRequest.pickup_longitude,routeRequest.delivery_latitude,routeRequest.delivery_longitude]
  if (coordinates.some((value) => typeof value !== 'number' || !Number.isFinite(value))) return reply({ error: 'Choose mapped pickup and drop-off points' }, 422)
  try {
    const response = await fetch('https://routes.googleapis.com/directions/v2:computeRoutes', {
      method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Goog-Api-Key': key,
        'X-Goog-FieldMask': 'routes.distanceMeters,routes.duration' },
      body: JSON.stringify({ origin: point(routeRequest.pickup_latitude,routeRequest.pickup_longitude),
        destination: point(routeRequest.delivery_latitude,routeRequest.delivery_longitude),
        travelMode: 'DRIVE', routingPreference: 'TRAFFIC_UNAWARE' }), signal: AbortSignal.timeout(8000),
    })
    if (!response.ok) return reply({ error: 'Road distance is temporarily unavailable' }, 503)
    const body = await response.json()
    const route = body?.routes?.[0]
    const distance = Number(route?.distanceMeters)
    const seconds = Number.parseFloat(route?.duration)
    if (!Number.isInteger(distance) || !Number.isFinite(seconds) || distance < 100 || seconds < 30)
      return reply({ error: 'No usable road route was found' }, 422)
    const { error } = await admin.rpc('record_bike_route_price', { p_request_id: requestId,
      p_distance_metres: distance, p_duration_seconds: Math.ceil(seconds) })
    if (error) return reply({ error: error.message }, 422)
    const { data: saved, error: savedError } = await admin.from('bike_route_prices')
      .select('customer_price_ngn,distance_metres,duration_seconds,estimated_fuel_litres,company_share_ngn,platform_share_ngn')
      .eq('request_id', requestId).single()
    if (savedError) return reply({ error: 'Could not read the saved price' }, 503)
    return reply(saved)
  } catch (error) {
    console.error('Bike road pricing failed', error)
    return reply({ error: 'Road pricing timed out. Try again shortly.' }, 503)
  }
})
