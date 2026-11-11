import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { SupabaseClient } from '@supabase/supabase-js'
import DeliveryPoint from './DeliveryPoint'
import { searchAddress, suggestAddresses, suggestNearby } from './lib/geoapify-geocoding'
import { requestAddressPosition } from './lib/proximity'

vi.mock('./PinCorrection', () => ({ default: () => <div aria-label="Map correction" /> }))
vi.mock('./lib/proximity', () => ({ requestAddressPosition: vi.fn(), LocationError: class LocationError extends Error {} }))
vi.mock('./lib/geoapify-geocoding', () => ({ suggestAddresses: vi.fn(), suggestNearby: vi.fn(), searchAddress: vi.fn(), reverseAddress: vi.fn(), identifyCurrentLocation: vi.fn() }))
const result = { address: 'Market Road', city: 'Port Harcourt', state: 'Rivers', latitude: 4.831, longitude: 7.021,
  specificity: 'street', resultType: 'street', confidence: null, distanceMetres: null,
  evidence: { latitude: 4.831, longitude: 7.021, accuracyMetres: null, capturedAt: 1000, source: 'search' }, qualityNote: '' }
const supabase = {} as SupabaseClient
const clientWithSaved = (saved: unknown[]) => {
  const query = { select: () => query, eq: () => query, order: async () => ({ data: saved, error: null }) }
  return { from: () => query } as unknown as SupabaseClient
}
beforeEach(() => { vi.clearAllMocks(); vi.mocked(suggestAddresses).mockResolvedValue([result] as never); vi.mocked(suggestNearby).mockResolvedValue([]) })

describe('one-field drop-off location', () => {
  it('reuses the signed-in customer saved drop-off coordinates without a map lookup', async () => {
    const onCitySelected = vi.fn()
    const saved = { slot: 2, label: 'Home', address: '12 Market Road', city: 'Port Harcourt', state: 'Rivers',
      latitude: 4.83, longitude: 7.02, location_source: 'search', location_accuracy_metres: null }
    render(<form><select name="delivery_city" defaultValue="Port Harcourt"><option>Port Harcourt</option></select>
      <DeliveryPoint supabase={clientWithSaved([saved])} userId="customer-1" onCitySelected={onCitySelected} /></form>)
    await userEvent.setup().selectOptions(await screen.findByLabelText('My delivery addresses'), '2')
    expect(screen.getByRole('searchbox', { name: 'Drop-off place search' })).toHaveValue('12 Market Road')
    expect(document.querySelector('[name=delivery_latitude]')).toHaveValue('4.83')
    expect(document.querySelector('[name=delivery_longitude]')).toHaveValue('7.02')
    expect(document.querySelector('[name=pickup_saved_slot]')).toBeNull()
    expect(onCitySelected).toHaveBeenCalledWith('Port Harcourt')
    expect(suggestAddresses).not.toHaveBeenCalled()
  })
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
    expect(screen.getByLabelText('This is the delivery location.')).toBeDisabled()
  })
  it('does not offer current-phone GPS for the drop-off', () => {
    render(<form><select name="delivery_city" defaultValue="Port Harcourt"><option>Port Harcourt</option></select><DeliveryPoint supabase={supabase} /></form>)
    expect(screen.queryByRole('button', { name: /I'm here/ })).toBeNull()
  })
})
