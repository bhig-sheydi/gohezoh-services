import { render, screen, fireEvent, act } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import RiderAvailability from './RiderAvailability'
import { startRiderTracking } from './lib/rider-tracking'

vi.mock('./lib/rider-tracking', () => ({ startRiderTracking: vi.fn(() => () => {}) }))

describe('RiderAvailability', () => {
  it('shows connecting until the server accepts a rider location', () => {
    render(<RiderAvailability supabase={{} as never} />)
    fireEvent.click(screen.getByRole('button', { name: 'Go online' }))
    expect(screen.getByRole('heading', { name: 'Connecting' })).toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: 'On duty' })).not.toBeInTheDocument()
    const options = vi.mocked(startRiderTracking).mock.lastCall?.[0]
    act(() => options?.status('Online · GPS ±20 m'))
    expect(screen.getByRole('heading', { name: 'On duty' })).toBeInTheDocument()
  })
})
