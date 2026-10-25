import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { SupabaseClient } from '@supabase/supabase-js'
import PickupLocation from './PickupLocation'
import { suggestAddresses, suggestNearby } from './lib/geoapify-geocoding'
import { requestAddressPosition } from './lib/proximity'

vi.mock('./PinCorrection', () => ({ default: () => <div aria-label="Map correction" /> }))
vi.mock('./lib/proximity', () => ({ requestAddressPosition: vi.fn() }))
vi.mock('./lib/geoapify-geocoding', () => ({ suggestAddresses: vi.fn(), suggestNearby: vi.fn(), searchAddress: vi.fn(), reverseAddress: vi.fn(), identifyCurrentLocation: vi.fn() }))
const match = { address: 'Eliozu Road', city: 'Port Harcourt', state: 'Rivers', latitude: 4.8661, longitude: 7.0219,
  specificity: 'street', resultType: 'street', confidence: null, distanceMetres: 50,
  evidence: { latitude: 4.8661, longitude: 7.0219, accuracyMetres: null, capturedAt: 1000, source: 'search' }, qualityNote: '' }
const client = (saved: unknown[] = []) => {
  const query = { select: () => query, eq: () => query, order: async () => ({ data: saved, error: null }) }
  return { from: () => query } as unknown as SupabaseClient
}
beforeEach(() => { vi.clearAllMocks(); vi.mocked(suggestAddresses).mockResolvedValue([match] as never); vi.mocked(suggestNearby).mockResolvedValue([]) })

describe('one-field pickup location', () => {
  it('shows one place search, then stores the selected mapped point', async () => {
    const user = userEvent.setup()
    render(<form><select name="pickup_city" defaultValue="Port Harcourt"><option>Port Harcourt</option></select><PickupLocation supabase={client()} userId="user-1" onCitySelected={vi.fn()} /></form>)
    const input = screen.getByRole('searchbox', { name: 'Pickup place search' })
    expect(input).toHaveAttribute('placeholder', 'Search the closest known place to you in Port Harcourt')
    expect(screen.queryByRole('textbox', { name: 'Street name' })).toBeNull()
    await user.type(input, 'Eliozu')
    await user.click(await screen.findByRole('button', { name: /Eliozu Road/ }))
    expect(input).toHaveValue('Eliozu Road')
    expect(document.querySelector('[name=pickup_latitude]')).toHaveValue('4.8661')
    expect(document.querySelector('[name=pickup_address]')).toHaveValue('Eliozu Road')
    expect(screen.getByLabelText('This is the pickup location.')).toBeInTheDocument()
    await user.clear(input)
    expect(document.querySelector('[name=pickup_latitude]')).toBeNull()
  })
  it('uses phone coordinates to narrow Find location, while preserving a saved address option', async () => {
    const saved = { slot: 1, label: 'Work', address: '12 Market Road', city: 'Port Harcourt', state: 'Rivers', latitude: 4.8, longitude: 7.0, location_source: 'browser', location_accuracy_metres: 18 }
    const user = userEvent.setup()
    vi.mocked(requestAddressPosition).mockResolvedValue({ latitude: 4.866, longitude: 7.022, accuracyMetres: 20, capturedAt: 1000, source: 'browser' } as never)
    vi.mocked(suggestNearby).mockResolvedValue([match] as never)
    render(<form><select name="pickup_city" defaultValue="Port Harcourt"><option>Port Harcourt</option></select><PickupLocation supabase={client([saved])} userId="user-1" onCitySelected={vi.fn()} /></form>)
    await user.selectOptions(await screen.findByLabelText('My pickup addresses'), '1')
    expect(document.querySelector('[name=pickup_latitude]')).toHaveValue('4.8')
    const input = screen.getByRole('searchbox', { name: 'Pickup place search' })
    await user.clear(input); await user.type(input, 'Eliozu')
    await user.click(screen.getByRole('button', { name: 'Find location' }))
    await waitFor(() => expect(suggestNearby).toHaveBeenCalled())
    expect(await screen.findByText(/Matched near your phone/)).toBeInTheDocument()
    expect(document.querySelector('[name=pickup_latitude]')).toHaveValue('4.8661')
  })
  it('does not treat a legacy saved address without coordinates as a selected pickup point', async () => {
    render(<form><select name="pickup_city" defaultValue="Port Harcourt"><option>Port Harcourt</option></select><PickupLocation supabase={client([{ slot: 1, label: 'Work', address: 'Old address', city: 'Port Harcourt', state: 'Rivers', latitude: null, longitude: null }])} userId="user-1" onCitySelected={vi.fn()} /></form>)
    await userEvent.setup().selectOptions(await screen.findByLabelText('My pickup addresses'), '1')
    expect(screen.getByRole('alert')).toHaveTextContent('no map point')
    expect(document.querySelector('[name=pickup_latitude]')).toBeNull()
  })
})
