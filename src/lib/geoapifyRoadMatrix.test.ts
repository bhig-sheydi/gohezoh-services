import { describe, expect, it, vi } from 'vitest'
import { geoapifyRoadMatrix } from '../../supabase/functions/_shared/geoapify-road-matrix'

const a = { latitude: 4.8, longitude: 7.0 }
const b = { latitude: 4.81, longitude: 7.02 }

describe('Geoapify road matrix adapter', () => {
  it('uses road seconds/metres, longitude-first requests, and reserves credits', async () => {
    const reserve = vi.fn(async () => true)
    const fetcher = vi.fn(async (_url: string, init: RequestInit) => {
      expect(JSON.parse(String(init.body))).toMatchObject({ mode: 'drive', sources: [{ location: [7, 4.8] }, { location: [7.02, 4.81] }] })
      return Response.json({ sources_to_targets: [[{ time: 0, distance: 0 }, { time: 600, distance: 4000 }],
        [{ time: 720, distance: 4700 }, { time: 0, distance: 0 }]] })
    }) as unknown as typeof fetch
    const matrix = await geoapifyRoadMatrix([a, b, a], 'key', reserve, fetcher)
    expect(reserve).toHaveBeenCalledWith(4)
    expect(matrix?.(a, b)).toEqual({ minutes: 10, kilometres: 4 })
    expect(matrix?.(b, a)).toEqual({ minutes: 12, kilometres: 4.7 })
  })

  it('does not call the provider when the daily budget refuses a reservation', async () => {
    const fetcher = vi.fn()
    expect(await geoapifyRoadMatrix([a, b], 'key', async () => false, fetcher)).toBeUndefined()
    expect(fetcher).not.toHaveBeenCalled()
  })

  it('does not invent a road leg for null or invalid provider cells', async () => {
    const response = Response.json({ sources_to_targets: [[{ time: 0, distance: 0 }, { time: null, distance: null }],
      [{ time: 100, distance: 200 }, { time: 0, distance: 0 }]] })
    const matrix = await geoapifyRoadMatrix([a, b], 'key', async () => true, vi.fn(async () => response) as unknown as typeof fetch)
    expect(matrix?.(a, b)).toBeUndefined()
    expect(matrix?.(b, a)).toEqual({ minutes: 100 / 60, kilometres: 0.2 })
  })

  it('uses a zero-minute leg for coincident coordinates without spending credits', async () => {
    const reserve = vi.fn()
    const fetcher = vi.fn()
    const matrix = await geoapifyRoadMatrix([a, a], 'key', reserve, fetcher)
    expect(matrix?.(a, a)).toEqual({ minutes: 0, kilometres: 0 })
    expect(matrix?.(a, b)).toBeUndefined()
    expect(reserve).not.toHaveBeenCalled()
    expect(fetcher).not.toHaveBeenCalled()
  })
})
