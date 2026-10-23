import { render, screen, fireEvent, act, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import RiderAvailability from './RiderAvailability'
import { startRiderTracking } from './lib/rider-tracking'

vi.mock('./lib/rider-tracking', () => ({ startRiderTracking: vi.fn(() => () => {}) }))
afterEach(() => { delete window.KwikParselNative; vi.clearAllMocks() })

describe('RiderAvailability', () => {
  it('shows connecting until the server confirms a fresh rider location', async () => {
    const rpc = vi.fn(async (name: string) => ({ data: name === 'my_rider_online' ? true : 'available', error: null }))
    render(<RiderAvailability supabase={{ rpc } as never} />)
    fireEvent.click(screen.getByRole('button', { name: 'Go online' }))
    expect(screen.getByRole('heading', { name: 'Connecting' })).toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: 'On duty' })).not.toBeInTheDocument()
    const options = vi.mocked(startRiderTracking).mock.lastCall?.[0]
    act(() => options?.status('Online · GPS ±20 m'))
    expect(await screen.findByRole('heading', { name: 'On duty' })).toBeInTheDocument()
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

  it('starts phone tracking with a position-only grant and leaves browser polling off', async () => {
    const postMessage = vi.fn()
    window.KwikParselNative = { postMessage }
    const rpc = vi.fn(async (name: string) => ({ data: name === 'issue_rider_tracking_token' ? 'a'.repeat(64) : name === 'my_rider_online' ? true : 'available', error: null }))
    render(<RiderAvailability supabase={{ rpc, auth: { getSession: vi.fn(async () => ({ data: { session: { user: { id: 'rider' } } }, error: null })) } } as never} />)
    expect(screen.getByText(/Phone GPS stays on duty/)).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Go online' }))
    expect(screen.getByRole('button', { name: 'Go online' })).toBeDisabled()
    await waitFor(() => expect(postMessage).toHaveBeenCalledWith(JSON.stringify({ type: 'rider:start', trackingToken: 'a'.repeat(64) })))
    expect(startRiderTracking).not.toHaveBeenCalled()
    act(() => window.dispatchEvent(new CustomEvent('kwik-parsel:native', { detail: { type: 'rider:status', active: true, message: 'Online · phone GPS ±20 m' } })))
    expect(await screen.findByRole('heading', { name: 'On duty' })).toBeInTheDocument()
  })
  it('shows location paused when the server has no fresh rider fix', async () => {
    const rpc = vi.fn(async (name: string) => ({ data: name === 'my_rider_online' ? false : 'available', error: null }))
    render(<RiderAvailability supabase={{ rpc } as never} />)
    fireEvent.click(screen.getByRole('button', { name: 'Go online' }))
    const options = vi.mocked(startRiderTracking).mock.lastCall?.[0]
    act(() => options?.status('Online · GPS ±20 m'))
    expect(await screen.findByRole('heading', { name: 'Location paused' })).toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: 'On duty' })).not.toBeInTheDocument()
  })
})
