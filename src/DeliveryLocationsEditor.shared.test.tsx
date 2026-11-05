import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, expect, it, vi } from 'vitest'
import type { SupabaseClient } from '@supabase/supabase-js'
import DeliveryLocationsEditor from './DeliveryLocationsEditor'
import { searchSharedDeliveryPlaces } from './lib/shared-delivery-places'
import { getAddressAtPosition, suggestAddresses } from './lib/geoapify-geocoding'
import { requestAddressPosition } from './lib/proximity'

vi.mock('./lib/shared-delivery-places', () => ({ searchSharedDeliveryPlaces: vi.fn() }))
vi.mock('./lib/geoapify-geocoding', () => ({ suggestAddresses: vi.fn(), getAddressAtPosition: vi.fn() }))
vi.mock('./lib/proximity', () => ({ requestAddressPosition: vi.fn() }))
vi.mock('./PinCorrection', () => ({ default: () => null }))

const place = { address: 'Orji Woko Close', city: 'Port Harcourt', state: 'Rivers', latitude: 4.882,
  longitude: 7.009, specificity: 'building' as const, resultType: 'community', distanceMetres: null,
  confidence: null, evidence: { latitude: 4.882, longitude: 7.009, accuracyMetres: null,
    capturedAt: 1, source: 'saved' as const }, qualityNote: 'Check this point.' }

beforeEach(() => { vi.clearAllMocks() })

function renderEditor() {
  render(<DeliveryLocationsEditor supabase={{} as SupabaseClient} userId="customer-1" destinations={[]}
    onSaved={async () => {}} onError={vi.fn()} onNotice={vi.fn()} />)
  return screen.getByText('Work').closest('form')!
}

it('shows a matching customer-contributed place without calling the map provider', async () => {
  vi.mocked(searchSharedDeliveryPlaces).mockResolvedValue([place])
  const card = renderEditor()
  const user = userEvent.setup()
  await user.type(within(card).getByLabelText('Address'), 'Orji Woko')
  await user.type(within(card).getByLabelText('City'), 'Port Harcourt')
  await user.click(within(card).getByRole('button', { name: 'Find options' }))
  expect(await within(card).findByRole('button', { name: /Orji Woko Close/ })).toBeVisible()
  expect(searchSharedDeliveryPlaces).toHaveBeenCalledOnce()
  expect(suggestAddresses).not.toHaveBeenCalled()
})

it('falls through to the map provider when the shared index has no match', async () => {
  vi.mocked(searchSharedDeliveryPlaces).mockResolvedValue([])
  vi.mocked(suggestAddresses).mockResolvedValue([place])
  const card = renderEditor()
  const user = userEvent.setup()
  await user.type(within(card).getByLabelText('Address'), 'Orji Woko')
  await user.type(within(card).getByLabelText('City'), 'Port Harcourt')
  await user.click(within(card).getByRole('button', { name: 'Find options' }))
  expect(await within(card).findByRole('button', { name: /Orji Woko Close/ })).toBeVisible()
  expect(searchSharedDeliveryPlaces).toHaveBeenCalledOnce()
  expect(suggestAddresses).toHaveBeenCalledOnce()
})

it('offers nearby saved places for GPS without choosing a neighbour or calling the map provider', async () => {
  vi.mocked(requestAddressPosition).mockResolvedValue({ latitude: 4.882, longitude: 7.009,
    accuracyMetres: 8, capturedAt: 1, source: 'browser' })
  vi.mocked(searchSharedDeliveryPlaces).mockResolvedValue([place, { ...place, address: 'Neighbouring entrance', longitude: 7.00901 }])
  const card = renderEditor()
  await userEvent.setup().type(within(card).getByLabelText('City'), 'Port Harcourt')
  await userEvent.setup().click(within(card).getByRole('button', { name: 'Get address' }))
  expect(await within(card).findByRole('button', { name: /Orji Woko Close/ })).toBeVisible()
  expect(within(card).getByRole('button', { name: /Neighbouring entrance/ })).toBeVisible()
  expect(within(card).queryByText(/Selected point:/)).not.toBeInTheDocument()
  expect(getAddressAtPosition).not.toHaveBeenCalled()
})
