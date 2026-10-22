import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { geoapifyRoadMatrix } from '../_shared/geoapify-road-matrix.ts'
import { bestPerCompany, planRiderRoute, DEFAULT_POLICY, type Point, type Stop, type RiderCandidate } from '../_shared/rider-route-planner.ts'

type Event = { event_id: string; request_id: string; rider_id: string | null; event_kind: string }
type Job = { job_id: string; status: string; pickup_latitude: number | null; pickup_longitude: number | null;
  dropoff_latitude: number | null; dropoff_longitude: number | null }
type StoredStop = { job_id: string; kind: 'pickup' | 'dropoff'; latitude: number; longitude: number; eta_at?: string | null }
type Context = { rider_id: string; partner_id: string; latitude: number | null; longitude: number | null;
  accuracy_metres: number | null; gps_captured_at: string | null; plan_version: number;
  existing_stops: StoredStop[]; active_jobs: Job[] }
const point = (latitude: number | null, longitude: number | null): Point | undefined =>
  typeof latitude === 'number' && typeof longitude === 'number' && Number.isFinite(latitude) &&
  Number.isFinite(longitude) && Math.abs(latitude) <= 90 && Math.abs(longitude) <= 180
    ? { latitude, longitude } : undefined
const unique = (points: Point[]) => [...new Map(points.map((p) => [`${p.latitude.toFixed(6)},${p.longitude.toFixed(6)}`, p])).values()]
const stop = (s: StoredStop): Stop => ({ id: `${s.job_id}:${s.kind}`, jobId: s.job_id, kind: s.kind,
  point: { latitude: s.latitude, longitude: s.longitude } })

Deno.serve(async (request) => {
  if (request.method !== 'POST') return Response.json({ error: 'Method not allowed' }, { status: 405 })
  const secret = Deno.env.get('ROUTE_WORKER_SECRET')
  if (!secret || request.headers.get('x-route-worker-secret') !== secret)
    return Response.json({ error: 'Unauthorized' }, { status: 401 })
  const url = Deno.env.get('SUPABASE_URL')
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  const geoKey = Deno.env.get('GEOAPIFY_API_KEY')
  if (!url || !serviceKey || !geoKey) return Response.json({ error: 'Routing is not configured' }, { status: 503 })
  const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const rpc = async (name: string, args: Record<string, unknown>) => {
    const { data, error } = await db.rpc(name, args)
    if (error) throw new Error(`${name}: ${error.message}`)
    return data
  }
  const roads = (points: Point[]) => geoapifyRoadMatrix(unique(points), geoKey,
    async (credits) => Boolean(await rpc('reserve_route_matrix_credits', { p_credits: credits })))
  const replan = async (riderId: string) => {
    const context = await rpc('rider_route_context', { p_rider: riderId }) as Context | null
    if (!context) return
    const jobs = context.active_jobs ?? []
    const exceptionIds = jobs.filter((j) => j.status === 'exception').map((j) => j.job_id)
    const { data: handoffs, error: handoffError } = exceptionIds.length
      ? await db.from('pickup_handoff_codes').select('job_id,verified_at').in('job_id', exceptionIds)
      : { data: [], error: null }
    if (handoffError) throw new Error(`Pickup custody lookup: ${handoffError.message}`)
    const collected = new Set((handoffs ?? []).filter((row) => row.verified_at).map((row) => row.job_id))
    const needsPickup = (job: Job) => job.status === 'pickup_scheduled' ||
      (job.status === 'exception' && !collected.has(job.job_id))
    const existing = (context.existing_stops ?? []).filter((s) => jobs.some((j) => j.job_id === s.job_id &&
      (s.kind === 'dropoff' || needsPickup(j))))
    const planned = new Set(existing.map((s) => `${s.job_id}:${s.kind}`))
    const next = [...existing]
    for (const job of jobs) {
      if (needsPickup(job)) {
        const pickup = point(job.pickup_latitude, job.pickup_longitude)
        if (!pickup) throw new Error('Assigned pickup lacks coordinates')
        if (!planned.has(`${job.job_id}:pickup`)) next.push({ job_id: job.job_id, kind: 'pickup', ...pickup })
      }
      const dropoff = point(job.dropoff_latitude, job.dropoff_longitude)
      if (!dropoff) throw new Error('Assigned drop-off lacks coordinates')
      if (!planned.has(`${job.job_id}:dropoff`)) next.push({ job_id: job.job_id, kind: 'dropoff', ...dropoff })
    }
    if (!next.length) {
      if (existing.length) await rpc('commit_rider_route_plan', { p_rider: riderId,
        p_expected_version: context.plan_version, p_stops: [], p_estimate_source: 'road' })
      return
    }
    const origin = point(context.latitude, context.longitude)
    if (!origin || !context.gps_captured_at || Date.now() - Date.parse(context.gps_captured_at) > 120_000 ||
      (context.accuracy_metres ?? Infinity) > 100) throw new Error('Fresh accurate rider GPS is required')
    const longRoute = next.length > 9
    const matrix = await roads([origin, ...next.slice(0, 9).map((s) => ({ latitude: s.latitude, longitude: s.longitude }))])
    if (!matrix) throw new Error('Road matrix unavailable or budget exhausted')
    // Insert newly awarded pickups into the road-time route while preserving
    // the rider's current next stop and existing customer ETA commitments.
    let ordered = (longRoute ? next : existing).map(stop)
    if (ordered[0]) ordered[0].pinned = true
    for (const job of longRoute ? [] : jobs) {
      const pickup = point(job.pickup_latitude, job.pickup_longitude)
      const dropoff = point(job.dropoff_latitude, job.dropoff_longitude)
      if (!dropoff) continue
      if (needsPickup(job) && pickup &&
        !planned.has(`${job.job_id}:pickup`)) {
        const proposal = planRiderRoute({ riderId, companyId: context.partner_id,
          position: origin, locationAgeSeconds: 0, locationAccuracyMetres: context.accuracy_metres ?? 0,
          onDuty: true, loadState: 'available', activePickupCount: jobs.length, stops: ordered },
        { jobId: job.job_id,
          pickup: { id: `${job.job_id}:pickup`, jobId: job.job_id, kind: 'pickup', point: pickup },
          dropoff: { id: `${job.job_id}:dropoff`, jobId: job.job_id, kind: 'dropoff', point: dropoff } },
        matrix, { ...DEFAULT_POLICY, maxPickupMinutes: Number.POSITIVE_INFINITY })
        if (proposal?.commitEligible) { ordered = proposal.stops; continue }
      }
      for (const s of next) if (s.job_id === job.job_id && !ordered.some((item) => item.id === `${s.job_id}:${s.kind}`))
        ordered.push(stop(s))
    }
    let at = origin
    let minutes = 0
    const sequenced = ordered.map((s, index) => {
      const destination = s.point
      const leg = index < 9 ? matrix(at, destination) : undefined
      if (!leg && index < 9) throw new Error('Road leg unavailable')
      if (leg) minutes += leg.minutes + 2
      at = destination
      return { job_id: s.jobId, kind: s.kind, ...destination,
        eta_at: leg ? new Date(Date.now() + minutes * 60_000).toISOString() : null }
    })
    await rpc('commit_rider_route_plan', { p_rider: riderId, p_expected_version: context.plan_version,
      p_stops: sequenced, p_estimate_source: 'road' })
  }
  const shadow = async (requestId: string) => {
    const { data: quote } = await db.from('delivery_quote_windows').select('deadline_at,status').eq('request_id', requestId).maybeSingle()
    if (!quote || quote.status !== 'open' || Date.parse(quote.deadline_at) <= Date.now()) return
    const { data: delivery } = await db.from('service_requests')
      .select('pickup_latitude,pickup_longitude,delivery_latitude,delivery_longitude').eq('id', requestId).maybeSingle()
    if (!delivery) return
    const pickup = point(delivery.pickup_latitude, delivery.pickup_longitude)
    const dropoff = point(delivery.delivery_latitude, delivery.delivery_longitude)
    if (!pickup || !dropoff) return
    const candidates = await rpc('route_planner_candidates', { p_request: requestId }) as Array<{
      partner_id: string; rider_id: string; latitude: number; longitude: number; accuracy_metres: number;
      gps_captured_at: string; load_state: 'available' | 'almost_full'; active_pickups: number;
      existing_stops: StoredStop[]; active_jobs: Job[]; has_unroutable_jobs: boolean
    }>
    const proposals = []
    for (const candidate of candidates.slice(0, 2)) {
      const active = candidate.active_jobs ?? []
      const stored = (candidate.existing_stops ?? []).filter((s) => active.some((j) => j.job_id === s.job_id &&
        (s.kind === 'dropoff' || j.status === 'pickup_scheduled' || j.status === 'exception')))
      if (candidate.has_unroutable_jobs || active.some((j) => j.status === 'exception') ||
        (active.length && !stored.length) ||
        active.some((j) => !stored.some((s) => s.job_id === j.job_id && s.kind === 'dropoff') ||
          ((j.status === 'pickup_scheduled' || j.status === 'exception') &&
            !stored.some((s) => s.job_id === j.job_id && s.kind === 'pickup')))) continue
      const stops = stored.map(stop)
      const origin = { latitude: candidate.latitude, longitude: candidate.longitude }
      const matrix = await roads([origin, ...stops.map((s) => s.point), pickup, dropoff])
      if (!matrix) continue
      const rider: RiderCandidate = { riderId: candidate.rider_id, companyId: candidate.partner_id,
        position: origin, onDuty: true, loadState: candidate.load_state,
        locationAgeSeconds: (Date.now() - Date.parse(candidate.gps_captured_at)) / 1000,
        locationAccuracyMetres: candidate.accuracy_metres, activePickupCount: candidate.active_pickups, stops }
      const proposal = planRiderRoute(rider, { jobId: requestId,
        pickup: { id: `${requestId}:pickup`, jobId: requestId, kind: 'pickup', point: pickup },
        dropoff: { id: `${requestId}:dropoff`, jobId: requestId, kind: 'dropoff', point: dropoff } }, matrix)
      if (proposal) proposals.push(proposal)
    }
    for (const proposal of bestPerCompany(proposals)) await rpc('upsert_dispatch_route_proposal', {
      p_request: requestId, p_partner: proposal.companyId, p_rider: proposal.riderId,
      p_load_state: proposal.loadState, p_algorithm_version: 'road-v1-shadow', p_score: proposal.score,
      p_details: { tier: proposal.tier, pickup_eta_minutes: proposal.pickupEtaMinute,
        max_existing_delay_minutes: proposal.maxExistingDelayMinutes, estimate_source: proposal.estimateSource },
      p_expires_at: quote.deadline_at,
    })
  }
  const events = await rpc('claim_route_planner_events', { p_limit: 5 }) as Event[]
  const outcomes = []
  for (const event of events) {
    try {
      if (event.event_kind === 'shadow_invitation') await shadow(event.request_id)
      else if (event.rider_id) await replan(event.rider_id)
      await rpc('finish_route_planner_event', { p_event_id: event.event_id, p_success: true })
      outcomes.push({ event_id: event.event_id, ok: true })
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Unknown routing error'
      await rpc('finish_route_planner_event', { p_event_id: event.event_id, p_success: false, p_error: message })
      outcomes.push({ event_id: event.event_id, ok: false, error: message })
    }
  }
  return Response.json({ processed: outcomes.length, outcomes })
})
