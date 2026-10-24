import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { SupabaseClient } from '@supabase/supabase-js'
import DeliveryPoint from './DeliveryPoint'
import { identifyCurrentLocation, searchAddress, suggestAddresses, suggestNearby } from './lib/geoapify-geocoding'
import { requestAddressPosition } from './lib/proximity'

vi.mock('./PinCorrection', () => ({ default: () => <div aria-label="Map correction" /> }))
vi.mock('./lib/proximity', () => ({ requestAddressPosition: vi.fn() }))
vi.mock('./lib/geoapify-geocoding', () => ({ suggestAddresses: vi.fn(), suggestNearby: vi.fn(), searchAddress: vi.fn(), reverseAddress: vi.fn(), identifyCurrentLocation: vi.fn() }))
const result = { address: 'Market Road', city: 'Port Harcourt', state: 'Rivers', latitude: 4.831, longitude: 7.021,
  specificity: 'street', resultType: 'street', confidence: null, distanceMetres: null,
  evidence: { latitude: 4.831, longitude: 7.021, accuracyMetres: null, capturedAt: 1000, source: 'search' }, qualityNote: '' }
const supabase = {} as SupabaseClient
beforeEach(() => { vi.clearAllMocks(); vi.mocked(suggestAddresses).mockResolvedValue([result] as never); vi.mocked(suggestNearby).mockResolvedValue([]) })

describe('one-field drop-off location', () => {
  it('keeps a Parcel Pal point until the user edits the single search', async () => {
    const destination = { slot: 2, label: 'Home', address: '12 Market Road', city: 'Port Harcourt', state: 'Rivers', secondary_phone: null,
      latitude: 4.83, longitude: 7.02, location_source: 'browser', location_accuracy_metres: 20 }
    render(<form><select name="delivery_city" defaultValue="Port Harcourt"><option>Port Harcourt</option></select><DeliveryPoint supabase={supabase} destination={destination} /></form>)
    const input = screen.getByRole('searchbox', { name: 'Drop-off place search' })
    expect(input).toHaveValue('12 Market Road')
    expect(document.querySelector('[name=delivery_latitude]')).toHaveValue('4.83')
    await userEvent.setup().type(input, ' changed')
    expect(document.querySelector('[name=delivery_latitude]')).toBeNull()
  })
  it('falls back to city text search when phone location is unavailable', async () => {
    const user = userEvent.setup()
    vi.mocked(requestAddressPosition).mockRejectedValue(new Error('Permission denied'))
    vi.mocked(searchAddress).mockResolvedValue(result as never)
    render(<form><select name="delivery_city" defaultValue="Port Harcourt"><option>Port Harcourt</option></select><DeliveryPoint supabase={supabase} /></form>)
    await user.type(screen.getByRole('searchbox', { name: 'Drop-off place search' }), 'Market Road')
    await user.click(screen.getByRole('button', { name: 'Find location' }))
    await waitFor(() => expect(searchAddress).toHaveBeenCalledWith(supabase, 'Market Road, Port Harcourt, Nigeria', expect.any(AbortSignal)))
    expect(document.querySelector('[name=delivery_latitude]')).toHaveValue('4.831')
    expect(screen.getByLabelText('This is the delivery location.')).toBeInTheDocument()
  })
  it('requires a corrected pin for an area-only result', async () => {
    const user = userEvent.setup()
    vi.mocked(suggestAddresses).mockResolvedValue([])
    vi.mocked(requestAddressPosition).mockRejectedValue(new Error('Permission denied'))
    vi.mocked(searchAddress).mockResolvedValue({ ...result, specificity: 'area' } as never)
    render(<form><select name="delivery_city" defaultValue="Port Harcourt"><option>Port Harcourt</option></select><DeliveryPoint supabase={supabase} /></form>)
    await user.type(screen.getByRole('searchbox', { name: 'Drop-off place search' }), 'Market Road')
    await user.click(screen.getByRole('button', { name: 'Find location' }))
    expect(await screen.findByText(/Only a broad area was found/)).toBeInTheDocument()
    expect(document.querySelector('[name=delivery_location_confirmed]')).toBeNull()
  })
  it('shows a nearby named place with the phone point rather than the place point', async () => {
    const user = userEvent.setup()
    vi.mocked(requestAddressPosition).mockResolvedValue({ latitude: 4.882269, longitude: 7.0096482, accuracyMetres: 15, capturedAt: 1000, source: 'browser' } as never)
    vi.mocked(identifyCurrentLocation).mockResolvedValue({ label: 'Near Divine Benevolent Care Organisation', landmarkDistanceMetres: 29, matchedAddress: null })
    render(<form><select name="delivery_city" defaultValue="Port Harcourt"><option>Port Harcourt</option></select><DeliveryPoint supabase={supabase} /></form>)
    await user.click(screen.getByRole('button', { name: /I'm here/ }))
    expect(await screen.findByRole('searchbox', { name: 'Drop-off place search' })).toHaveValue('Near Divine Benevolent Care Organisation')
    expect(document.querySelector('[name=delivery_latitude]')).toHaveValue('4.882269')
    expect(document.querySelector('[name=delivery_longitude]')).toHaveValue('7.0096482')
    expect(screen.getByText(/Named place 29 m away/)).toBeInTheDocument()
  })
})
