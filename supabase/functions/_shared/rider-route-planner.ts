/** Pure, bounded planner. All times are minutes from `now`; road legs are authoritative. */
export type Point = { latitude: number; longitude: number }
export type LoadState = 'available' | 'almost_full' | 'full'
export type Stop = {
  id: string
  jobId: string
  kind: 'pickup' | 'dropoff'
  point: Point
  serviceMinutes?: number
  /** A stop already shown to the rider as next cannot be moved behind new work. */
  pinned?: boolean
}
export type RoadLeg = { minutes: number; kilometres: number }
export type RoadMatrix = (from: Point, to: Point) => RoadLeg | undefined
export type RiderCandidate = {
  riderId: string
  companyId: string
  position: Point
  locationAgeSeconds: number
  locationAccuracyMetres: number
  onDuty: boolean
  loadState: LoadState
  activePickupCount: number
  stops: Stop[]
}
export type DeliveryRequest = { jobId: string; pickup: Stop; dropoff: Stop }
export type PlannerPolicy = {
  maxLocationAgeSeconds: number
  maxLocationAccuracyMetres: number
  maxPickupMinutes: number
  qualityBandMinutes: number
  maxEnumerations: number
}
export const DEFAULT_POLICY: PlannerPolicy = {
  maxLocationAgeSeconds: 120,
  maxLocationAccuracyMetres: 100,
  maxPickupMinutes: 30,
  qualityBandMinutes: 3,
  maxEnumerations: 512,
}
export type RouteProposal = {
  riderId: string
  companyId: string
  loadState: LoadState
  stops: Stop[]
  pickupEtaMinute: number
  totalMinutes: number
  totalKilometres: number
  maxExistingDelayMinutes: number
  sumExistingDelayMinutes: number
  tier: 1 | 2 | 3 | 4
  score: number
  estimateSource: 'road' | 'idle-fallback'
  /** False for approximate idle-rider pickup ranking; never commit its stop plan. */
  commitEligible: boolean
}

function validPoint(point: Point): boolean {
  return Number.isFinite(point.latitude) && Number.isFinite(point.longitude) && Math.abs(point.latitude) <= 90 && Math.abs(point.longitude) <= 180
}

function validLeg(leg: RoadLeg | undefined): leg is RoadLeg {
  return !!leg && Number.isFinite(leg.minutes) && leg.minutes >= 0 && Number.isFinite(leg.kilometres) && leg.kilometres >= 0
}

type Evaluation = { arrivals: Map<string, number>; minutes: number; kilometres: number }
function evaluate(start: Point, stops: Stop[], matrix: RoadMatrix): Evaluation | undefined {
  let at = start
  let time = 0
  let kilometres = 0
  const arrivals = new Map<string, number>()
  const picked = new Set<string>()
  for (const stop of stops) {
    if (!validPoint(stop.point)) return undefined
    const leg = matrix(at, stop.point)
    if (!validLeg(leg)) return undefined
    time += leg.minutes
    kilometres += leg.kilometres
    if (stop.kind === 'pickup') picked.add(stop.jobId)
    else if (stops.some((item) => item.jobId === stop.jobId && item.kind === 'pickup') && !picked.has(stop.jobId)) return undefined
    arrivals.set(stop.id, time)
    time += stop.serviceMinutes ?? 0
    at = stop.point
  }
  return { arrivals, minutes: time, kilometres }
}

function isFiniteStop(stop: Stop): boolean {
  return !!stop.id && !!stop.jobId && validPoint(stop.point) && (stop.serviceMinutes ?? 0) >= 0
}

/** Intended direction comes from parcels already in custody, not GPS heading. */
export function followsCarriedParcelRoute(position: Point, stops: Stop[], pickup: Point, dropoff: Point): boolean {
  if (![position, pickup, dropoff].every(validPoint)) return false
  const awaitingPickup = new Set(stops.filter((s) => s.kind === 'pickup').map((s) => s.jobId))
  const carriedDropoffs = stops.filter((s) => s.kind === 'dropoff' && !awaitingPickup.has(s.jobId))
  let from = position
  for (const destination of carriedDropoffs) {
    const latitudeScale = 111.2
    const longitudeScale = latitudeScale * Math.cos((from.latitude + destination.point.latitude) / 2 * Math.PI / 180)
    const east = (destination.point.longitude - from.longitude) * longitudeScale
    const north = (destination.point.latitude - from.latitude) * latitudeScale
    const length = Math.hypot(east, north)
    if (length < 0.2) { from = destination.point; continue }
    const forward = (point: Point) =>
      ((point.longitude - from.longitude) * longitudeScale * east +
        (point.latitude - from.latitude) * latitudeScale * north) / length
    const pickupAlong = forward(pickup)
    const newTripAlong = forward(dropoff) - pickupAlong
    // A 200 m tolerance absorbs small address and GPS inaccuracies.
    if (pickupAlong >= -0.2 && newTripAlong >= -0.2) return true
    from = destination.point
  }
  return false
}

/** Bounded road-time search: reduce kilometres and total parcel completion time. */
export function optimizeCommittedRoute(start: Point, stops: Stop[], roads: RoadMatrix): Stop[] | undefined {
  if (!validPoint(start) || stops.length > 9 || stops.some((s) => !isFiniteStop(s)) ||
    new Set(stops.map((s) => s.id)).size !== stops.length) return undefined
  if (!stops.length) return []
  const allPickups = new Set(stops.filter((s) => s.kind === 'pickup').map((s) => s.jobId))
  type State = { at: Point; route: Stop[]; remaining: Stop[]; picked: Set<string>;
    minutes: number; kilometres: number; completionMinutes: number; score: number }
  let beam: State[] = [{ at: start, route: [], remaining: stops, picked: new Set(),
    minutes: 0, kilometres: 0, completionMinutes: 0, score: 0 }]
  for (let depth = 0; depth < stops.length; depth++) {
    const next: State[] = []
    for (const state of beam) for (let i = 0; i < state.remaining.length; i++) {
      const candidate = state.remaining[i]
      if (depth === 0 && stops[0].pinned && candidate.id !== stops[0].id) continue
      if (candidate.kind === 'dropoff' && allPickups.has(candidate.jobId) && !state.picked.has(candidate.jobId)) continue
      const leg = roads(state.at, candidate.point)
      if (!validLeg(leg)) continue
      const minutes = state.minutes + leg.minutes + (candidate.serviceMinutes ?? 0)
      const kilometres = state.kilometres + leg.kilometres
      const completionMinutes = state.completionMinutes + (candidate.kind === 'dropoff' ? minutes : 0)
      const route = [...state.route, candidate]
      next.push({ at: candidate.point, route,
        remaining: state.remaining.filter((_, index) => index !== i),
        picked: candidate.kind === 'pickup' ? new Set([...state.picked, candidate.jobId]) : state.picked,
        minutes, kilometres, completionMinutes,
        score: 5 * kilometres + minutes + completionMinutes })
    }
    if (!next.length) return undefined
    next.sort((a, b) => a.score - b.score ||
      a.route.map((s) => s.id).join('|').localeCompare(b.route.map((s) => s.id).join('|')))
    beam = next.slice(0, 64)
  }
  return beam[0].route
}

/** Optimize existing stops, then insert the new pickup and drop-off. */
export function planRiderRoute(
  rider: RiderCandidate,
  request: DeliveryRequest,
  matrix: RoadMatrix | undefined,
  policy: PlannerPolicy = DEFAULT_POLICY,
  idleFallback?: RoadMatrix,
): RouteProposal | undefined {
  if (!rider.onDuty || rider.loadState === 'full' ||
    rider.activePickupCount >= 6 ||
    rider.locationAgeSeconds < 0 || rider.locationAgeSeconds > policy.maxLocationAgeSeconds ||
    rider.locationAccuracyMetres < 0 || rider.locationAccuracyMetres > policy.maxLocationAccuracyMetres ||
    !validPoint(rider.position) || request.pickup.kind !== 'pickup' || request.dropoff.kind !== 'dropoff' ||
    request.pickup.jobId !== request.jobId || request.dropoff.jobId !== request.jobId ||
    !isFiniteStop(request.pickup) || !isFiniteStop(request.dropoff) ||
    rider.stops.some((stop) => !isFiniteStop(stop) || stop.jobId === request.jobId) ||
    new Set(rider.stops.map((stop) => stop.id)).size !== rider.stops.length) return undefined

  const source = matrix ? 'road' : 'idle-fallback'
  // A fallback can rank a simple idle pickup, but must never stack or resequence existing work.
  if (!matrix && rider.stops.length) return undefined
  const roads = matrix ?? idleFallback
  if (!roads) return undefined
  const baseline = evaluate(rider.position, rider.stops, roads)
  if (!baseline) return undefined
  const stops = matrix ? optimizeCommittedRoute(rider.position, rider.stops, roads) ?? rider.stops : rider.stops
  let best: RouteProposal | undefined
  let examined = 0
  for (let pickupAt = 0; pickupAt <= stops.length; pickupAt++) {
    const withPickup = [...stops.slice(0, pickupAt), request.pickup, ...stops.slice(pickupAt)]
    for (let dropoffAt = pickupAt + 1; dropoffAt <= withPickup.length; dropoffAt++) {
      if (++examined > policy.maxEnumerations) break
      const proposed = [...withPickup.slice(0, dropoffAt), request.dropoff, ...withPickup.slice(dropoffAt)]
      // An acknowledged next stop must remain next.
      if (stops[0]?.pinned && proposed[0]?.id !== stops[0].id) continue
      const route = evaluate(rider.position, proposed, roads)
      if (!route) continue
      const pickupEta = route.arrivals.get(request.pickup.id)
      if (pickupEta === undefined || pickupEta > policy.maxPickupMinutes) continue
      let maxDelay = 0
      let sumDelay = 0
      let feasible = true
      for (const stop of stops) {
        const oldEta = baseline.arrivals.get(stop.id)
        const newEta = route.arrivals.get(stop.id)
        if (oldEta === undefined || newEta === undefined) { feasible = false; break }
        const delay = Math.max(0, newEta - oldEta)
        maxDelay = Math.max(maxDelay, delay)
        sumDelay += delay
      }
      if (!feasible) continue
      const direct = roads(request.pickup.point, request.dropoff.point)
      if (!validLeg(direct)) continue
      const extraMinutes = Math.max(0, route.minutes - baseline.minutes)
      const extraKilometres = Math.max(0, route.kilometres - baseline.kilometres)
      const aligned = followsCarriedParcelRoute(rider.position, stops, request.pickup.point,
        request.dropoff.point) && extraMinutes <= direct.minutes + 5
      const nearPickup = pickupEta <= 10
      const tier: 1 | 2 | 3 | 4 = aligned ? (nearPickup ? 1 : 2) : stops.length ? (nearPickup ? 3 : 4) : 4
      const candidate: RouteProposal = {
        riderId: rider.riderId, companyId: rider.companyId, loadState: rider.loadState,
        stops: matrix ? proposed : [], pickupEtaMinute: pickupEta, totalMinutes: matrix ? route.minutes : 0,
        totalKilometres: matrix ? route.kilometres : 0, maxExistingDelayMinutes: maxDelay,
        sumExistingDelayMinutes: sumDelay, tier,
        score: pickupEta + extraMinutes + 5 * extraKilometres,
        estimateSource: source, commitEligible: !!matrix,
      }
      if (!best || compareProposals(candidate, best, policy) < 0) best = candidate
    }
    if (examined > policy.maxEnumerations) break
  }
  return best
}

export function compareProposals(a: RouteProposal, b: RouteProposal, _policy: PlannerPolicy = DEFAULT_POLICY): number {
  if (a.tier !== b.tier) return a.tier - b.tier
  if (a.score !== b.score) return a.score - b.score
  return a.riderId.localeCompare(b.riderId)
}

export function bestPerCompany(proposals: RouteProposal[], policy: PlannerPolicy = DEFAULT_POLICY): RouteProposal[] {
  const winners = new Map<string, RouteProposal>()
  for (const proposal of proposals) {
    const current = winners.get(proposal.companyId)
    if (!current || compareProposals(proposal, current, policy) < 0) winners.set(proposal.companyId, proposal)
  }
  return [...winners.values()].sort((a, b) => compareProposals(a, b, policy)).slice(0, 50)
}
