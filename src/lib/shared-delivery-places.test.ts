import { expect, it, vi } from 'vitest'
import type { SupabaseClient } from '@supabase/supabase-js'
import { searchSharedDeliveryPlaces } from './shared-delivery-places'

const clientFor = (data: unknown, error: unknown = null) => ({
  rpc: vi.fn(() => {
    const result = Promise.resolve({ data, error })
    return Object.assign(result, { abortSignal: () => result })
  }),
}) as unknown as SupabaseClient

it('converts a saved place to a confirmable suggestion with coordinates', async () => {
  const client = clientFor([{ id: 'test', label: 'Orji Woko Close', city: 'Port Harcourt', state: 'Rivers',
    latitude: 4.882269, longitude: 7.0096482, distance_metres: 12 }])
  const results = await searchSharedDeliveryPlaces(client, '', 'Port Harcourt', { latitude: 4.88227, longitude: 7.00965 })
  expect(client.rpc).toHaveBeenCalledWith('search_shared_delivery_places', {
    p_query: '', p_city: 'Port Harcourt', p_latitude: 4.88227, p_longitude: 7.00965, p_limit: 8,
  })
  expect(results[0]).toMatchObject({ address: 'Orji Woko Close', distanceMetres: 12,
    evidence: { latitude: 4.882269, longitude: 7.0096482, source: 'saved' } })
})

it('drops malformed results instead of exposing an invalid pin', async () => {
  const client = clientFor([{ id: 'test', label: 'Bad place', city: 'Port Harcourt', state: 'Rivers',
    latitude: 999, longitude: 7, distance_metres: null }])
  expect(await searchSharedDeliveryPlaces(client, 'Bad place', 'Port Harcourt')).toEqual([])
})

it('surfaces database failures so the caller can fall back to the map provider', async () => {
  const client = clientFor(null, { message: 'unavailable' })
  await expect(searchSharedDeliveryPlaces(client, 'Orji Woko', 'Port Harcourt')).rejects.toThrow('Saved places are unavailable')
})
