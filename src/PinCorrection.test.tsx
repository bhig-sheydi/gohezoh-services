import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { SupabaseClient } from '@supabase/supabase-js'
import PinCorrection from './PinCorrection'
import { nearbyPlaces, staticPinMap, suggestNearby, type AddressSuggestion } from './lib/geoapify-geocoding'

vi.mock('./lib/geoapify-geocoding', () => ({ staticPinMap: vi.fn(), reverseAddress: vi.fn(), suggestNearby: vi.fn(), nearbyPlaces: vi.fn() }))
afterEach(() => { vi.unstubAllGlobals(); vi.clearAllMocks() })

describe('mobile pin correction', () => {
  it('pans the map on a touch-style pointer drag and requires an exact point after a broad match', async () => {
    vi.mocked(staticPinMap).mockResolvedValue(new Blob(['jpeg'], { type: 'image/jpeg' }))
    vi.stubGlobal('URL', { ...URL, createObjectURL: vi.fn(() => 'blob:map'), revokeObjectURL: vi.fn() })
    render(<PinCorrection supabase={{} as SupabaseClient} initial={{ latitude: 5.5296, longitude: 7.4861 }} requireMove onChoose={vi.fn()} onClose={vi.fn()} />)
    const map = screen.getByRole('button', { name: 'Drag or tap map to choose a point' })
    Object.defineProperty(map, 'setPointerCapture', { value: vi.fn() })
    Object.defineProperty(map, 'getBoundingClientRect', { value: () => ({ left: 0, top: 0, width: 320, height: 220 }) })
    await screen.findByRole('img', { name: 'Street map around the selected address' })
    expect(screen.getByRole('button', { name: 'Use this pin' })).toBeDisabled()
    fireEvent.pointerDown(map, { pointerId: 1, clientX: 100, clientY: 100 })
    fireEvent.pointerMove(map, { pointerId: 1, clientX: 140, clientY: 100 })
    fireEvent.pointerUp(map, { pointerId: 1, clientX: 140, clientY: 100 })
    await waitFor(() => expect(vi.mocked(staticPinMap).mock.calls.some((call) => call[2] !== 7.4861)).toBe(true))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Use this pin' })).toBeEnabled())
  })
  it('narrows a selected street to its mapped landmarks before house pin placement', async () => {
    const street: AddressSuggestion = { address: 'Market Road', city: 'Umuahia', state: 'Abia', latitude: 5.5296, longitude: 7.4861, specificity: 'street', resultType: 'street', confidence: null,
      distanceMetres: null, evidence: { latitude: 5.5296, longitude: 7.4861, accuracyMetres: null, capturedAt: Date.now(), source: 'search' }, qualityNote: '' }
    const landmark = { ...street, address: 'Main Market', latitude: 5.53, longitude: 7.49, resultType: 'amenity', specificity: 'area' as const, distanceMetres: 250 }
    vi.mocked(staticPinMap).mockResolvedValue(new Blob(['jpeg'], { type: 'image/jpeg' }))
    vi.mocked(suggestNearby).mockResolvedValue([street])
    vi.mocked(nearbyPlaces).mockResolvedValue([landmark])
    vi.stubGlobal('URL', { ...URL, createObjectURL: vi.fn(() => 'blob:map'), revokeObjectURL: vi.fn() })
    render(<PinCorrection supabase={{} as SupabaseClient} initial={{ latitude: 5.52, longitude: 7.48 }} requireMove onChoose={vi.fn()} onClose={vi.fn()} />)
    await userEvent.setup().type(screen.getByRole('textbox', { name: 'Street name' }), 'Market')
    await userEvent.setup().click(await screen.findByRole('button', { name: 'Market Road, Umuahia' }))
    expect(nearbyPlaces).toHaveBeenCalledWith(expect.anything(), { latitude: 5.5296, longitude: 7.4861 }, 'Market Road')
    await userEvent.setup().click(await screen.findByRole('button', { name: /Main Market/ }))
    await waitFor(() => expect(vi.mocked(staticPinMap).mock.calls.some((call) => call[1] === 5.53 && call[2] === 7.49)).toBe(true))
    expect(screen.getByRole('button', { name: 'Use this pin' })).toBeDisabled()
  })
})
