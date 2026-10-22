import { render, screen, fireEvent, act, waitFor } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import RiderAvailability from './RiderAvailability'
import { startRiderTracking } from './lib/rider-tracking'

vi.mock('./lib/rider-tracking', () => ({ startRiderTracking: vi.fn(() => () => {}) }))

describe('RiderAvailability', () => {
  it('shows connecting until the server accepts a rider location', () => {
    render(<RiderAvailability supabase={{ rpc: vi.fn(async () => ({ data: 'available', error: null })) } as never} />)
    fireEvent.click(screen.getByRole('button', { name: 'Go online' }))
    expect(screen.getByRole('heading', { name: 'Connecting' })).toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: 'On duty' })).not.toBeInTheDocument()
    const options = vi.mocked(startRiderTracking).mock.lastCall?.[0]
    act(() => options?.status('Online · GPS ±20 m'))
    expect(screen.getByRole('heading', { name: 'On duty' })).toBeInTheDocument()
  })

  it('marks a rider full without stopping tracking', async () => {
    const rpc = vi.fn(async (name: string) => ({ data: name === 'my_rider_load_state' ? 'available' : 'full', error: null }))
    render(<RiderAvailability supabase={{ rpc } as never} />)
    const full = await screen.findByRole('button', { name: 'Full' })
    await waitFor(() => expect(full).toBeEnabled())
    fireEvent.click(full)
    expect(await screen.findByText('New orders are paused. Tracking and current deliveries continue.')).toBeInTheDocument()
    expect(rpc).toHaveBeenCalledWith('set_rider_load_state', { p_state: 'full' })
    expect(screen.getByRole('button', { name: 'Go online' })).toBeInTheDocument()
  })
})
