import { describe, expect, it, vi } from 'vitest'
import { googleRoadMatrix } from '../../supabase/functions/_shared/google-road-matrix'

const a = { latitude: 4.8, longitude: 7.0 }
const b = { latitude: 4.81, longitude: 7.02 }
const element = (originIndex: number, destinationIndex: number, duration: string, distanceMeters: number) =>
  ({ originIndex, destinationIndex, status: {}, condition: 'ROUTE_EXISTS', duration, distanceMeters })
const response = () => [element(1, 0, '720s', 4700), element(0, 0, '0s', 0),
  element(1, 1, '0s', 0), element(0, 1, '600.5s', 4000)]

describe('Google Routes road matrix adapter', () => {
  it('reserves unique elements, sends a private-key request, and parses unordered road legs', async () => {
    const reserve = vi.fn(async () => true)
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
