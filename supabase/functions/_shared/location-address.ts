/** Geoapify adapter. The application never stores request coordinates or address searches here.
 * Documentation: https://apidocs.geoapify.com/docs/geocoding/reverse-geocoding/
 * https://apidocs.geoapify.com/docs/geocoding/forward-geocoding/
 * https://apidocs.geoapify.com/docs/maps/map-tiles/
 */
export type LocationAddressResult = {
  address: string
  city: string
  state: string
  latitude: number
  longitude: number
  specificity: 'building' | 'street' | 'area'
  resultType: string
  distanceMetres: number | null
  confidence: number | null
}

type Action =
  | { action: 'reverse'; latitude: number; longitude: number }
  | { action: 'search'; text: string }
  | { action: 'suggest'; text: string }
  | { action: 'nearby_suggest'; text: string; kind: 'street' | 'amenity'; latitude: number; longitude: number }
  | { action: 'nearby_places'; latitude: number; longitude: number; street: string }
  | { action: 'map'; latitude: number; longitude: number; zoom: number }
  | { action: 'tile'; z: number; x: number; y: number }

type Dependencies = {
  apiKey: string | undefined
  authenticate: (bearer: string) => Promise<string | null>
  fetcher?: typeof fetch
  productionOrigin?: string
  now?: () => number
  upstreamTimeoutMs?: number
}

class LocationError extends Error {
  constructor(readonly status: number, readonly code: string, message: string, readonly retryAfter?: number) {
    super(message)
  }
}

const MAX_REQUEST_BYTES = 2048
const WINDOW_MS = 60_000
const MAX_RATE_ENTRIES = 2000
const resultTypes = new Set(['unknown', 'amenity', 'building', 'street', 'suburb', 'district', 'postcode', 'city', 'county', 'state', 'country'])
const finite = (value: unknown): value is number => typeof value === 'number' && Number.isFinite(value)
const validCoordinates = (latitude: unknown, longitude: unknown): boolean =>
  finite(latitude) && finite(longitude) && Math.abs(latitude) <= 90 && Math.abs(longitude) <= 180
const object = (value: unknown): value is Record<string, unknown> => !!value && typeof value === 'object' && !Array.isArray(value)

function parseAction(body: unknown): Action {
  if (!object(body)) throw new LocationError(400, 'invalid_request', 'A valid location request is required.')
  if (body.action === 'reverse' && validCoordinates(body.latitude, body.longitude)) {
    return { action: 'reverse', latitude: body.latitude as number, longitude: body.longitude as number }
  }
  if ((body.action === 'search' || body.action === 'suggest') && typeof body.text === 'string') {
    const text = body.text.trim()
    if (text.length >= 3 && text.length <= 300 && !Array.from(text).some(character => character.charCodeAt(0) < 32 || character.charCodeAt(0) === 127)) return { action: body.action, text }
  }
  if (body.action === 'nearby_suggest' && typeof body.text === 'string' && (body.kind === 'street' || body.kind === 'amenity') && validCoordinates(body.latitude, body.longitude)) {
    const text = body.text.trim()
    if (text.length >= 2 && text.length <= 120 && !Array.from(text).some(character => character.charCodeAt(0) < 32 || character.charCodeAt(0) === 127))
      return { action: 'nearby_suggest', text, kind: body.kind, latitude: body.latitude as number, longitude: body.longitude as number }
  }
  if (body.action === 'nearby_places' && validCoordinates(body.latitude, body.longitude) && typeof body.street === 'string' && body.street.trim().length >= 2 && body.street.length <= 120)
    return { action: 'nearby_places', latitude: body.latitude as number, longitude: body.longitude as number, street: body.street.trim() }
  if (body.action === 'map' && validCoordinates(body.latitude, body.longitude) && Number.isInteger(body.zoom) && body.zoom >= 14 && body.zoom <= 19)
    return { action: 'map', latitude: body.latitude as number, longitude: body.longitude as number, zoom: body.zoom as number }
  if (body.action === 'tile' && Number.isInteger(body.z) && Number.isInteger(body.x) && Number.isInteger(body.y)) {
    const z = body.z as number, x = body.x as number, y = body.y as number
    // Geoapify supports 0..20; the correction map intentionally stops at zoom 19.
    if (z >= 0 && z <= 19 && x >= 0 && y >= 0 && x < 2 ** z && y < 2 ** z) return { action: 'tile', z, x, y }
  }
  throw new LocationError(400, 'invalid_request', 'Check the address, coordinates or map tile and try again.')
}

async function limitedBytes(response: Response | Request, maximum: number): Promise<Uint8Array<ArrayBuffer>> {
  const advertisedLength = Number(response.headers.get('Content-Length'))
  if (advertisedLength > maximum) throw new LocationError(413, 'request_too_large', 'The location request is too large.')
  const reader = response.body?.getReader()
  if (!reader) throw new LocationError(400, 'invalid_request', 'The location request is empty.')
  const chunks: Uint8Array[] = []
  let length = 0
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => {
        void reader.cancel().catch(() => {})
        reject(new LocationError(408, 'request_timeout', 'The location request timed out. Try again.'))
      }, 8000)
    })
    await Promise.race([(async () => {
      for (;;) {
        const { done, value } = await reader.read()
        if (done) break
        length += value.length
        if (length > maximum) {
          void reader.cancel().catch(() => {})
          throw new LocationError(413, 'request_too_large', 'The location request is too large.')
        }
        chunks.push(value)
      }
    })(), timeout])
  } finally {
    clearTimeout(timer)
    reader.releaseLock()
  }
  const bytes = new Uint8Array(length)
  let offset = 0
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length }
  return bytes
}

function normalizeResults(payload: unknown): LocationAddressResult[] {
  if (!object(payload) || !Array.isArray(payload.results)) throw new Error('invalid schema')
  if (!payload.results.length) throw new LocationError(404, 'address_not_found', 'No mapped address was found. Enter your address manually or adjust the pin.')
  return payload.results.map(normalizeOneResult)
}

function normalizeOneResult(result: unknown): LocationAddressResult {
  if (!object(result) || !validCoordinates(result.lat, result.lon)) throw new Error('invalid coordinates')
  for (const key of ['address_line1', 'formatted', 'city', 'state', 'street', 'housenumber', 'result_type']) {
    if (result[key] !== undefined && (typeof result[key] !== 'string' || (result[key] as string).length > 1000)) throw new Error('invalid field')
  }
  const address = String(result.address_line1 || result.formatted || '').trim()
  const resultType = String(result.result_type || 'unknown')
  if (!address || !resultTypes.has(resultType)) throw new Error('invalid address')
  const distance = result.distance ?? null
  if (distance !== null && (!finite(distance) || distance < 0)) throw new Error('invalid distance')
  if (result.rank !== undefined && !object(result.rank)) throw new Error('invalid rank')
  const confidence = object(result.rank) ? result.rank.confidence ?? null : null
  if (confidence !== null && (!finite(confidence) || confidence < 0 || confidence > 1)) throw new Error('invalid confidence')
  return {
    address,
    city: String(result.city || '').trim(),
    state: String(result.state || '').trim(),
    latitude: result.lat as number,
    longitude: result.lon as number,
    // Specificity describes map data, never device accuracy or proof of occupancy.
    specificity: resultType === 'building' && !!result.housenumber ? 'building' : result.street || resultType === 'street' ? 'street' : 'area',
    resultType,
    distanceMetres: distance as number | null,
    confidence: confidence as number | null,
  }
}

function streetKey(value: string): string {
  return value.toLowerCase().replace(/\broad\b|\brd\b/g, 'road').replace(/\bstreet\b|\bst\b/g, 'street').replace(/\bavenue\b|\bave\b/g, 'avenue').replace(/[^a-z0-9]/g, '')
}

function normalizeNearbyPlaces(payload: unknown, street: string): LocationAddressResult[] {
  if (!object(payload) || !Array.isArray(payload.features)) throw new Error('invalid places schema')
  const selectedStreet = streetKey(street)
  return payload.features.slice(0, 30).flatMap((feature: unknown) => {
    if (!object(feature) || !object(feature.properties)) return []
    const item = feature.properties
    if (!validCoordinates(item.lat, item.lon) || typeof item.name !== 'string' || !item.name.trim() || item.name.length > 160 ||
      typeof item.street !== 'string' || streetKey(item.street) !== selectedStreet) return []
    return [{ address: item.name.trim(), city: typeof item.city === 'string' ? item.city : '', state: typeof item.state === 'string' ? item.state : '',
      latitude: item.lat as number, longitude: item.lon as number, specificity: 'area' as const, resultType: 'amenity',
      distanceMetres: finite(item.distance) && item.distance >= 0 ? item.distance : null, confidence: null }]
  }).slice(0, 12)
}

/** In-memory counters are best-effort per isolate, not a distributed quota guarantee.
 * Only user identifiers, counts and expiry times are retained; at most 2000 entries/minute.
 */
export function createLocationAddressHandler(dependencies: Dependencies) {
  const fetcher = dependencies.fetcher ?? fetch
  const now = dependencies.now ?? Date.now
  const origins = new Set([dependencies.productionOrigin || 'https://gohezoh-services.vercel.app', 'http://localhost:3000', 'http://localhost:5173'])
  const counters = new Map<string, { expires: number; addresses: number; tiles: number; maps: number }>()

  async function upstream(url: URL): Promise<Response> {
    for (let attempt = 0; attempt < 2; attempt++) {
      const controller = new AbortController()
      const timer = setTimeout(() => controller.abort(), dependencies.upstreamTimeoutMs ?? 8000)
      try {
        const accept = url.pathname.startsWith('/v1/staticmap') ? 'image/jpeg' : url.hostname === 'maps.geoapify.com' ? 'image/png' : 'application/json'
        const response = await fetcher(url, { signal: controller.signal, redirect: 'error', headers: { Accept: accept } })
        if (response.status >= 500 && attempt === 0) { await response.body?.cancel(); continue }
        if (!response.ok) {
          await response.body?.cancel()
          return new Response(null, { status: response.status, headers: response.headers })
        }
        // The fetch abort controller remains active while consuming the bounded body.
        const maximum = url.hostname === 'maps.geoapify.com' ? 512 * 1024 : url.pathname === '/v2/places' ? 128 * 1024 : 64 * 1024
        const bytes = await limitedBytes(response, maximum)
        return new Response(bytes, { status: response.status, headers: response.headers })
      } catch (error) {
        if (error instanceof LocationError) throw new LocationError(502, 'invalid_response', 'The address service returned an invalid response. Enter the address manually.')
        if (attempt === 1) throw new LocationError(503, 'service_unavailable', 'The address service is unavailable. Enter the address manually or try again later.')
      } finally { clearTimeout(timer) }
    }
    throw new LocationError(503, 'service_unavailable', 'The address service is unavailable. Try again later.')
  }

  return async (request: Request): Promise<Response> => {
    const origin = request.headers.get('Origin')
    const headers = new Headers({
      'Cache-Control': 'no-store', Vary: 'Origin', 'X-Content-Type-Options': 'nosniff',
      'Access-Control-Allow-Headers': 'authorization, apikey, x-client-info, content-type',
      'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Access-Control-Expose-Headers': 'Retry-After, X-Image-Type',
    })
    if (origin && origins.has(origin)) headers.set('Access-Control-Allow-Origin', origin)
    const json = (value: unknown, status: number) => Response.json(value, { status, headers })
    try {
      if (origin && !origins.has(origin)) throw new LocationError(403, 'origin_denied', 'This site cannot use the address service.')
      if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers })
      if (request.method !== 'POST') throw new LocationError(405, 'method_not_allowed', 'Use POST for location requests.')
      const authorization = request.headers.get('Authorization')
      if (!authorization || !/^Bearer \S+$/i.test(authorization)) throw new LocationError(401, 'sign_in_required', 'Sign in to find an address.')
      let userId: string | null
      try { userId = await dependencies.authenticate(authorization) } catch { throw new LocationError(503, 'auth_unavailable', 'Session verification is unavailable. Try again later.') }
      if (!userId) throw new LocationError(401, 'invalid_session', 'Your session has expired. Sign in again.')
      if (!dependencies.apiKey?.trim()) throw new LocationError(503, 'not_configured', 'The address service is not configured. Enter your address manually.')
      if (!request.headers.get('Content-Type')?.toLowerCase().startsWith('application/json')) throw new LocationError(415, 'invalid_content_type', 'Send the location request as JSON.')
      let body: unknown
      try { body = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(await limitedBytes(request, MAX_REQUEST_BYTES))) }
      catch (error) {
        if (error instanceof LocationError) throw error
        throw new LocationError(400, 'invalid_request', 'The location request is not valid JSON.')
      }
      const action = parseAction(body)
      const time = now()
      for (const [key, value] of counters) if (value.expires <= time) counters.delete(key)
      let count = counters.get(userId)
      if (!count) {
        if (counters.size >= MAX_RATE_ENTRIES) throw new LocationError(429, 'rate_limited', 'The address service is busy. Try again shortly.', 60)
        count = { expires: time + WINDOW_MS, addresses: 0, tiles: 0, maps: 0 }
        counters.set(userId, count)
      }
      const isImage = action.action === 'tile' || action.action === 'map'
      const countKey = action.action === 'map' ? 'maps' : isImage ? 'tiles' : 'addresses'
      if (++count[countKey] > (action.action === 'map' ? 20 : isImage ? 180 : 30)) throw new LocationError(429, 'rate_limited', 'Too many location requests. Try again shortly.', Math.max(1, Math.ceil((count.expires - time) / 1000)))
      let url: URL
      if (action.action === 'tile') url = new URL(`https://maps.geoapify.com/v1/tile/osm-bright/${action.z}/${action.x}/${action.y}.png`)
      else if (action.action === 'map') {
        url = new URL('https://maps.geoapify.com/v1/staticmap')
        url.searchParams.set('style', 'osm-bright'); url.searchParams.set('format', 'jpeg')
        url.searchParams.set('width', '320'); url.searchParams.set('height', '220')
        url.searchParams.set('center', `lonlat:${action.longitude},${action.latitude}`)
        url.searchParams.set('zoom', String(action.zoom))
      }
      else if (action.action === 'nearby_places') {
        url = new URL('https://api.geoapify.com/v2/places')
        url.searchParams.set('categories', 'commercial,catering,education,healthcare,public_transport,tourism')
        url.searchParams.set('filter', `circle:${action.longitude},${action.latitude},1000`)
        url.searchParams.set('bias', `proximity:${action.longitude},${action.latitude}`)
        url.searchParams.set('limit', '30'); url.searchParams.set('lang', 'en')
      } else {
        url = new URL(`https://api.geoapify.com/v1/geocode/${action.action === 'reverse' ? 'reverse' : action.action === 'suggest' || action.action === 'nearby_suggest' ? 'autocomplete' : 'search'}`)
        url.searchParams.set('format', 'json'); url.searchParams.set('lang', 'en'); url.searchParams.set('limit', action.action === 'suggest' ? '5' : action.action === 'nearby_suggest' ? '8' : '1')
        if (action.action === 'reverse') {
          url.searchParams.set('lat', String(action.latitude)); url.searchParams.set('lon', String(action.longitude)); url.searchParams.set('countrycodes', 'ng')
        } else if (action.action === 'nearby_suggest') {
          url.searchParams.set('text', action.text); url.searchParams.set('type', action.kind)
          url.searchParams.set('filter', `circle:${action.longitude},${action.latitude},10000`)
          url.searchParams.set('bias', `proximity:${action.longitude},${action.latitude}`)
        } else {
          url.searchParams.set('text', action.text); url.searchParams.set('filter', 'countrycode:ng')
        }
      }
      url.searchParams.set('apiKey', dependencies.apiKey)
      const response = await upstream(url)
      if (response.status === 429) {
        const raw = response.headers.get('Retry-After') ?? '60'
        const seconds = /^\d+$/.test(raw) ? Number(raw) : Math.ceil((Date.parse(raw) - now()) / 1000)
        throw new LocationError(429, 'rate_limited', 'The address service has reached its request limit. Try again later.', Math.min(300, Math.max(1, Number.isFinite(seconds) ? seconds : 60)))
      }
      if (!response.ok) throw new LocationError(503, 'service_unavailable', 'The address service is unavailable. Enter your address manually or try again later.')
      if (action.action === 'tile') {
        if (response.headers.get('Content-Type')?.split(';')[0].trim().toLowerCase() !== 'image/png') throw new LocationError(502, 'invalid_response', 'The map image is unavailable. Enter your address manually.')
        const bytes = new Uint8Array(await response.arrayBuffer())
        if (bytes.length < 8 || ![137, 80, 78, 71, 13, 10, 26, 10].every((byte, index) => bytes[index] === byte)) throw new LocationError(502, 'invalid_response', 'The map image is unavailable. Enter your address manually.')
        // Supabase FunctionsClient only decodes octet-stream/PDF as binary;
        // image/png would be decoded as text and corrupt these validated bytes.
        headers.set('Content-Type', 'application/octet-stream')
        headers.set('X-Image-Type', 'image/png')
        return new Response(bytes, { headers })
      }
      if (action.action === 'map') {
        if (response.headers.get('Content-Type')?.split(';')[0].trim().toLowerCase() !== 'image/jpeg') throw new LocationError(502, 'invalid_response', 'The pin map is unavailable. Confirm the address manually.')
        const bytes = new Uint8Array(await response.arrayBuffer())
        if (bytes.length < 3 || bytes[0] !== 255 || bytes[1] !== 216 || bytes[2] !== 255) throw new LocationError(502, 'invalid_response', 'The pin map is unavailable. Confirm the address manually.')
        headers.set('Content-Type', 'application/octet-stream')
        headers.set('X-Image-Type', 'image/jpeg')
        return new Response(bytes, { headers })
      }
      try {
        if (!response.headers.get('Content-Type')?.toLowerCase().includes('application/json')) throw new Error('invalid content type')
        const payload = await response.json()
        if (action.action === 'nearby_places') return json({ suggestions: normalizeNearbyPlaces(payload, action.street) }, 200)
        const results = normalizeResults(payload)
        return json(action.action === 'suggest' || action.action === 'nearby_suggest' ? { suggestions: results } : results[0], 200)
      } catch (error) {
        if (error instanceof LocationError) throw error
        throw new LocationError(502, 'invalid_response', 'The address service returned an invalid address. Enter your address manually.')
      }
    } catch (error) {
      const problem = error instanceof LocationError ? error : new LocationError(503, 'service_unavailable', 'The address service is unavailable. Enter your address manually.')
      if (problem.retryAfter) headers.set('Retry-After', String(problem.retryAfter))
      return json({ error: problem.message, code: problem.code }, problem.status)
    }
  }
}
