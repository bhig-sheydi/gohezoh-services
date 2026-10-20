import { describe, expect, it, vi } from 'vitest'
import type { SupabaseClient } from '@supabase/supabase-js'
import { suggestAreas } from './geoapify-geocoding'

const area = (address: string, resultType: string) => ({
  address, resultType, city: 'Port Harcourt', state: 'Rivers', latitude: 4.83, longitude: 7.02,
  specificity: resultType === 'street' ? 'street' : 'area', confidence: 0.9, distanceMetres: null,
})

describe('area suggestions', () => {
  it('uses neighbourhood matches and does not show an unrelated city', async () => {
    const invoke = vi.fn().mockResolvedValue({ data: { suggestions: [area('Eliozu', 'suburb'), area('Port Harcourt', 'city')] }, error: null })
    const client = { functions: { invoke } } as unknown as SupabaseClient
    expect((await suggestAreas(client, 'Eliozu')).map((item) => item.address)).toEqual(['Eliozu'])
    expect(invoke).toHaveBeenCalledTimes(1)
    expect(invoke).toHaveBeenCalledWith('location-address', expect.objectContaining({ body: expect.objectContaining({ type: 'locality' }) }))
    expect(invoke).toHaveBeenCalledWith('location-address', expect.objectContaining({ body: expect.objectContaining({ text: 'Eliozu' }) }))
  })

  it('falls back to a locally named road axis such as Ada George', async () => {
    const invoke = vi.fn()
      .mockResolvedValueOnce({ data: null, error: { context: new Response(null, { status: 404 }) } })
      .mockResolvedValueOnce({ data: { suggestions: [area('Ada-George Road', 'street')] }, error: null })
    const client = { functions: { invoke } } as unknown as SupabaseClient
    expect((await suggestAreas(client, 'Ada George')).map((item) => item.address)).toEqual(['Ada-George Road'])
    expect(invoke).toHaveBeenCalledTimes(2)
  })

  it('accepts the mapped Rumuaholu spelling for Rumuagholu', async () => {
    const invoke = vi.fn().mockResolvedValue({ data: { suggestions: [area('Rumuaholu', 'city')] }, error: null })
    const client = { functions: { invoke } } as unknown as SupabaseClient
    expect((await suggestAreas(client, 'Rumuagholu')).map((item) => item.address)).toEqual(['Rumuaholu'])
  })

  it('accepts Ada George when the provider labels it an amenity', async () => {
    const invoke = vi.fn()
      .mockResolvedValueOnce({ data: null, error: { context: new Response(null, { status: 404 }) } })
      .mockResolvedValueOnce({ data: { suggestions: [area('Ada George', 'amenity')] }, error: null })
    const client = { functions: { invoke } } as unknown as SupabaseClient
    expect((await suggestAreas(client, 'Ada George')).map((item) => item.address)).toEqual(['Ada George'])
  })
})
