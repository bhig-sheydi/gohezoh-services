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
beforeEach(() => { vi.clearAllMocks(); vi.mocked(suggestAddresses).mockResolvedValue([result] as never); vi.mocked(suggestNearby).mockResolvedValue([]) })

describe('one-field drop-off location', () => {
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
    expect(screen.getByLabelText('This is the delivery location.')).toBeEnabled()
  })
  it('does not offer current-phone GPS for the drop-off', () => {
    render(<form><select name="delivery_city" defaultValue="Port Harcourt"><option>Port Harcourt</option></select><DeliveryPoint supabase={supabase} /></form>)
    expect(screen.queryByRole('button', { name: /I'm here/ })).toBeNull()
  })
})
