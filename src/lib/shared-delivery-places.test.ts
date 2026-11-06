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

it('coalesces concurrent text lookups and reuses a recent result without another database read', async () => {
  let finish!: (value: { data: unknown[]; error: null }) => void
  const response = new Promise<{ data: unknown[]; error: null }>((resolve) => { finish = resolve })
  const client = { rpc: vi.fn(() => Object.assign(response, { abortSignal: () => response })) } as unknown as SupabaseClient
  const aborted = new AbortController()
  const first = searchSharedDeliveryPlaces(client, 'Orji Woko', 'Port Harcourt', undefined, aborted.signal)
  const second = searchSharedDeliveryPlaces(client, 'orji  woko', 'port harcourt')
  expect(client.rpc).toHaveBeenCalledOnce()
  aborted.abort()
  await expect(first).rejects.toMatchObject({ name: 'AbortError' })
  finish({ data: [{ id: 'test', label: 'Orji Woko Close', city: 'Port Harcourt', state: 'Rivers',
    latitude: 4.882269, longitude: 7.0096482, distance_metres: null }], error: null })
  expect((await second)[0].address).toBe('Orji Woko Close')
  expect((await searchSharedDeliveryPlaces(client, 'Orji Woko', 'Port Harcourt'))[0].address).toBe('Orji Woko Close')
  expect(client.rpc).toHaveBeenCalledOnce()
})

it('does not retry a recent empty text result on every repeated Find click', async () => {
  const client = clientFor([])
  expect(await searchSharedDeliveryPlaces(client, 'Okemini', 'Port Harcourt')).toEqual([])
  expect(await searchSharedDeliveryPlaces(client, 'okemini', 'port harcourt')).toEqual([])
  expect(client.rpc).toHaveBeenCalledOnce()
})

it('drops text-search cache when the Supabase client changes user sessions', async () => {
  let authChanged!: (event: 'SIGNED_OUT' | 'SIGNED_IN') => void
  const client = { ...clientFor([]), auth: { onAuthStateChange: vi.fn((callback: (event: 'SIGNED_OUT' | 'SIGNED_IN') => void) => {
    authChanged = callback
    return { data: { subscription: { unsubscribe: vi.fn() } } }
  }) } } as unknown as SupabaseClient
  await searchSharedDeliveryPlaces(client, 'Okemini', 'Port Harcourt')
  authChanged('SIGNED_OUT')
  await searchSharedDeliveryPlaces(client, 'Okemini', 'Port Harcourt')
  expect(client.rpc).toHaveBeenCalledTimes(2)
})
