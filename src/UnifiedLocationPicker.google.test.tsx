import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, expect, it, vi } from 'vitest'
import type { SupabaseClient } from '@supabase/supabase-js'
import UnifiedLocationPicker from './UnifiedLocationPicker'
import { googleAutocomplete } from './lib/google-geocoding'
import { identifyCurrentLocation, suggestAddresses } from './lib/geoapify-geocoding'
import { LocationError, requestAddressPosition } from './lib/proximity'

vi.mock('./PinCorrection', () => ({ default: ({ initial, onChoose }: { initial: { latitude: number; longitude: number }; onChoose: (point: unknown, address: null, moved: boolean) => void }) =>
  <button type="button" aria-label="Move map pin" onClick={() => onChoose({ ...initial, accuracyMetres: null, capturedAt: Date.now(), source: 'map' }, null, true)}>Move map pin</button> }))
vi.mock('./lib/google-maps', () => ({ googleMapsDemoEnabled: true }))
vi.mock('./lib/google-geocoding', () => ({ googleAutocomplete: vi.fn(), newGoogleAutocompleteSession: () => ({}) }))
vi.mock('./lib/geoapify-geocoding', () => ({ suggestAddresses: vi.fn(), suggestNearby: vi.fn(), searchAddress: vi.fn(), identifyCurrentLocation: vi.fn() }))
vi.mock('./lib/proximity', () => ({ requestAddressPosition: vi.fn(), LocationError: class LocationError extends Error {
  code: string
  constructor(code: string, message: string) { super(message); this.code = code }
} }))

beforeEach(() => { vi.clearAllMocks() })

const sharedClient = (places: unknown[]) => ({ rpc: vi.fn(() => {
  const result = Promise.resolve({ data: places, error: null })
  return Object.assign(result, { abortSignal: () => result })
}) }) as unknown as SupabaseClient
const savedPlace = { id: 'local-one', label: 'Orji Woko Close', city: 'Port Harcourt', state: 'Rivers',
  latitude: 4.882269, longitude: 7.0096482, distance_metres: null }

it('shows saved delivery places before using Google and keeps the customer typed query separate', async () => {
  const client = sharedClient([savedPlace])
  render(<form><select name="pickup_city" defaultValue="Port Harcourt"><option>Port Harcourt</option></select>
    <UnifiedLocationPicker kind="pickup" supabase={client} /></form>)
  await userEvent.setup().type(screen.getByRole('searchbox', { name: 'Pickup place search' }), 'Orji Woko')
  await screen.findByRole('button', { name: /Orji Woko Close/ })
  expect(googleAutocomplete).not.toHaveBeenCalled()
  expect(screen.getByRole('button', { name: 'Search more places' })).toBeVisible()
  await userEvent.setup().click(screen.getByRole('button', { name: /Orji Woko Close/ }))
  expect(document.querySelector('[name=pickup_latitude]')).toHaveValue('4.882269')
  expect(document.querySelector('[name=pickup_customer_query]')).toHaveValue('Orji Woko')
  expect(document.querySelector('[name=pickup_user_moved_pin]')).toHaveValue('no')
})

it('uses Google automatically when no saved place matches', async () => {
  const client = sharedClient([])
  vi.mocked(googleAutocomplete).mockResolvedValue([])
  render(<form><select name="pickup_city" defaultValue="Port Harcourt"><option>Port Harcourt</option></select>
    <UnifiedLocationPicker kind="pickup" supabase={client} /></form>)
  await userEvent.setup().type(screen.getByRole('searchbox', { name: 'Pickup place search' }), 'Orji Woko')
  await vi.waitFor(() => expect(googleAutocomplete).toHaveBeenCalledOnce())
})

it('does not offer current-phone GPS for a drop-off destination', () => {
  render(<form><select name="delivery_city" defaultValue="Port Harcourt"><option>Port Harcourt</option></select>
    <UnifiedLocationPicker kind="delivery" supabase={sharedClient([])} /></form>)
  expect(screen.queryByRole('button', { name: /use GPS/ })).not.toBeInTheDocument()
  expect(screen.getByRole('searchbox', { name: 'Drop-off place search' })).toBeInTheDocument()
})

it('allows Google search when the saved places are not the intended place', async () => {
  const client = sharedClient([savedPlace])
  vi.mocked(googleAutocomplete).mockResolvedValue([])
  render(<form><select name="pickup_city" defaultValue="Port Harcourt"><option>Port Harcourt</option></select>
    <UnifiedLocationPicker kind="pickup" supabase={client} /></form>)
  await userEvent.setup().type(screen.getByRole('searchbox', { name: 'Pickup place search' }), 'Orji Woko')
  await userEvent.setup().click(await screen.findByRole('button', { name: 'Search more places' }))
  await vi.waitFor(() => expect(googleAutocomplete).toHaveBeenCalledOnce())
})

it('does not burst into Google requests when saved-place search fails', async () => {
  const client = { rpc: vi.fn(() => {
    const result = Promise.resolve({ data: null, error: { message: 'rate limited' } })
    return Object.assign(result, { abortSignal: () => result })
  }) } as unknown as SupabaseClient
  vi.mocked(googleAutocomplete).mockResolvedValue([])
  render(<form><select name="pickup_city" defaultValue="Port Harcourt"><option>Port Harcourt</option></select>
    <UnifiedLocationPicker kind="pickup" supabase={client} /></form>)
  await userEvent.setup().type(screen.getByRole('searchbox', { name: 'Pickup place search' }), 'Orji Woko')
  expect(await screen.findByRole('button', { name: 'Search more places' })).toBeVisible()
  expect(googleAutocomplete).not.toHaveBeenCalled()
  await userEvent.setup().click(screen.getByRole('button', { name: 'Search more places' }))
  await vi.waitFor(() => expect(googleAutocomplete).toHaveBeenCalledOnce())
})

it('shows multiple nearby saved places and uses only the one the customer selects', async () => {
  const second = { ...savedPlace, id: 'local-two', label: 'Neighbouring house', latitude: 4.882275, longitude: 7.009652, distance_metres: 11 }
  const client = sharedClient([{ ...savedPlace, distance_metres: 9 }, second])
  vi.mocked(requestAddressPosition).mockResolvedValue({ latitude: 4.88227, longitude: 7.00965,
    accuracyMetres: 8, capturedAt: Date.now(), source: 'browser' })
  render(<form><select name="pickup_city" defaultValue="Port Harcourt"><option>Port Harcourt</option></select>
    <UnifiedLocationPicker kind="pickup" supabase={client} /></form>)
  await userEvent.setup().click(screen.getByRole('button', { name: /use GPS/ }))
  expect(await screen.findByRole('button', { name: /Orji Woko Close.*9 m from your phone/ })).toBeVisible()
  expect(screen.getByRole('button', { name: /Neighbouring house.*11 m from your phone/ })).toBeVisible()
  expect(document.querySelector('[name=pickup_latitude]')).toBeNull()
  expect(document.querySelector('[name=pickup_address]')).toHaveValue('')
  expect(identifyCurrentLocation).not.toHaveBeenCalled()
  expect(googleAutocomplete).not.toHaveBeenCalled()
  await userEvent.setup().click(screen.getByRole('button', { name: /Neighbouring house/ }))
  expect(document.querySelector('[name=pickup_latitude]')).toHaveValue('4.882275')
  expect(document.querySelector('[name=pickup_longitude]')).toHaveValue('7.009652')
  await userEvent.setup().click(screen.getByRole('button', { name: 'Move map pin' }))
  expect(document.querySelector('[name=pickup_user_moved_pin]')).toHaveValue('yes')
})

it('keeps the phone point available when nearby saved places are not right', async () => {
  const client = sharedClient([{ ...savedPlace, distance_metres: 9 }])
  vi.mocked(requestAddressPosition).mockResolvedValue({ latitude: 4.88227, longitude: 7.00965,
    accuracyMetres: 8, capturedAt: Date.now(), source: 'browser' })
  vi.mocked(identifyCurrentLocation).mockResolvedValue({ label: 'My actual entrance', landmarkDistanceMetres: null, matchedAddress: null })
  render(<form><select name="pickup_city" defaultValue="Port Harcourt"><option>Port Harcourt</option></select>
    <UnifiedLocationPicker kind="pickup" supabase={client} /></form>)
  await userEvent.setup().click(screen.getByRole('button', { name: /use GPS/ }))
  await userEvent.setup().click(await screen.findByRole('button', { name: 'Use my phone point instead' }))
  await vi.waitFor(() => expect(document.querySelector('[name=pickup_latitude]')).toHaveValue('4.88227'))
  expect(identifyCurrentLocation).toHaveBeenCalledOnce()
})

it('opens phone location settings after a GPS timeout in the Android app', async () => {
  const postMessage = vi.fn()
  window.GohezohLocation = { postMessage }
  vi.mocked(requestAddressPosition).mockRejectedValue(new LocationError('timeout', 'Location request timed out.'))
  render(<form><select name="pickup_city" defaultValue="Port Harcourt"><option>Port Harcourt</option></select>
    <UnifiedLocationPicker kind="pickup" supabase={sharedClient([])} /></form>)
  await userEvent.setup().click(screen.getByRole('button', { name: /use GPS/ }))
  expect(await screen.findByRole('alert')).toHaveTextContent('Location request timed out.')
  await userEvent.setup().click(screen.getByRole('button', { name: 'Turn on phone location' }))
  expect(postMessage).toHaveBeenCalledWith('{"type":"position:settings"}')
  delete window.GohezohLocation
})

it('reverse geocodes a phone point when the nearest saved place is beyond 15 metres', async () => {
  const client = sharedClient([{ ...savedPlace, distance_metres: 16 }])
  vi.mocked(requestAddressPosition).mockResolvedValue({ latitude: 4.88227, longitude: 7.00965,
    accuracyMetres: 8, capturedAt: Date.now(), source: 'browser' })
  vi.mocked(identifyCurrentLocation).mockResolvedValue({ label: 'Nearby address', landmarkDistanceMetres: null, matchedAddress: null })
  render(<form><select name="pickup_city" defaultValue="Port Harcourt"><option>Port Harcourt</option></select>
    <UnifiedLocationPicker kind="pickup" supabase={client} /></form>)
  await userEvent.setup().click(screen.getByRole('button', { name: /use GPS/ }))
  await vi.waitFor(() => expect(identifyCurrentLocation).toHaveBeenCalledOnce())
  expect(document.querySelector('[name=pickup_latitude]')).toHaveValue('4.88227')
})

it.each(['pickup', 'delivery'] as const)('resolves a named Nigerian %s place only after selection', async (kind) => {
  const select = vi.fn(async () => ({ address: 'Divine Benevolent Care Organisation', city: 'Port Harcourt', state: 'Rivers',
    latitude: 4.8821755, longitude: 7.0098946, specificity: 'area', resultType: 'amenity', confidence: null, distanceMetres: null,
    evidence: { latitude: 4.8821755, longitude: 7.0098946, accuracyMetres: null, capturedAt: 1000, source: 'search' }, qualityNote: '' }))
  vi.mocked(googleAutocomplete).mockResolvedValue([{ address: 'Divine Benevolent Care Organisation', detail: 'Eliozu, Port Harcourt, Nigeria',
    placeId: 'divine-benevolent-care', select }] as never)
  render(<form><select name={`${kind}_city`} defaultValue="Port Harcourt"><option>Port Harcourt</option></select>
    <UnifiedLocationPicker kind={kind} supabase={{} as SupabaseClient} /></form>)
  await userEvent.setup().type(screen.getByRole('searchbox', { name: kind === 'pickup' ? 'Pickup place search' : 'Drop-off place search' }), 'Divine Benevolent')
  expect(document.querySelector(`[name=${kind}_latitude]`)).toBeNull()
  await userEvent.setup().click(await screen.findByRole('button', { name: 'Search more places' }))
  expect(await screen.findByText('Google Maps')).toBeVisible()
  await userEvent.setup().click(await screen.findByRole('button', { name: /Divine Benevolent Care Organisation/ }))
  expect(select).toHaveBeenCalledOnce()
  expect(document.querySelector(`[name=${kind}_latitude]`)).toHaveValue('4.8821755')
  expect(document.querySelector(`[name=${kind}_longitude]`)).toHaveValue('7.0098946')
  expect(suggestAddresses).not.toHaveBeenCalled()
})
