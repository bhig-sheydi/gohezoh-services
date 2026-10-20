import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { SupabaseClient } from '@supabase/supabase-js'
import DeliveryPoint from './DeliveryPoint'
import { searchAddress, suggestAreas, suggestNearby } from './lib/geoapify-geocoding'

vi.mock('./lib/geoapify-geocoding', () => ({
  searchAddress: vi.fn(), suggestAreas: vi.fn(), suggestAddresses: vi.fn(), suggestNearby: vi.fn().mockResolvedValue([]), reverseAddress: vi.fn().mockResolvedValue(null), mapTile: vi.fn().mockResolvedValue(new Blob()),
}))

const supabase = { functions: { invoke: vi.fn().mockResolvedValue({ data: { url: '' }, error: null }) } } as unknown as SupabaseClient
beforeEach(() => { vi.clearAllMocks(); vi.mocked(suggestNearby).mockResolvedValue([]); vi.mocked(suggestAreas).mockResolvedValue([]) })

describe('delivery point', () => {
  it('selects a street suggestion without opening the map or finding the address', async () => {
    const destination = { slot: 2, label: 'Home', address: 'Old Road', city: 'Lagos', state: 'Lagos', secondary_phone: null,
      latitude: 6.45, longitude: 3.4, location_source: 'browser', location_accuracy_metres: 20 }
    vi.mocked(suggestNearby).mockResolvedValue([{ address: 'Market Road', city: 'Lagos', state: 'Lagos', specificity: 'street', resultType: 'street',
      latitude: 6.46, longitude: 3.41, confidence: 0.9, distanceMetres: null,
      evidence: { latitude: 6.46, longitude: 3.41, accuracyMetres: null, capturedAt: Date.now(), source: 'search' }, qualityNote: '' }])
    render(<form><DeliveryPoint supabase={supabase} destination={destination} onCitySelected={vi.fn()} /></form>)
    expect(screen.queryByRole('button', { name: 'Drag or tap map to choose a point' })).toBeNull()
    const street = screen.getByRole('textbox', { name: 'Street name' })
    await userEvent.setup().clear(street)
    await userEvent.setup().type(street, 'Market')
    expect(await screen.findByText(/Searching streets — wait for a suggestion/)).toBeInTheDocument()
    await userEvent.setup().click(await screen.findByRole('button', { name: 'Market Road, Lagos' }))
    expect(document.querySelector('[name=delivery_latitude]')).toHaveValue('6.46')
    expect(screen.getByLabelText('This is the delivery location.')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Adjust pin on map (optional)' })).toBeInTheDocument()
  })
  it('starts from a Parcel Pal saved point and invalidates it when the street changes', async () => {
    const destination = { slot: 2, label: 'Home', address: '12 Market Road', city: 'Lagos', state: 'Lagos', secondary_phone: null,
      latitude: 6.45, longitude: 3.4, location_source: 'browser', location_accuracy_metres: 20 }
    render(<form><DeliveryPoint supabase={supabase} destination={destination} onCitySelected={vi.fn()} /></form>)
    expect(document.querySelector('[name=delivery_latitude]')).toHaveValue('6.45')
    const street = screen.getByRole('textbox', { name: 'Street name' })
    expect(street).toHaveValue('12 Market Road')
    await userEvent.setup().type(street, ' changed')
    expect(document.querySelector('[name=delivery_latitude]')).toBeNull()
    expect(street).toHaveValue('12 Market Road changed')
  })

  it('suggests a delivery community, then searches its street and requires pin correction for broad results', async () => {
    const user = userEvent.setup()
    vi.mocked(suggestAreas).mockResolvedValue([{ address: 'Eliozu', city: 'Port Harcourt', state: 'Rivers', specificity: 'area', resultType: 'suburb',
      latitude: 4.83, longitude: 7.02, confidence: null, distanceMetres: null, placeId: 'abcdef1234',
      evidence: { latitude: 4.83, longitude: 7.02, accuracyMetres: null, capturedAt: Date.now(), source: 'search' }, qualityNote: '' }])
    vi.mocked(searchAddress).mockResolvedValue({ address: 'Market Road', city: 'Port Harcourt', state: 'Rivers', specificity: 'area', resultType: 'city',
      latitude: 4.831, longitude: 7.021, confidence: 0.4, distanceMetres: null,
      evidence: { latitude: 4.831, longitude: 7.021, accuracyMetres: null, capturedAt: Date.now(), source: 'search' }, qualityNote: '' })
    render(<form><input name="delivery_community" aria-label="Delivery community" /><select name="delivery_city" defaultValue="Port Harcourt"><option>Port Harcourt</option></select>
      <DeliveryPoint supabase={supabase} onCitySelected={vi.fn()} /></form>)
    await user.type(screen.getByLabelText('Delivery community'), 'Eliozu')
    await user.click(await screen.findByRole('button', { name: /Eliozu/ }))
    expect(screen.getByLabelText('Delivery community')).toHaveValue('Eliozu')
    const street = screen.getByRole('textbox', { name: 'Street name' })
    await user.click(street)
    expect(street).toHaveFocus()
    await user.type(street, 'Market Road')
    await user.click(screen.getByRole('button', { name: 'Find delivery address' }))
    await screen.findByText(/Only a broad area was found/)
    expect(document.querySelector('.delivery-location .pin-correction')).toBeInTheDocument()
    expect(document.querySelector('[name=delivery_location_confirmed]')).toBeNull()
    await waitFor(() => expect(searchAddress).toHaveBeenCalledWith(supabase, 'Market Road', expect.any(AbortSignal), 'abcdef1234'))
  })
})
