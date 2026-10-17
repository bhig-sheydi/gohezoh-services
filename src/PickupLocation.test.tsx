import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { SupabaseClient } from '@supabase/supabase-js'
import PickupLocation from './PickupLocation'
import { mapTile, reverseAddress, suggestAddresses, suggestNearby, type AddressSuggestion } from './lib/geoapify-geocoding'

vi.mock('./lib/geoapify-geocoding', () => ({ mapTile: vi.fn(), reverseAddress: vi.fn(), suggestAddresses: vi.fn(), suggestNearby: vi.fn() }))

const community: AddressSuggestion = {
  address: 'Eliozu', city: 'Port Harcourt', state: 'Rivers', latitude: 4.83, longitude: 7.02,
  placeId: '51f07665660fc4024059dc0a96dfac6c', specificity: 'area', resultType: 'suburb',
  distanceMetres: null, confidence: 0.9, qualityNote: '',
  evidence: { latitude: 4.83, longitude: 7.02, accuracyMetres: null, capturedAt: Date.now(), source: 'search' },
}
const street: AddressSuggestion = {
  ...community, address: 'Orji Woko Close', latitude: 4.831, longitude: 7.021,
  specificity: 'street', resultType: 'street',
  evidence: { ...community.evidence, latitude: 4.831, longitude: 7.021 },
}

beforeEach(() => {
  vi.mocked(mapTile).mockResolvedValue(new Blob(['map'], { type: 'image/png' }))
  vi.mocked(reverseAddress).mockResolvedValue(street)
  vi.mocked(suggestAddresses).mockResolvedValue([community])
  vi.mocked(suggestNearby).mockResolvedValue([street])
  vi.stubGlobal('URL', { ...URL, createObjectURL: vi.fn(() => 'blob:map'), revokeObjectURL: vi.fn() })
})

describe('pickup location selection', () => {
  it('uses the always-visible pin picker as the only pickup street field', async () => {
    const query = { select: () => query, eq: () => query, order: async () => ({ data: [], error: null }) }
    render(<form><select name="pickup_city" defaultValue="Port Harcourt"><option>Port Harcourt</option></select>
      <input name="pickup_community" aria-label="Pickup community" />
      <PickupLocation supabase={{ from: () => query } as unknown as SupabaseClient} userId="user-1" onCitySelected={vi.fn()} /></form>)
    const user = userEvent.setup()
    expect(document.querySelector('.pickup-location .pin-correction')).toBeInTheDocument()
    expect(document.querySelectorAll('[name=pickup_address]')).toHaveLength(1)
    await user.type(screen.getByLabelText('Pickup community'), 'Eliozu')
    await user.click(await screen.findByRole('button', { name: /Eliozu/ }))
    await user.type(screen.getByRole('textbox', { name: 'Street name' }), 'Orji')
    await user.click(await screen.findByRole('button', { name: /Orji Woko Close/ }))
    expect(screen.getByRole('textbox', { name: 'Street name' })).toHaveValue('Orji Woko Close')
    await user.click(screen.getByRole('button', { name: 'Use this pin' }))
    await waitFor(() => expect(document.querySelector('[name=pickup_latitude]')).toHaveValue('4.831'))
    expect(new FormData(document.querySelector('form')!).get('pickup_address')).toBe('Orji Woko Close')
  })

  it('fills the same street picker from a saved address and clears the old pin when edited', async () => {
    const saved = [{ slot: 1, label: 'Work', address: '12 Market Road', city: 'Lagos', state: 'Lagos',
      latitude: 6.45, longitude: 3.4, location_source: 'browser', location_accuracy_metres: 18 }]
    const query = { select: () => query, eq: () => query, order: async () => ({ data: saved, error: null }) }
    const onCitySelected = vi.fn()
    render(<form><input name="pickup_community" /><PickupLocation supabase={{ from: () => query } as unknown as SupabaseClient} userId="user-1" onCitySelected={onCitySelected} /></form>)
    const user = userEvent.setup()
    await user.selectOptions(await screen.findByLabelText('My pickup addresses'), '1')
    expect(screen.getByRole('textbox', { name: 'Street name' })).toHaveValue('12 Market Road')
    expect(onCitySelected).toHaveBeenCalledWith('Lagos')
    expect(document.querySelector('[name=pickup_latitude]')).toHaveValue('6.45')
    await user.clear(screen.getByRole('textbox', { name: 'Street name' }))
    await user.type(screen.getByRole('textbox', { name: 'Street name' }), 'Other street')
    expect(document.querySelector('[name=pickup_latitude]')).toBeNull()
  })
})
