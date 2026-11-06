import { describe, expect, it, vi } from 'vitest'
import { googleIdleRiderRoadMatrix, googleRoadMatrix, memoizeDeniedMatrixReservations } from '../../supabase/functions/_shared/google-road-matrix'
import { planRiderRoute, type RiderCandidate, type DeliveryRequest, type RoadMatrix } from '../../supabase/functions/_shared/rider-route-planner'

const a = { latitude: 4.8, longitude: 7.0 }
const b = { latitude: 4.81, longitude: 7.02 }
const c = { latitude: 4.82, longitude: 7.04 }
const element = (originIndex: number, destinationIndex: number, duration: string, distanceMeters: number) =>
  ({ originIndex, destinationIndex, status: {}, condition: 'ROUTE_EXISTS', duration, distanceMeters })
const response = () => [element(1, 0, '720s', 4700), element(0, 0, '0s', 0),
  element(1, 1, '0s', 0), element(0, 1, '600.5s', 4000)]

describe('Google Routes road matrix adapter', () => {
  it('reserves unique elements, sends a private-key request, and parses unordered road legs', async () => {
    const reserve = vi.fn(async (_elements: number) => true)
    const fetcher = vi.fn(async () => Response.json(response())) as unknown as typeof fetch
    const roads = await googleRoadMatrix([a, b, a], 'server-only-key', reserve, fetcher)
    expect(reserve).toHaveBeenCalledExactlyOnceWith(4)
    expect(fetcher).toHaveBeenCalledOnce()
    const [url, init] = vi.mocked(fetcher).mock.calls[0]
    expect(url).toBe('https://routes.googleapis.com/distanceMatrix/v2:computeRouteMatrix')
    expect(init?.headers).toMatchObject({ 'X-Goog-Api-Key': 'server-only-key',
      'X-Goog-FieldMask': 'originIndex,destinationIndex,status,condition,distanceMeters,duration' })
    expect(JSON.parse(String(init?.body))).toEqual({ origins: [
      { waypoint: { location: { latLng: a } } }, { waypoint: { location: { latLng: b } } },
    ], destinations: [
      { waypoint: { location: { latLng: a } } }, { waypoint: { location: { latLng: b } } },
    ], travelMode: 'DRIVE', routingPreference: 'TRAFFIC_UNAWARE' })
    expect(roads?.(a, b)).toEqual({ minutes: 600.5 / 60, kilometres: 4 })
    expect(roads?.(b, a)).toEqual({ minutes: 12, kilometres: 4.7 })
  })

  it('never calls Google when reservation fails or coordinates are invalid', async () => {
    const reserve = vi.fn(async () => false)
    const fetcher = vi.fn()
    expect(await googleRoadMatrix([a, b], 'key', reserve, fetcher)).toBeUndefined()
    expect(reserve).toHaveBeenCalledExactlyOnceWith(4)
    expect(await googleRoadMatrix([a, { latitude: 91, longitude: 0 }], 'key', reserve, fetcher)).toBeUndefined()
    expect(await googleRoadMatrix(Array.from({ length: 11 }, (_, i) => ({ latitude: i, longitude: 7 })),
      'key', reserve, fetcher)).toBeUndefined()
    expect(fetcher).not.toHaveBeenCalled()
  })

  it('returns a local zero leg for coincident coordinates without spending elements', async () => {
    const reserve = vi.fn()
    const fetcher = vi.fn()
    const roads = await googleRoadMatrix([a, { ...a }], 'key', reserve, fetcher)
    expect(roads?.(a, a)).toEqual({ minutes: 0, kilometres: 0 })
    expect(roads?.(a, b)).toBeUndefined()
    expect(reserve).not.toHaveBeenCalled()
    expect(fetcher).not.toHaveBeenCalled()
  })

  it('does not invent legs for failed statuses, no-route results, or malformed durations', async () => {
    const body = response()
    body[0] = { ...body[0], status: { code: 5, message: 'no route' } } as typeof body[number]
    body[3] = { ...body[3], condition: 'ROUTE_NOT_FOUND' }
    const fetcher = vi.fn(async () => Response.json(body)) as unknown as typeof fetch
    const roads = await googleRoadMatrix([a, b], 'key', async () => true, fetcher)
    expect(roads?.(b, a)).toBeUndefined()
    expect(roads?.(a, b)).toBeUndefined()
    expect(roads?.(a, a)).toEqual({ minutes: 0, kilometres: 0 })
    const badDuration = response()
    badDuration[3] = { ...badDuration[3], duration: '600ms' }
    const invalid = await googleRoadMatrix([a, b], 'key', async () => true,
      vi.fn(async () => Response.json(badDuration)) as unknown as typeof fetch)
    expect(invalid?.(a, b)).toBeUndefined()
  })

  it('accepts omitted proto3 zero values for the first indices and zero-length legs', async () => {
    const body = [
      { condition: 'ROUTE_EXISTS' },
      { destinationIndex: 1, condition: 'ROUTE_EXISTS', distanceMeters: 4000, duration: '600s' },
      { originIndex: 1, condition: 'ROUTE_EXISTS', distanceMeters: 4700, duration: '720s' },
      { originIndex: 1, destinationIndex: 1, condition: 'ROUTE_EXISTS' },
    ]
    const roads = await googleRoadMatrix([a, b], 'key', async () => true,
      vi.fn(async () => Response.json(body)) as unknown as typeof fetch)
    expect(roads?.(a, a)).toEqual({ minutes: 0, kilometres: 0 })
    expect(roads?.(a, b)).toEqual({ minutes: 10, kilometres: 4 })
    expect(roads?.(b, a)).toEqual({ minutes: 12, kilometres: 4.7 })
    expect(roads?.(b, b)).toEqual({ minutes: 0, kilometres: 0 })
  })

  it('rejects incomplete, duplicate, or out-of-range response elements', async () => {
    for (const body of [response().slice(0, 3), [...response().slice(0, 3), response()[0]],
      [...response().slice(0, 3), element(2, 1, '60s', 1000)]]) {
      const roads = await googleRoadMatrix([a, b], 'key', async () => true,
        vi.fn(async () => Response.json(body)) as unknown as typeof fetch)
      expect(roads).toBeUndefined()
    }
  })

  it('aborts a slow request after 3.5 seconds', async () => {
    vi.useFakeTimers()
    try {
      const fetcher = vi.fn((_url: string, init: RequestInit) => new Promise<Response>((_resolve, reject) => {
        init.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')))
      })) as unknown as typeof fetch
      const pending = googleRoadMatrix([a, b], 'key', async () => true, fetcher)
      await vi.advanceTimersByTimeAsync(3500)
      expect(await pending).toBeUndefined()
    } finally { vi.useRealTimers() }
  })

  it('also bounds a fetcher that ignores cancellation', async () => {
    vi.useFakeTimers()
    try {
      const fetcher = vi.fn(() => new Promise<Response>(() => {})) as unknown as typeof fetch
      const pending = googleRoadMatrix([a, b], 'key', async () => true, fetcher)
      await vi.advanceTimersByTimeAsync(3500)
      expect(await pending).toBeUndefined()
    } finally { vi.useRealTimers() }
  })
})

describe('sparse Google matrix for an idle rider', () => {
  it('reserves two elements, requests only required legs, and preserves planner output', async () => {
    const reserve = vi.fn(async (_elements: number) => true)
    const fetcher = vi.fn()
      .mockResolvedValueOnce(Response.json([element(0, 0, '480s', 2500)]))
      .mockResolvedValueOnce(Response.json([element(0, 0, '900s', 6800)])) as unknown as typeof fetch
    const sparse = await googleIdleRiderRoadMatrix(a, b, c, 'server-only-key', reserve, fetcher)
    expect(reserve).toHaveBeenCalledExactlyOnceWith(2)
    expect(fetcher).toHaveBeenCalledTimes(2)
    const bodies = vi.mocked(fetcher).mock.calls.map(([, init]) => JSON.parse(String(init?.body)))
    expect(bodies.map((body) => [body.origins[0].waypoint.location.latLng, body.destinations[0].waypoint.location.latLng]))
      .toEqual([[a, b], [b, c]])
    expect(bodies.every((body) => body.origins.length === 1 && body.destinations.length === 1)).toBe(true)
    expect(sparse?.(a, b)).toEqual({ minutes: 8, kilometres: 2.5 })
    expect(sparse?.(b, c)).toEqual({ minutes: 15, kilometres: 6.8 })
    expect(sparse?.(a, c)).toBeUndefined()
    const full: RoadMatrix = (from, to) => {
      if (from.latitude === a.latitude && to.latitude === b.latitude) return { minutes: 8, kilometres: 2.5 }
      if (from.latitude === b.latitude && to.latitude === c.latitude) return { minutes: 15, kilometres: 6.8 }
      return { minutes: 99, kilometres: 99 }
    }
    const rider: RiderCandidate = { riderId: 'rider-1', companyId: 'company-1', position: a,
      locationAgeSeconds: 15, locationAccuracyMetres: 10, onDuty: true, loadState: 'available',
      activePickupCount: 0, stops: [] }
    const request: DeliveryRequest = { jobId: 'job-1',
      pickup: { id: 'pickup', jobId: 'job-1', kind: 'pickup', point: b },
      dropoff: { id: 'dropoff', jobId: 'job-1', kind: 'dropoff', point: c } }
    expect(planRiderRoute(rider, request, sparse)).toEqual(planRiderRoute(rider, request, full))
  })

  it('does not call Google without budget and rejects a missing road leg', async () => {
    const fetcher = vi.fn()
    expect(await googleIdleRiderRoadMatrix(a, b, c, 'key', async () => false, fetcher)).toBeUndefined()
    expect(fetcher).not.toHaveBeenCalled()
    const invalid = vi.fn()
      .mockResolvedValueOnce(Response.json([element(0, 0, '480s', 2500)]))
      .mockResolvedValueOnce(Response.json([{ ...element(0, 0, '900s', 6800), condition: 'ROUTE_NOT_FOUND' }])) as unknown as typeof fetch
    expect(await googleIdleRiderRoadMatrix(a, b, c, 'key', async () => true, invalid)).toBeUndefined()
  })

  it('charges only one element when two required points coincide', async () => {
    const reserve = vi.fn(async (_elements: number) => true)
    const fetcher = vi.fn(async () => Response.json([element(0, 0, '900s', 6800)])) as unknown as typeof fetch
    const sparse = await googleIdleRiderRoadMatrix(a, { ...a }, c, 'key', reserve, fetcher)
    expect(reserve).toHaveBeenCalledExactlyOnceWith(1)
    expect(sparse?.(a, a)).toEqual({ minutes: 0, kilometres: 0 })
    expect(sparse?.(a, c)).toEqual({ minutes: 15, kilometres: 6.8 })
    const same = await googleIdleRiderRoadMatrix(a, { ...a }, { ...a }, 'key', reserve, fetcher)
    expect(same?.(a, a)).toEqual({ minutes: 0, kilometres: 0 })
    expect(reserve).toHaveBeenCalledOnce()
    expect(fetcher).toHaveBeenCalledOnce()
  })

  it('reuses one successful direct leg across idle candidates for the same order', async () => {
    const reserve = vi.fn(async (_elements: number) => true)
    const directLegCache = new Map()
    const riders = [a, { latitude: 4.83, longitude: 7.05 }, { latitude: 4.84, longitude: 7.06 }]
    const fetcher = vi.fn(async (_url: string, init: RequestInit) => {
      const body = JSON.parse(String(init.body))
      const from = body.origins[0].waypoint.location.latLng
      return Response.json([from.latitude === b.latitude
        ? element(0, 0, '900s', 6800) : element(0, 0, '480s', 2500)])
    }) as unknown as typeof fetch
    for (const rider of riders) {
      const roads = await googleIdleRiderRoadMatrix(rider, b, c, 'key', reserve, fetcher, directLegCache)
      expect(roads?.(rider, b)).toEqual({ minutes: 8, kilometres: 2.5 })
      expect(roads?.(b, c)).toEqual({ minutes: 15, kilometres: 6.8 })
    }
    expect(reserve.mock.calls.map(([count]) => count)).toEqual([2, 1, 1])
    expect(fetcher).toHaveBeenCalledTimes(4)
    expect(directLegCache.size).toBe(1)
  })

  it('does not cache a failed direct leg', async () => {
    const reserve = vi.fn(async (_elements: number) => true)
    const directLegCache = new Map()
    let directCalls = 0
    const fetcher = vi.fn(async (_url: string, init: RequestInit) => {
      const body = JSON.parse(String(init.body))
      const from = body.origins[0].waypoint.location.latLng
      if (from.latitude !== b.latitude) return Response.json([element(0, 0, '480s', 2500)])
      directCalls++
      return Response.json([{ ...element(0, 0, '900s', 6800),
        condition: directCalls === 1 ? 'ROUTE_NOT_FOUND' : 'ROUTE_EXISTS' }])
    }) as unknown as typeof fetch
    expect(await googleIdleRiderRoadMatrix(a, b, c, 'key', reserve, fetcher, directLegCache)).toBeUndefined()
    expect(directLegCache.size).toBe(0)
    expect((await googleIdleRiderRoadMatrix({ latitude: 4.83, longitude: 7.05 }, b, c,
      'key', reserve, fetcher, directLegCache))?.(b, c)).toEqual({ minutes: 15, kilometres: 6.8 })
    expect(reserve.mock.calls.map(([count]) => count)).toEqual([2, 2])
    expect(directCalls).toBe(2)
  })

  it('bounds both parallel requests to one 3.5-second deadline', async () => {
    vi.useFakeTimers()
    try {
      const fetcher = vi.fn(() => new Promise<Response>(() => {})) as unknown as typeof fetch
      const pending = googleIdleRiderRoadMatrix(a, b, c, 'key', async () => true, fetcher)
      await vi.advanceTimersByTimeAsync(3500)
      expect(await pending).toBeUndefined()
      expect(fetcher).toHaveBeenCalledTimes(2)
    } finally { vi.useRealTimers() }
  })
})

describe('per-invocation denied matrix budget memo', () => {
  it('skips reservations that cannot fit today but still tries smaller requests', async () => {
    let day = '2026-11-06'
    const backend = vi.fn(async (elements: number) => elements <= 2)
    const reserve = memoizeDeniedMatrixReservations(backend, () => day)
    expect(await reserve(4)).toBe(false)
    expect(await reserve(9)).toBe(false)
    expect(backend).toHaveBeenCalledTimes(1)
    expect(await reserve(2)).toBe(true)
    expect(await reserve(3)).toBe(false)
    expect(await reserve(3)).toBe(false)
    expect(backend.mock.calls.map(([elements]) => elements)).toEqual([4, 2, 3])
    day = '2026-11-07'
    expect(await reserve(4)).toBe(false)
    expect(backend.mock.calls.map(([elements]) => elements)).toEqual([4, 2, 3, 4])
  })

  it('does not memoize a reservation error', async () => {
    const backend = vi.fn()
      .mockRejectedValueOnce(new Error('Database unavailable'))
      .mockResolvedValueOnce(false)
    const reserve = memoizeDeniedMatrixReservations(backend, () => '2026-11-06')
    await expect(reserve(4)).rejects.toThrow('Database unavailable')
    expect(await reserve(4)).toBe(false)
    expect(backend).toHaveBeenCalledTimes(2)
  })
})
