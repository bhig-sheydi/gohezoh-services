import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { SupabaseClient } from '@supabase/supabase-js'
import CustomerRiderTracking from './CustomerRiderTracking'

vi.mock('./lib/geoapify-geocoding', () => ({
  reverseAddress: vi.fn(async () => ({ community: 'Eliozu', street: 'Police Post Road', specificity: 'street', address: 'Police Post Road', distanceMetres: 16, confidence: 0.9 })),
  closestMappedLandmark: vi.fn(async () => ({ name: 'School Gate', distanceMetres: 48 })),
}))
afterEach(() => { cleanup(); vi.restoreAllMocks() })

describe('customer rider tracking', () => {
  it('shows progress without coordinates, then reveals a checked address and map', async () => {
    const rpc = vi.fn(async (name: string) => name === 'get_my_delivery_tracking' ? { data: {
      state: 'live', captured_at: new Date().toISOString(), distance_metres: 1200,
      speed_kmh: 24, eta_minutes: 3, checks_remaining: 2,
    }, error: null } : { data: { state: 'live', latitude: 6.45, longitude: 3.4,
      accuracy_metres: 20, captured_at: new Date().toISOString(), checks_remaining: 1 }, error: null })
    render(<CustomerRiderTracking supabase={{ rpc } as unknown as SupabaseClient} jobId="job-1" />)
    expect(await screen.findByText('~3 min')).toBeInTheDocument()
    expect(screen.getByText('24 km/h')).toBeInTheDocument()
    expect(screen.queryByText('Police Post Road')).not.toBeInTheDocument()
    expect(screen.queryByTitle("Rider's checked location on OpenStreetMap")).not.toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Check rider address' }))
    expect(await screen.findByText('Eliozu')).toBeInTheDocument()
    expect(screen.getByText('Police Post Road')).toBeInTheDocument()
    expect(screen.getByText(/School Gate/)).toBeInTheDocument()
    expect(screen.getByText('1 of 2 checks left this hour')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Show checked location on map' }))
    expect(screen.getByTitle("Rider's checked location on OpenStreetMap")).toBeInTheDocument()
    expect(rpc).toHaveBeenCalledWith('claim_my_rider_location_check', { p_job_id: 'job-1' })
  })

  it('does not offer an address or map when the rider is offline', async () => {
    const rpc = vi.fn().mockResolvedValue({ data: { state: 'offline' }, error: null })
    render(<CustomerRiderTracking supabase={{ rpc } as unknown as SupabaseClient} jobId="job-2" />)
    await waitFor(() => expect(screen.getByText(/location is unavailable/)).toBeInTheDocument())
    expect(screen.queryByRole('button', { name: 'Check rider address' })).not.toBeInTheDocument()
  })

  it('disables new checks after the server reports the hourly limit', async () => {
    const rpc = vi.fn().mockResolvedValue({ data: { state: 'live', captured_at: new Date().toISOString(), checks_remaining: 0 }, error: null })
    render(<CustomerRiderTracking supabase={{ rpc } as unknown as SupabaseClient} jobId="job-3" />)
    const button = await screen.findByRole('button', { name: 'Check rider address' })
    expect(button).toBeDisabled()
    expect(screen.queryByTitle("Rider's checked location on OpenStreetMap")).not.toBeInTheDocument()
  })
})
