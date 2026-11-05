import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, expect, it, vi } from 'vitest'
import type { SupabaseClient } from '@supabase/supabase-js'
import UnifiedLocationPicker from './UnifiedLocationPicker'
import { googleAutocomplete } from './lib/google-geocoding'
import { suggestAddresses } from './lib/geoapify-geocoding'

vi.mock('./PinCorrection', () => ({ default: () => <div aria-label="Map correction" /> }))
vi.mock('./lib/google-maps', () => ({ googleMapsDemoEnabled: true }))
vi.mock('./lib/google-geocoding', () => ({ googleAutocomplete: vi.fn(), newGoogleAutocompleteSession: () => ({}) }))
vi.mock('./lib/geoapify-geocoding', () => ({ suggestAddresses: vi.fn(), suggestNearby: vi.fn(), searchAddress: vi.fn(), identifyCurrentLocation: vi.fn() }))
vi.mock('./lib/proximity', () => ({ requestAddressPosition: vi.fn() }))

beforeEach(() => { vi.clearAllMocks() })

it('resolves a named Nigerian place only after the customer selects its autocomplete prediction', async () => {
  const select = vi.fn(async () => ({ address: 'Divine Benevolent Care Organisation', city: 'Port Harcourt', state: 'Rivers',
    latitude: 4.8821755, longitude: 7.0098946, specificity: 'area', resultType: 'amenity', confidence: null, distanceMetres: null,
    evidence: { latitude: 4.8821755, longitude: 7.0098946, accuracyMetres: null, capturedAt: 1000, source: 'search' }, qualityNote: '' }))
  vi.mocked(googleAutocomplete).mockResolvedValue([{ address: 'Divine Benevolent Care Organisation', detail: 'Eliozu, Port Harcourt, Nigeria',
    placeId: 'divine-benevolent-care', select }] as never)
  render(<form><select name="pickup_city" defaultValue="Port Harcourt"><option>Port Harcourt</option></select>
    <UnifiedLocationPicker kind="pickup" supabase={{} as SupabaseClient} /></form>)
  await userEvent.setup().type(screen.getByRole('searchbox', { name: 'Pickup place search' }), 'Divine Benevolent')
  expect(document.querySelector('[name=pickup_latitude]')).toBeNull()
  expect(await screen.findByText('Google Maps')).toBeVisible()
  await userEvent.setup().click(await screen.findByRole('button', { name: /Divine Benevolent Care Organisation/ }))
  expect(select).toHaveBeenCalledOnce()
  expect(document.querySelector('[name=pickup_latitude]')).toHaveValue('4.8821755')
  expect(document.querySelector('[name=pickup_longitude]')).toHaveValue('7.0098946')
  expect(suggestAddresses).not.toHaveBeenCalled()
})
