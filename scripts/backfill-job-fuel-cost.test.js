import { describe, expect, it, vi } from 'vitest'
import { fuelCostNgn, googleRoadDistanceMetres } from './backfill-job-fuel-cost.mjs'

describe('job fuel estimates', () => {
  it('uses road distance, consumption, and pump price without changing the bid', () => {
    expect(fuelCostNgn(10000)).toBe(350)
    expect(fuelCostNgn(1250)).toBe(43.75)
  })

  it('requests driving distance with a narrow field mask', async () => {
    const fetcher = vi.fn(async () => ({ ok: true, json: async () => ({ routes: [{ distanceMeters: 8000 }] }) }))
    const distance = await googleRoadDistanceMetres(
      { latitude: 4.882269, longitude: 7.0096482 },
      { latitude: 4.89, longitude: 7.02 }, 'test-key', fetcher)
    expect(distance).toBe(8000)
    expect(fetcher.mock.calls[0][1].headers['X-Goog-FieldMask']).toBe('routes.distanceMeters')
    expect(JSON.parse(fetcher.mock.calls[0][1].body).travelMode).toBe('DRIVE')
  })

  it('does not invent a distance when Google has no route', async () => {
    await expect(googleRoadDistanceMetres(
      { latitude: 4.8, longitude: 7 }, { latitude: 4.9, longitude: 7.1 }, 'test-key',
      async () => ({ ok: true, json: async () => ({ routes: [] }) }))).rejects.toThrow('no valid driving route')
  })
})
