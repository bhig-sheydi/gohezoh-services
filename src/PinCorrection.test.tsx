import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { SupabaseClient } from '@supabase/supabase-js'
import PinCorrection from './PinCorrection'
import { mapTile, suggestAddresses, suggestNearby, type AddressSuggestion } from './lib/geoapify-geocoding'

vi.mock('./lib/geoapify-geocoding', () => ({ mapTile: vi.fn(), reverseAddress: vi.fn(), suggestNearby: vi.fn(), suggestAddresses: vi.fn() }))
beforeEach(() => { vi.mocked(suggestAddresses).mockResolvedValue([]) })
afterEach(() => { vi.unstubAllGlobals(); vi.clearAllMocks() })

describe('mobile pin correction', () => {
  it('pans the map on a touch-style pointer drag and requires an exact point after a broad match', async () => {
    vi.mocked(mapTile).mockResolvedValue(new Blob(['png'], { type: 'image/png' }))
    vi.stubGlobal('URL', { ...URL, createObjectURL: vi.fn(() => 'blob:map'), revokeObjectURL: vi.fn() })
    render(<PinCorrection supabase={{} as SupabaseClient} initial={{ latitude: 5.5296, longitude: 7.4861 }} requireMove onChoose={vi.fn()} onClose={vi.fn()} />)
    const map = screen.getByRole('button', { name: 'Drag or tap map to choose a point' })
    Object.defineProperty(map, 'setPointerCapture', { value: vi.fn() })
    Object.defineProperty(map, 'getBoundingClientRect', { value: () => ({ left: 0, top: 0, width: 320, height: 220 }) })
    await waitFor(() => expect(document.querySelector('.pin-map-tile')).toBeTruthy())
    expect(screen.getByRole('button', { name: 'Use this pin' })).toBeDisabled()
    fireEvent.pointerDown(map, { pointerId: 1, clientX: 100, clientY: 100 })
    fireEvent.pointerMove(map, { pointerId: 1, clientX: 140, clientY: 100 })
    fireEvent.pointerUp(map, { pointerId: 1, clientX: 140, clientY: 100 })
    expect(mapTile).toHaveBeenCalled()
    await waitFor(() => expect(screen.getByRole('button', { name: 'Use this pin' })).toBeEnabled())
    const tileKeys = vi.mocked(mapTile).mock.calls.map((call) => `${call[1]}/${call[2]}/${call[3]}`)
    expect(new Set(tileKeys).size).toBe(tileKeys.length)
  })
  it('narrows a selected street to its mapped landmarks before house pin placement', async () => {
    const street: AddressSuggestion = { address: 'Market Road', city: 'Umuahia', state: 'Abia', latitude: 5.5296, longitude: 7.4861, specificity: 'street', resultType: 'street', confidence: null,
      distanceMetres: null, evidence: { latitude: 5.5296, longitude: 7.4861, accuracyMetres: null, capturedAt: Date.now(), source: 'search' }, qualityNote: '' }
    const landmark = { ...street, address: 'Main Market', latitude: 5.53, longitude: 7.49, resultType: 'amenity', specificity: 'area' as const, distanceMetres: 250 }
    vi.mocked(mapTile).mockResolvedValue(new Blob(['png'], { type: 'image/png' }))
    vi.mocked(suggestNearby).mockImplementation(async (_client, _text, kind) => kind === 'street' ? [street] : [landmark])
    vi.stubGlobal('URL', { ...URL, createObjectURL: vi.fn(() => 'blob:map'), revokeObjectURL: vi.fn() })
    render(<PinCorrection supabase={{} as SupabaseClient} initial={{ latitude: 5.52, longitude: 7.48 }} requireMove onChoose={vi.fn()} onClose={vi.fn()} />)
    await userEvent.setup().type(screen.getByRole('textbox', { name: 'Street name' }), 'Market')
    await userEvent.setup().click(await screen.findByRole('button', { name: 'Market Road, Umuahia' }))
    expect(screen.getByRole('textbox', { name: 'Street name' })).toHaveValue('Market Road')
    expect(screen.getByRole('textbox', { name: 'Search close, side street or landmark' })).toBeInTheDocument()
    await userEvent.setup().type(screen.getByRole('textbox', { name: 'Search close, side street or landmark' }), 'Main')
    await waitFor(() => expect(suggestNearby).toHaveBeenCalledWith(expect.anything(), 'Main', 'amenity', expect.anything(), expect.anything(), 'Market Road'), { timeout: 3000 })
    await userEvent.setup().click(await within(await screen.findByRole('group', { name: 'Landmarks on selected street' })).findByRole('button', { name: /Main Market/ }))
    expect(screen.getByText(/Selected Main Market/)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Use this pin' })).toBeDisabled()
  })
  it('explains when a landmark search has no mapped match on the selected street', async () => {
    const street: AddressSuggestion = { address: 'Market Road', city: 'Umuahia', state: 'Abia', latitude: 5.5296, longitude: 7.4861, specificity: 'street', resultType: 'street', confidence: null,
      distanceMetres: null, evidence: { latitude: 5.5296, longitude: 7.4861, accuracyMetres: null, capturedAt: Date.now(), source: 'search' }, qualityNote: '' }
    vi.mocked(mapTile).mockResolvedValue(new Blob(['png'], { type: 'image/png' }))
    vi.mocked(suggestNearby).mockImplementation(async (_client, _text, kind) => kind === 'street' ? [street] : [])
    vi.stubGlobal('URL', { ...URL, createObjectURL: vi.fn(() => 'blob:map'), revokeObjectURL: vi.fn() })
    render(<PinCorrection supabase={{} as SupabaseClient} initial={{ latitude: 5.52, longitude: 7.48 }} onChoose={vi.fn()} onClose={vi.fn()} />)
    await userEvent.setup().type(screen.getByRole('textbox', { name: 'Street name' }), 'Market')
    await userEvent.setup().click(await screen.findByRole('button', { name: 'Market Road, Umuahia' }))
    await userEvent.setup().type(screen.getByRole('textbox', { name: 'Search close, side street or landmark' }), 'Unknown')
    expect(await screen.findByText(/No mapped street, close or landmark with that name by Market Road/)).toBeInTheDocument()
  })
  it('shows a matching Nigerian street when the nearby pin is in the wrong area', async () => {
    const street: AddressSuggestion = { address: 'Ibeku Road', city: 'Umuahia', state: 'Abia', latitude: 5.5296, longitude: 7.4861, specificity: 'street', resultType: 'street', confidence: null,
      distanceMetres: null, evidence: { latitude: 5.5296, longitude: 7.4861, accuracyMetres: null, capturedAt: Date.now(), source: 'search' }, qualityNote: '' }
    vi.mocked(mapTile).mockResolvedValue(new Blob(['png'], { type: 'image/png' }))
    vi.mocked(suggestNearby).mockResolvedValue([])
    vi.mocked(suggestAddresses).mockResolvedValue([street])
    vi.stubGlobal('URL', { ...URL, createObjectURL: vi.fn(() => 'blob:map'), revokeObjectURL: vi.fn() })
    render(<PinCorrection supabase={{} as SupabaseClient} initial={{ latitude: 4.85, longitude: 7.01 }} onChoose={vi.fn()} onClose={vi.fn()} />)
    await userEvent.setup().type(screen.getByRole('textbox', { name: 'Street name' }), 'Ibeku')
    expect(await screen.findByRole('button', { name: 'Ibeku Road, Umuahia' })).toBeInTheDocument()
    expect(suggestAddresses).toHaveBeenCalledWith(expect.anything(), 'Ibeku', expect.anything())
  })
  it('explains when neither nearby nor wider street search finds a match', async () => {
    vi.mocked(mapTile).mockResolvedValue(new Blob(['png'], { type: 'image/png' }))
    vi.mocked(suggestNearby).mockResolvedValue([])
    vi.stubGlobal('URL', { ...URL, createObjectURL: vi.fn(() => 'blob:map'), revokeObjectURL: vi.fn() })
    render(<PinCorrection supabase={{} as SupabaseClient} initial={{ latitude: 4.85, longitude: 7.01 }} onChoose={vi.fn()} onClose={vi.fn()} />)
    await userEvent.setup().type(screen.getByRole('textbox', { name: 'Street name' }), 'Unmapped')
    expect(await screen.findByText(/This street is missing from the map/)).toBeInTheDocument()
  })
  it('keeps an unmapped street name and asks for a GPS or map point', async () => {
    vi.mocked(mapTile).mockResolvedValue(new Blob(['png'], { type: 'image/png' }))
    vi.mocked(suggestNearby).mockResolvedValue([])
    vi.mocked(suggestAddresses).mockResolvedValue([])
    vi.stubGlobal('URL', { ...URL, createObjectURL: vi.fn(() => 'blob:map'), revokeObjectURL: vi.fn() })
    const onChoose = vi.fn()
    render(<PinCorrection supabase={{} as SupabaseClient} initial={{ latitude: 4.87442, longitude: 6.988312 }}
      streetInputName="pickup_address" streetSearchRadiusMetres={3000} areaPlaceId="rumuaholu-place" compactMap onChoose={onChoose} />)
    await userEvent.setup().type(screen.getByRole('textbox', { name: 'Street name' }), 'Okemini')
    expect(await screen.findByText(/This street is missing from the map/)).toBeInTheDocument()
    expect(suggestAddresses).toHaveBeenCalledWith(expect.anything(), 'Okemini', expect.anything(), 'rumuaholu-place')
    await userEvent.setup().click(screen.getByRole('button', { name: 'Use typed street' }))
    expect(screen.getByRole('textbox', { name: 'Street name' })).toHaveValue('Okemini')
    expect(screen.getByRole('button', { name: 'Drag or tap map to choose a point' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Use this pin' })).toBeDisabled()
    expect(onChoose).not.toHaveBeenCalled()
  })
  it('lets customers choose a mapped close connected to the selected street', async () => {
    const street: AddressSuggestion = { address: 'Market Road', city: 'Umuahia', state: 'Abia', latitude: 5.5296, longitude: 7.4861, specificity: 'street', resultType: 'street', confidence: null,
      distanceMetres: null, evidence: { latitude: 5.5296, longitude: 7.4861, accuracyMetres: null, capturedAt: Date.now(), source: 'search' }, qualityNote: '' }
    const close = { ...street, address: 'School Close', latitude: 5.5301, longitude: 7.4864 }
    vi.mocked(mapTile).mockResolvedValue(new Blob(['png'], { type: 'image/png' }))
    vi.mocked(suggestNearby).mockImplementation(async (_client, text, kind) => kind === 'street' ? text === 'Market' ? [street] : [close] : [])
    vi.stubGlobal('URL', { ...URL, createObjectURL: vi.fn(() => 'blob:map'), revokeObjectURL: vi.fn() })
    render(<PinCorrection supabase={{} as SupabaseClient} initial={{ latitude: 5.52, longitude: 7.48 }} onChoose={vi.fn()} onClose={vi.fn()} />)
    await userEvent.setup().type(screen.getByRole('textbox', { name: 'Street name' }), 'Market')
    await userEvent.setup().click(await screen.findByRole('button', { name: 'Market Road, Umuahia' }))
    await userEvent.setup().type(screen.getByRole('textbox', { name: 'Search close, side street or landmark' }), 'School')
    await waitFor(() => expect(suggestNearby).toHaveBeenCalledWith(expect.anything(), 'School', 'street', expect.anything(), expect.anything(), 'Market Road'))
    await userEvent.setup().click(await within(await screen.findByRole('group', { name: 'Streets and closes by selected street' })).findByRole('button', { name: 'School Close, Umuahia' }))
    expect(screen.getByRole('textbox', { name: 'Street name' })).toHaveValue('School Close')
    expect(screen.getByText(/Search a close, side street or landmark off School Close/)).toBeInTheDocument()
  })
})
