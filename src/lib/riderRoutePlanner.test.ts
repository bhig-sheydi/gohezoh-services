import { describe, expect, it } from 'vitest'
import {
  bestPerCompany, compareProposals, followsCarriedParcelRoute, optimizeCommittedRoute, planRiderRoute,
  type DeliveryRequest, type RiderCandidate, type RoadMatrix, type Stop,
} from '../../supabase/functions/_shared/rider-route-planner'

const point = (n: number) => ({ latitude: n, longitude: 0 })
const matrix: RoadMatrix = (a, b) => ({ minutes: Math.abs(a.latitude - b.latitude), kilometres: Math.abs(a.latitude - b.latitude) / 2 })
const pickup: Stop = { id: 'new-p', jobId: 'new', kind: 'pickup', point: point(2) }
const dropoff: Stop = { id: 'new-d', jobId: 'new', kind: 'dropoff', point: point(6) }
const request: DeliveryRequest = { jobId: 'new', pickup, dropoff }
const rider = (changes: Partial<RiderCandidate> = {}): RiderCandidate => ({
  riderId: 'rider-a', companyId: 'company-a', position: point(0), locationAgeSeconds: 20,
  locationAccuracyMetres: 20, onDuty: true, loadState: 'available', activePickupCount: 0,
  stops: [], ...changes,
})

describe('deterministic route planner', () => {
  it('inserts pickup before dropoff and keeps an already collected parcel dropoff', () => {
    const existing: Stop = { id: 'old-d', jobId: 'old', kind: 'dropoff', point: point(8) }
    const plan = planRiderRoute(rider({ stops: [existing] }), request, matrix)
    expect(plan).toBeDefined()
    expect(plan!.stops.findIndex(s => s.id === pickup.id)).toBeLessThan(plan!.stops.findIndex(s => s.id === dropoff.id))
    expect(plan!.stops.some(s => s.id === existing.id)).toBe(true)
    expect(plan!.estimateSource).toBe('road')
  })

  it('keeps pinned next stop first', () => {
    const pinned: Stop = { id: 'old-d', jobId: 'old', kind: 'dropoff', point: point(1), pinned: true }
    const plan = planRiderRoute(rider({ stops: [pinned] }), request, matrix)
    expect(plan?.stops[0].id).toBe('old-d')
  })

  it('serves five drop-offs on route A before one opposite-side drop-off on B', () => {
    const stops: Stop[] = [
      { id: 'b', jobId: 'b', kind: 'dropoff', point: point(-10) },
      ...Array.from({ length: 5 }, (_, i) => ({ id: `a-${i}`, jobId: `a-${i}`,
        kind: 'dropoff' as const, point: point(10) })),
    ]
    expect(optimizeCommittedRoute(point(0), stops, matrix)?.map(s => s.id))
      .toEqual(['a-0', 'a-1', 'a-2', 'a-3', 'a-4', 'b'])
  })

  it('finishes an acknowledged B stop before returning to A and its newly added C stop', () => {
    const stops: Stop[] = [
      { id: 'b', jobId: 'b', kind: 'dropoff', point: point(-10), pinned: true },
      ...Array.from({ length: 5 }, (_, i) => ({ id: `a-${i}`, jobId: `a-${i}`,
        kind: 'dropoff' as const, point: point(10) })),
      { id: 'c', jobId: 'c', kind: 'dropoff', point: point(12) },
    ]
    const order = optimizeCommittedRoute(point(0), stops, matrix)?.map(s => s.id)
    expect(order?.[0]).toBe('b')
    expect(order?.slice(1, 6)).toEqual(['a-0', 'a-1', 'a-2', 'a-3', 'a-4'])
    expect(order?.[6]).toBe('c')
  })

  it('keeps each pickup before its drop-off when reordering', () => {
    const stops: Stop[] = [
      { id: 'a-d', jobId: 'a', kind: 'dropoff', point: point(2) },
      { id: 'a-p', jobId: 'a', kind: 'pickup', point: point(1) },
      { id: 'b-d', jobId: 'b', kind: 'dropoff', point: point(-1) },
    ]
    const order = optimizeCommittedRoute(point(0), stops, matrix)?.map(s => s.id)
    expect(order?.indexOf('a-p')).toBeLessThan(order!.indexOf('a-d'))
    expect(order).toHaveLength(3)
  })

  it('derives intended direction from parcels already in the rider’s custody', () => {
    const carried: Stop[] = [{ id: 'a-d', jobId: 'a', kind: 'dropoff', point: point(10) }]
    expect(followsCarriedParcelRoute(point(0), carried, point(2), point(6))).toBe(true)
    expect(followsCarriedParcelRoute(point(0), carried, point(-2), point(6))).toBe(false)
    expect(followsCarriedParcelRoute(point(0), carried, point(2), point(-6))).toBe(false)
    expect(followsCarriedParcelRoute(point(0), [
      { id: 'a-p', jobId: 'a', kind: 'pickup', point: point(1) }, ...carried,
    ], point(2), point(6))).toBe(false)
  })

  it('recognizes the planned return from B toward parcels on A', () => {
    const carried: Stop[] = [
      { id: 'b-d', jobId: 'b', kind: 'dropoff', point: point(-10), pinned: true },
      { id: 'a-d', jobId: 'a', kind: 'dropoff', point: point(10) },
    ]
    expect(followsCarriedParcelRoute(point(0), carried, point(2), point(8))).toBe(true)
  })

  it('does not call an opposite-direction delivery route-aligned', () => {
    const carried: Stop = { id: 'a-d', jobId: 'a', kind: 'dropoff', point: point(10) }
    const opposite = { ...request, pickup: { ...pickup, point: point(-2) },
      dropoff: { ...dropoff, point: point(-6) } }
    expect(planRiderRoute(rider({ stops: [carried] }), opposite, matrix)?.tier).toBe(3)
  })

  it('excludes full riders without removing them from duty or imposing fabricated box capacity', () => {
    expect(planRiderRoute(rider({ loadState: 'full' }), request, matrix)).toBeUndefined()
    expect(planRiderRoute(rider({ loadState: 'almost_full' }), request, matrix)?.loadState).toBe('almost_full')
  })

  it('rejects stale or inaccurate GPS and enforces the six-parcel limit', () => {
    expect(planRiderRoute(rider({ locationAgeSeconds: 121 }), request, matrix)).toBeUndefined()
    expect(planRiderRoute(rider({ locationAccuracyMetres: 101 }), request, matrix)).toBeUndefined()
    expect(planRiderRoute(rider({ activePickupCount: 5 }), request, matrix)).toBeDefined()
    expect(planRiderRoute(rider({ activePickupCount: 6 }), request, matrix)).toBeUndefined()
  })

  it('uses degraded estimates only for idle riders and never calls them road evidence', () => {
    expect(planRiderRoute(rider(), request, undefined, undefined, matrix)).toMatchObject({ estimateSource: 'idle-fallback', commitEligible: false, stops: [] })
    expect(planRiderRoute(rider({ stops: [{ id: 'old-d', jobId: 'old', kind: 'dropoff', point: point(7) }] }), request, undefined, undefined, matrix)).toBeUndefined()
  })

  it('does not treat geometric closeness as road closeness', () => {
    const river: RoadMatrix = (a, b) => a.latitude === 0 && b.latitude === 2
      ? { minutes: 40, kilometres: 2 }
      : matrix(a, b)
    expect(planRiderRoute(rider(), request, river)).toBeUndefined()
  })

  it('retains one candidate per company with stable rider-id tie break', () => {
    const a = planRiderRoute(rider({ riderId: 'a' }), request, matrix)!
    const b = planRiderRoute(rider({ riderId: 'b' }), request, matrix)!
    const c = planRiderRoute(rider({ riderId: 'c', companyId: 'other' }), request, matrix)!
    expect(bestPerCompany([b, c, a]).map(p => p.riderId)).toEqual(['a', 'c'])
  })

  it('prioritizes nearby route fit, then distant route fit, before a closer rider on the wrong route', () => {
    const base = planRiderRoute(rider(), request, matrix)!
    const nearbyAligned = { ...base, riderId: 'near-aligned', tier: 1 as const, pickupEtaMinute: 8 }
    const distantAligned = { ...base, riderId: 'far-aligned', tier: 2 as const, pickupEtaMinute: 22 }
    const nearbyWrongRoute = { ...base, riderId: 'near-wrong', tier: 3 as const, pickupEtaMinute: 2 }
    expect([nearbyWrongRoute, distantAligned, nearbyAligned].sort(compareProposals).map(p => p.riderId))
      .toEqual(['near-aligned', 'far-aligned', 'near-wrong'])
  })
  it('does not rank an otherwise equal route by delay to an existing parcel', () => {
    const base = planRiderRoute(rider(), request, matrix)!
    const delayed = { ...base, riderId: 'a', maxExistingDelayMinutes: 8, sumExistingDelayMinutes: 8 }
    const noDelay = { ...base, riderId: 'b', maxExistingDelayMinutes: 0, sumExistingDelayMinutes: 0 }
    expect([noDelay, delayed].sort(compareProposals).map(p => p.riderId)).toEqual(['a', 'b'])
  })
})
