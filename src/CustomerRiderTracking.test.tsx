import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { SupabaseClient } from '@supabase/supabase-js'
import CustomerRiderTracking from './CustomerRiderTracking'

afterEach(() => { cleanup(); vi.restoreAllMocks() })

describe('customer rider tracking', () => {
  it('shows live position, approximate ETA and map only when requested', async () => {
    const rpc = vi.fn().mockResolvedValue({ data: {
      state: 'live', latitude: 6.45, longitude: 3.4, accuracy_metres: 20,
      captured_at: new Date().toISOString(), distance_metres: 1200, speed_kmh: 24, eta_minutes: 3,
    }, error: null })
    render(<CustomerRiderTracking supabase={{ rpc } as unknown as SupabaseClient} jobId="job-1" />)
    expect(await screen.findByText('~3 min')).toBeInTheDocument()
    expect(screen.getByText('24 km/h')).toBeInTheDocument()
    expect(screen.queryByTitle("Rider's latest location on OpenStreetMap")).not.toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Show rider on map' }))
    expect(screen.getByTitle("Rider's latest location on OpenStreetMap")).toBeInTheDocument()
    expect(rpc).toHaveBeenCalledWith('get_my_delivery_tracking', { p_job_id: 'job-1' })
  })

  it('does not show coordinates or map for an offline rider', async () => {
    const rpc = vi.fn().mockResolvedValue({ data: { state: 'offline' }, error: null })
    render(<CustomerRiderTracking supabase={{ rpc } as unknown as SupabaseClient} jobId="job-2" />)
    await waitFor(() => expect(screen.getByText(/location is unavailable/)).toBeInTheDocument())
    expect(screen.queryByRole('button', { name: 'Show rider on map' })).not.toBeInTheDocument()
  })
})
