import type { Point, RoadMatrix, RoadLeg } from './rider-route-planner.ts'

// Compute Route Matrix returns an unordered JSON array in the REST API.
// https://developers.google.com/maps/documentation/routes/compute_route_matrix
type MatrixElement = {
  originIndex?: unknown
  destinationIndex?: unknown
  status?: unknown
  condition?: unknown
  distanceMeters?: unknown
  duration?: unknown
}

const endpoint = 'https://routes.googleapis.com/distanceMatrix/v2:computeRouteMatrix'
const fieldMask = 'originIndex,destinationIndex,status,condition,distanceMeters,duration'
const coordinateKey = (point: Point) => `${point.latitude.toFixed(6)},${point.longitude.toFixed(6)}`
const nearbyMetres = (a: Point, b: Point) => {
  const lat = (b.latitude - a.latitude) * Math.PI / 180
  const lon = (b.longitude - a.longitude) * Math.PI / 180
  const ratio = Math.sin(lat / 2) ** 2 + Math.cos(a.latitude * Math.PI / 180) *
    Math.cos(b.latitude * Math.PI / 180) * Math.sin(lon / 2) ** 2
  return 6371000 * 2 * Math.asin(Math.sqrt(Math.min(1, ratio)))
}
const validPoint = (point: Point) => Number.isFinite(point.latitude) && Number.isFinite(point.longitude) &&
  Math.abs(point.latitude) <= 90 && Math.abs(point.longitude) <= 180
const waypoint = (point: Point) => ({ waypoint: { location: { latLng: {
  latitude: point.latitude, longitude: point.longitude,
} } } })

/** Reservations only increase during one UTC day. After n elements are denied,
 * n or more cannot fit later that day, so avoid another database reservation.
 */
export function memoizeDeniedMatrixReservations(
  reserve: (elements: number) => Promise<boolean>,
  utcDay: () => string = () => new Date().toISOString().slice(0, 10),
): (elements: number) => Promise<boolean> {
  let day = utcDay()
  let smallestDenied = Number.POSITIVE_INFINITY
  return async (elements) => {
    const requestDay = utcDay()
    if (requestDay !== day) { day = requestDay; smallestDenied = Number.POSITIVE_INFINITY }
    if (elements >= smallestDenied) return false
    const granted = await reserve(elements)
    if (!granted && day === requestDay && utcDay() === requestDay)
      smallestDenied = Math.min(smallestDenied, elements)
    return granted
  }
}

function validLeg(element: MatrixElement): RoadLeg | undefined {
  // Proto3 may omit default-valued fields, including an OK status and zero distance.
  if (element.status !== undefined &&
    (!element.status || typeof element.status !== 'object' || Array.isArray(element.status))) return undefined
  const status = (element.status ?? {}) as { code?: unknown }
  if (status.code !== undefined && status.code !== 0) return undefined
  const distance = element.distanceMeters ?? 0
  const duration = element.duration ?? (distance === 0 ? '0s' : undefined)
  if (element.condition !== 'ROUTE_EXISTS' || typeof distance !== 'number' ||
    !Number.isSafeInteger(distance) || distance < 0 ||
    typeof duration !== 'string' || !/^(?:0|[1-9]\d*)(?:\.\d{1,9})?s$/.test(duration)) return undefined
  const seconds = Number(duration.slice(0, -1))
  if (!Number.isFinite(seconds)) return undefined
  return { minutes: seconds / 60, kilometres: distance / 1000 }
}

/** Bounded all-to-all road matrix; the reservation is not refunded on HTTP failure. */
export async function googleRoadMatrix(
  points: Point[], apiKey: string,
  reserve: (elements: number) => Promise<boolean>,
  fetcher: typeof fetch = fetch,
): Promise<RoadMatrix | undefined> {
  if (!apiKey.trim() || points.length < 2 || points.some((point) => !validPoint(point))) return undefined
  const unique = [...new Map(points.map((point) => [coordinateKey(point), point])).values()]
  if (unique.length > 10) return undefined
  if (unique.length === 1) return (from, to) =>
    validPoint(from) && validPoint(to) && coordinateKey(from) === coordinateKey(unique[0]) &&
      coordinateKey(to) === coordinateKey(unique[0]) ? { minutes: 0, kilometres: 0 } : undefined

  // Google bills Compute Route Matrix per origin × destination element.
  const elements = unique.length ** 2
  if (!await reserve(elements)) return undefined
  const controller = new AbortController()
  let timer!: ReturnType<typeof setTimeout>
  const timeout = new Promise<undefined>((resolve) => {
    timer = setTimeout(() => { controller.abort(); resolve(undefined) }, 3500)
  })
  try {
    const response = await Promise.race([fetcher(endpoint, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'X-Goog-Api-Key': apiKey,
        'X-Goog-FieldMask': fieldMask },
      body: JSON.stringify({ origins: unique.map(waypoint), destinations: unique.map(waypoint),
        travelMode: 'DRIVE', routingPreference: 'TRAFFIC_UNAWARE' }),
      signal: controller.signal,
    }), timeout])
    if (!response?.ok) return undefined
    const body: unknown = await Promise.race([response.json(), timeout])
    if (!Array.isArray(body) || body.length !== elements) return undefined
    const legs = new Map<string, RoadLeg | undefined>()
    for (const value of body) {
      if (!value || typeof value !== 'object' || Array.isArray(value)) return undefined
      const element = value as MatrixElement
      const from = element.originIndex ?? 0
      const to = element.destinationIndex ?? 0
      if (!Number.isInteger(from) || !Number.isInteger(to) ||
        (from as number) < 0 || (to as number) < 0 ||
        (from as number) >= unique.length || (to as number) >= unique.length) return undefined
      const key = `${from}:${to}`
      if (legs.has(key)) return undefined
      legs.set(key, validLeg(element))
    }
    const lookup = new Map(unique.map((point, index) => [coordinateKey(point), index]))
    return (from, to) => {
      if (!validPoint(from) || !validPoint(to)) return undefined
      const i = lookup.get(coordinateKey(from)); const j = lookup.get(coordinateKey(to))
      return i === undefined || j === undefined ? undefined : legs.get(`${i}:${j}`)
    }
  } catch { return undefined }
  finally { clearTimeout(timer) }
}

/** An idle rider needs only rider→pickup and pickup→drop-off. Google matrices
 * are Cartesian products, so two 1×1 requests avoid charging for unused legs.
 * Needed requests share a 3.5-second deadline; the reservation is never refunded.
 * An optional order-scoped cache reuses only a successful pickup→drop-off leg.
 */
export async function googleIdleRiderRoadMatrix(
  rider: Point, pickup: Point, dropoff: Point, apiKey: string,
  reserve: (elements: number) => Promise<boolean>,
  fetcher: typeof fetch = fetch,
  directLegCache?: Map<string, RoadLeg>,
): Promise<RoadMatrix | undefined> {
  if (!apiKey.trim() || ![rider, pickup, dropoff].every(validPoint)) return undefined
  const key = (from: Point, to: Point) => `${coordinateKey(from)}>${coordinateKey(to)}`
  const required = [...new Map([[rider, pickup], [pickup, dropoff]].map(
    ([from, to]) => [key(from, to), { from, to }],
  )).values()]
  const directKey = key(pickup, dropoff)
  const riderAtPickup = nearbyMetres(rider, pickup) <= 30
  const nonzero = required.filter(({ from, to }) =>
    coordinateKey(from) !== coordinateKey(to) && !(riderAtPickup && key(from, to) === key(rider, pickup)) &&
    !(directLegCache?.has(directKey) && key(from, to) === directKey))
  if (nonzero.length && !await reserve(nonzero.length)) return undefined

  const controller = new AbortController()
  let timer!: ReturnType<typeof setTimeout>
  const timeout = new Promise<undefined>((resolve) => {
    timer = setTimeout(() => { controller.abort(); resolve(undefined) }, 3500)
  })
  try {
    const fetched = await Promise.race([Promise.all(nonzero.map(async ({ from, to }) => {
      const response = await fetcher(endpoint, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'X-Goog-Api-Key': apiKey,
          'X-Goog-FieldMask': fieldMask },
        body: JSON.stringify({ origins: [waypoint(from)], destinations: [waypoint(to)],
          travelMode: 'DRIVE', routingPreference: 'TRAFFIC_UNAWARE' }),
        signal: controller.signal,
      })
      if (!response.ok) return undefined
      const body: unknown = await response.json()
      if (!Array.isArray(body) || body.length !== 1 || !body[0] ||
        typeof body[0] !== 'object' || Array.isArray(body[0])) return undefined
      const element = body[0] as MatrixElement
      if ((element.originIndex ?? 0) !== 0 || (element.destinationIndex ?? 0) !== 0)
        return undefined
      return validLeg(element)
    })), timeout])
    if (!fetched) return undefined
    const legs = new Map<string, RoadLeg>()
    for (const { from, to } of required) {
      if (coordinateKey(from) === coordinateKey(to)) legs.set(key(from, to), { minutes: 0, kilometres: 0 })
    }
    if (riderAtPickup) legs.set(key(rider, pickup), { minutes: 0, kilometres: 0 })
    if (directLegCache?.has(directKey)) legs.set(directKey, directLegCache.get(directKey)!)
    nonzero.forEach(({ from, to }, index) => {
      const leg = fetched[index]
      if (leg) {
        legs.set(key(from, to), leg)
        if (key(from, to) === directKey) directLegCache?.set(directKey, leg)
      }
    })
    if (required.some(({ from, to }) => !legs.has(key(from, to)))) return undefined
    return (from, to) => validPoint(from) && validPoint(to) ? legs.get(key(from, to)) : undefined
  } catch { return undefined }
  finally { clearTimeout(timer) }
}
