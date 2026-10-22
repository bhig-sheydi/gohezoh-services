import { describe, expect, it } from 'vitest'
import {
  bestPerCompany, planRiderRoute,
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

  it('rejects missed existing promises', () => {
    const promised: Stop = { id: 'old-d', jobId: 'old', kind: 'dropoff', point: point(8), latestMinute: 8, baselineEtaMinute: 8 }
    const plan = planRiderRoute(rider({ stops: [promised] }), { ...request, dropoff: { ...dropoff, point: point(15) } }, matrix)
    expect(plan?.stops.findIndex(s => s.id === 'old-d')).toBeLessThan(plan!.stops.findIndex(s => s.id === 'new-d'))
  })

  it('excludes full riders without removing them from duty or imposing fabricated box capacity', () => {
    expect(planRiderRoute(rider({ loadState: 'full' }), request, matrix)).toBeUndefined()
    expect(planRiderRoute(rider({ loadState: 'almost_full' }), request, matrix)?.loadState).toBe('almost_full')
  })

  it('rejects stale or inaccurate GPS without inventing a parcel-count capacity', () => {
    expect(planRiderRoute(rider({ locationAgeSeconds: 121 }), request, matrix)).toBeUndefined()
    expect(planRiderRoute(rider({ locationAccuracyMetres: 101 }), request, matrix)).toBeUndefined()
    expect(planRiderRoute(rider({ activePickupCount: 5 }), request, matrix)).toBeDefined()
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
})
