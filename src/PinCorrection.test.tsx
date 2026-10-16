import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { SupabaseClient } from '@supabase/supabase-js'
import PinCorrection from './PinCorrection'
import { staticPinMap } from './lib/geoapify-geocoding'

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
})
