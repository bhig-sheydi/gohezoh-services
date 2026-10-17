import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import type { SupabaseClient } from '@supabase/supabase-js'
import DeliveryPoint from './DeliveryPoint'
import { searchAddress } from './lib/geoapify-geocoding'

vi.mock('./lib/geoapify-geocoding', () => ({ searchAddress: vi.fn(), suggestAddresses: vi.fn() }))

describe('delivery point', () => {
  it('uses a Parcel Pal saved point but clears it when the destination address changes', async () => {
    const destination = { slot: 2, label: 'Home', address: '12 Market Road', city: 'Lagos', state: 'Lagos', secondary_phone: null,
      latitude: 6.45, longitude: 3.4, location_source: 'browser', location_accuracy_metres: 20 }
    render(<form><input name="delivery_address" aria-label="Delivery address" defaultValue={destination.address} />
      <DeliveryPoint supabase={{} as SupabaseClient} destination={destination} onCitySelected={vi.fn()} /></form>)
    expect((document.querySelector('[name=delivery_latitude]') as HTMLInputElement).value).toBe('6.45')
    await userEvent.setup().type(screen.getByLabelText('Delivery address'), ' changed')
    expect(document.querySelector('[name=delivery_latitude]')).toBeNull()
  })

  it('does not attach broad-area coordinates to the typed delivery street', async () => {
    vi.mocked(searchAddress).mockResolvedValueOnce({ address: 'Market Road', city: 'Lagos', state: 'Lagos', specificity: 'area', resultType: 'city', latitude: 6.45, longitude: 3.4,
      confidence: 0.4, distanceMetres: null, evidence: { latitude: 6.45, longitude: 3.4, accuracyMetres: null, capturedAt: Date.now(), source: 'search' }, qualityNote: '' })
    render(<form><input name="delivery_address" defaultValue="Market Road" /><select name="delivery_city" defaultValue="Lagos"><option>Lagos</option></select>
      <DeliveryPoint supabase={{} as SupabaseClient} onCitySelected={vi.fn()} /></form>)
    await userEvent.setup().click(screen.getByRole('button', { name: 'Find delivery street (optional)' }))
    expect(await screen.findByText(/Only a broad area was found/)).toBeInTheDocument()
    expect(document.querySelector('[name=delivery_latitude]')).toBeNull()
  })
})
