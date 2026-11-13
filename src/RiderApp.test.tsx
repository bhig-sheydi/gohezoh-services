import { act, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import RiderApp from './RiderApp'

const mocks = vi.hoisted(() => ({
  getSession: vi.fn(async () => ({ data: { session: null } })),
  setSession: vi.fn(async () => ({ error: null })),
  signOut: vi.fn(async () => ({ error: null })),
  proof: vi.fn(async () => ({ publicKey: { kty: 'EC', crv: 'P-256', x: 'x', y: 'y' } })),
  rpc: vi.fn(),
  from: vi.fn(),
}))
vi.mock('./lib/supabase', () => {
  const client = { auth: {
    getSession: mocks.getSession, setSession: mocks.setSession, signOut: mocks.signOut,
    onAuthStateChange: () => ({ data: { subscription: { unsubscribe: vi.fn() } } }),
  }, rpc: mocks.rpc, from: mocks.from }
  return { getSupabaseClient: () => client }
})
vi.mock('./lib/rider-device', () => ({ riderDeviceProof: mocks.proof }))

const dashboard = (overrides: Record<string, unknown> = {}) => ({
  has_role: true, session_active: true, jobs: [], profile: [], pickup_locations: [],
  delivery_locations: [], selected_pickups: [], next_stop: [], ...overrides,
})

describe('company rider sign-in', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mocks.getSession.mockResolvedValue({ data: { session: null } })
    mocks.rpc.mockResolvedValue({ data: dashboard(), error: null })
    window.history.replaceState({}, '', `/rider#rider=${'a'.repeat(64)}`)
  })

  it('asks only for the rider password and registers the first phone key', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce({ ok: true, json: async () => ({ firstDevice: true }) })
      .mockResolvedValueOnce({ ok: true, json: async () => ({ session: { access_token: 'access', refresh_token: 'refresh' } }) })
    vi.stubGlobal('fetch', fetchMock)
    render(<RiderApp />)
    expect(await screen.findByLabelText('Your password')).toBeInTheDocument()
    expect(screen.queryByLabelText(/email/i)).not.toBeInTheDocument()
    fireEvent.change(screen.getByLabelText('Your password'), { target: { value: 'unique-password' } })
    fireEvent.submit(screen.getByRole('button', { name: 'Sign in' }).closest('form')!)
    await waitFor(() => expect(mocks.setSession).toHaveBeenCalledWith({ access_token: 'access', refresh_token: 'refresh' }))
    expect(JSON.parse(fetchMock.mock.calls[1][1].body)).toMatchObject({ action: 'login', password: 'unique-password', publicKey: expect.any(Object) })
  })

  it('shows the management reset instruction on a different phone', async () => {
    vi.stubGlobal('fetch', vi.fn()
      .mockResolvedValueOnce({ ok: true, json: async () => ({ challenge: 'challenge' }) })
      .mockResolvedValueOnce({ ok: false, json: async () => ({ error: 'It seems you changed your phone. Contact your management to set a new password.' }) }))
    render(<RiderApp />)
    fireEvent.change(await screen.findByLabelText('Your password'), { target: { value: 'unique-password' } })
    fireEvent.submit(screen.getByRole('button', { name: 'Sign in' }).closest('form')!)
    expect(await screen.findByRole('alert')).toHaveTextContent('It seems you changed your phone')
    expect(mocks.setSession).not.toHaveBeenCalled()
  })

  it('uses a shared company link and a unique rider password to find the first phone', async () => {
    const companyId = '11111111-1111-4111-8111-111111111111'
    window.history.replaceState({}, '', `/rider#company=${companyId}`)
    const fetchMock = vi.fn()
      .mockResolvedValueOnce({ ok: true, json: async () => ({ firstDevice: true, riderId: 'rider-identity' }) })
      .mockResolvedValueOnce({ ok: true, json: async () => ({ session: { access_token: 'access', refresh_token: 'refresh' } }) })
    vi.stubGlobal('fetch', fetchMock)
    render(<RiderApp />)
    fireEvent.change(await screen.findByLabelText('Your password'), { target: { value: 'Market-River-Mango-1234' } })
    fireEvent.submit(screen.getByRole('button', { name: 'Sign in' }).closest('form')!)
    await waitFor(() => expect(mocks.setSession).toHaveBeenCalled())
    expect(JSON.parse(fetchMock.mock.calls[0][1].body)).toMatchObject({ action: 'challenge', companyId, password: 'Market-River-Mango-1234' })
    expect(mocks.proof).toHaveBeenCalledWith('rider-identity', undefined)
  })

  it('loads rider jobs and coordinates through one snapshot request', async () => {
    mocks.getSession.mockResolvedValue({ data: { session: { user: { id: 'rider-1', user_metadata: { full_name: 'Ada' } } } } } as never)
    mocks.rpc.mockImplementation(async (name: string) => name === 'my_rider_dashboard_snapshot'
      ? { data: dashboard({
        jobs: [{ job_id: 'job-1', job_number: 'JOB-1', status: 'pickup_scheduled', pickup_address: '1 Market Road', pickup_city: 'Lagos', delivery_address: '2 Market Road', delivery_city: 'Lagos', recipient_name: 'Receiver', recipient_phone: '08000000000', parcel_summary: 'Books', company_name: 'Quick Riders' }],
        profile: [{ company_name: 'Quick Riders' }],
        pickup_locations: [{ job_id: 'job-1', latitude: 6.5, longitude: 3.4 }],
        delivery_locations: [{ job_id: 'job-1', latitude: 6.6, longitude: 3.5 }],
      }), error: null }
      : { data: [], error: null })
    render(<RiderApp />)
    expect(await screen.findByText('JOB-1')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Open pickup directions' })).toHaveAttribute('href', 'https://www.google.com/maps/search/?api=1&query=6.5,3.4')
    expect(screen.getByRole('link', { name: 'Open delivery pin' })).toHaveAttribute('href', 'https://www.google.com/maps/search/?api=1&query=6.6,3.5')
    expect(mocks.rpc).toHaveBeenCalledWith('my_rider_dashboard_snapshot')
    for (const oldRpc of ['list_my_rider_jobs', 'my_rider_profile', 'list_my_rider_pickup_locations', 'list_my_rider_delivery_locations', 'list_my_selected_pickups', 'my_rider_next_stop'])
      expect(mocks.rpc).not.toHaveBeenCalledWith(oldRpc)
    expect(mocks.from).not.toHaveBeenCalledWith('user_roles')
  })

  it('signs out promptly when the snapshot says rider access was revoked', async () => {
    mocks.getSession.mockResolvedValue({ data: { session: { user: { id: 'rider-1', user_metadata: {} } } } } as never)
    let revoked = false
    mocks.rpc.mockImplementation(async (name: string) => name === 'my_rider_dashboard_snapshot'
      ? { data: revoked ? dashboard({ session_active: false }) : dashboard({ jobs: [{ job_id: 'job-1', job_number: 'JOB-1', status: 'pickup_scheduled', pickup_address: 'Pickup', pickup_city: 'Lagos', delivery_address: 'Dropoff', delivery_city: 'Lagos', recipient_name: 'Receiver', recipient_phone: '08000000000', parcel_summary: 'Books', company_name: 'Quick Riders' }] }), error: null }
      : { data: [], error: null })
    render(<RiderApp />)
    expect(await screen.findByText('JOB-1')).toBeInTheDocument()
    revoked = true
    fireEvent.click(screen.getByRole('button', { name: 'Refresh jobs' }))
    await waitFor(() => expect(mocks.signOut).toHaveBeenCalled())
    expect(screen.queryByText('JOB-1')).not.toBeInTheDocument()
    expect(screen.getByRole('alert')).toHaveTextContent('Your rider access has ended')
  })

  it('hides previously loaded jobs if the next access snapshot fails', async () => {
    mocks.getSession.mockResolvedValue({ data: { session: { user: { id: 'rider-1', user_metadata: {} } } } } as never)
    let fail = false
    mocks.rpc.mockImplementation(async (name: string) => name === 'my_rider_dashboard_snapshot'
      ? fail ? { data: null, error: { message: 'Access check unavailable' } }
        : { data: dashboard({ jobs: [{ job_id: 'job-1', job_number: 'JOB-1', status: 'pickup_scheduled', pickup_address: 'Pickup', pickup_city: 'Lagos', delivery_address: 'Dropoff', delivery_city: 'Lagos', recipient_name: 'Receiver', recipient_phone: '08000000000', parcel_summary: 'Books', company_name: 'Quick Riders' }] }), error: null }
      : { data: [], error: null })
    render(<RiderApp />)
    expect(await screen.findByText('JOB-1')).toBeInTheDocument()
    fail = true
    fireEvent.click(screen.getByRole('button', { name: 'Refresh jobs' }))
    await waitFor(() => expect(screen.queryByText('JOB-1')).not.toBeInTheDocument())
    expect(screen.getByRole('alert')).toHaveTextContent('Access check unavailable')
  })

  it('signs out if the rider role is removed', async () => {
    mocks.getSession.mockResolvedValue({ data: { session: { user: { id: 'rider-1', user_metadata: {} } } } } as never)
    let roleRemoved = false
    mocks.rpc.mockImplementation(async (name: string) => name === 'my_rider_dashboard_snapshot'
      ? { data: dashboard(roleRemoved ? { has_role: false, session_active: false } : {}), error: null }
      : { data: [], error: null })
    render(<RiderApp />)
    expect(await screen.findByRole('button', { name: 'Refresh jobs' })).toBeInTheDocument()
    roleRemoved = true
    fireEvent.click(screen.getByRole('button', { name: 'Refresh jobs' }))
    await waitFor(() => expect(mocks.signOut).toHaveBeenCalled())
  })

  it('ignores an older dashboard response after a newer access revocation', async () => {
    mocks.getSession.mockResolvedValue({ data: { session: { user: { id: 'rider-1', user_metadata: {} } } } } as never)
    const pending: Array<(value: { data: unknown; error: null }) => void> = []
    let snapshotCount = 0
    mocks.rpc.mockImplementation((name: string) => {
      if (name !== 'my_rider_dashboard_snapshot') return Promise.resolve({ data: [], error: null })
      snapshotCount++
      if (snapshotCount === 1) return Promise.resolve({ data: dashboard(), error: null })
      return new Promise((resolve) => { pending.push(resolve) })
    })
    render(<RiderApp />)
    const refresh = await screen.findByRole('button', { name: 'Refresh jobs' })
    fireEvent.click(refresh)
    fireEvent.click(refresh)
    await waitFor(() => expect(pending).toHaveLength(2))
    await act(async () => { pending[1]({ data: dashboard({ session_active: false }), error: null }) })
    expect(mocks.signOut).toHaveBeenCalled()
    await act(async () => { pending[0]({ data: dashboard({ jobs: [{ job_id: 'old-job', job_number: 'STALE-JOB', status: 'pickup_scheduled', pickup_address: 'Pickup', pickup_city: 'Lagos', delivery_address: 'Dropoff', delivery_city: 'Lagos', recipient_name: 'Receiver', recipient_phone: '08000000000', parcel_summary: 'Books', company_name: 'Quick Riders' }] }), error: null }) })
    expect(screen.queryByText('STALE-JOB')).not.toBeInTheDocument()
  })

  it('uses recent snapshots for visible access checks but still checks on focus', async () => {
    vi.useFakeTimers()
    try {
      mocks.getSession.mockResolvedValue({ data: { session: { user: { id: 'rider-1', user_metadata: {} } } } } as never)
      mocks.rpc.mockImplementation(async (name: string) => name === 'my_rider_dashboard_snapshot'
        ? { data: dashboard(), error: null } : { data: true, error: null })
      render(<RiderApp />)
      await act(async () => { await Promise.resolve() })
      await act(async () => { await vi.advanceTimersByTimeAsync(1) })
      await act(async () => { await vi.advanceTimersByTimeAsync(30_000) })
      expect(mocks.rpc.mock.calls.some(([name]) => name === 'my_rider_dashboard_snapshot')).toBe(true)
      expect(mocks.rpc.mock.calls.some(([name]) => name === 'rider_session_active')).toBe(false)
      await act(async () => { window.dispatchEvent(new Event('focus')); await Promise.resolve() })
      expect(mocks.rpc.mock.calls.filter(([name]) => name === 'rider_session_active')).toHaveLength(1)
      const hidden = vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('hidden')
      try {
        await act(async () => { await vi.advanceTimersByTimeAsync(15_000) })
        expect(mocks.rpc.mock.calls.filter(([name]) => name === 'rider_session_active')).toHaveLength(2)
      } finally { hidden.mockRestore() }
    } finally { vi.useRealTimers() }
  })

  it('shows a chosen company pickup as preparation only, before an awarded job exists', async () => {
    mocks.getSession.mockResolvedValue({ data: { session: { user: { id: 'rider-1', user_metadata: { full_name: 'Ada' } } } } } as never)
    mocks.rpc.mockImplementation(async (name: string) => {
      if (name === 'my_rider_dashboard_snapshot') return { data: dashboard({ selected_pickups: [{ request_id: 'request-1', request_number: 'REQ-001', pickup_city: 'Port Harcourt', delivery_city: 'Port Harcourt', pickup_address: 'Police Post, Eliozu', delivery_address: 'Farm Road 2, Eliozu', parcel_summary: 'Books', company_name: 'Quick Riders', selected_at: new Date().toISOString() }], profile: [{ company_name: 'Quick Riders' }] }), error: null }
      return { data: [], error: null }
    })
    render(<RiderApp />)
    expect(await screen.findByText('Upcoming pickups')).toBeInTheDocument()
    expect(screen.getByText('Police Post, Eliozu → Farm Road 2, Eliozu')).toBeInTheDocument()
    expect(screen.getByText('Waiting for customer payment. Do not travel, contact the customer, or collect the parcel. This task becomes actionable only when a confirmed job appears here.')).toBeInTheDocument()
    expect(screen.queryByText('Open pickup directions')).not.toBeInTheDocument()
    expect(screen.queryByText('Update delivery')).not.toBeInTheDocument()
  })

  it('requires the sender pickup code before marking an assigned parcel collected', async () => {
    mocks.getSession.mockResolvedValue({ data: { session: { user: { id: 'rider-1', user_metadata: { full_name: 'Ada' } } } } } as never)
    mocks.rpc.mockImplementation(async (name: string) => {
      if (name === 'my_rider_dashboard_snapshot') return { data: dashboard({ jobs: [{ job_id: 'job-1', job_number: 'JOB-1', status: 'pickup_scheduled', pickup_address: '1 Market Road', pickup_city: 'Lagos', delivery_address: '2 Market Road', delivery_city: 'Lagos', recipient_name: 'Receiver', recipient_phone: '08000000000', parcel_summary: 'Books', company_name: 'Quick Riders' }] }), error: null }
      if (name === 'verify_pickup_handoff_code') return { data: { verified: true }, error: null }
      return { data: [], error: null }
    })
    render(<RiderApp />)
    const field = await screen.findByLabelText('Sender pickup code')
    expect(screen.queryByRole('option', { name: 'Picked up' })).not.toBeInTheDocument()
    const button = screen.getByRole('button', { name: 'Confirm parcel collected' })
    expect(button).toBeDisabled()
    fireEvent.change(field, { target: { value: '12345678' } })
    fireEvent.click(button)
    await waitFor(() => expect(mocks.rpc).toHaveBeenCalledWith('verify_pickup_handoff_code', { p_job_id: 'job-1', p_code: '12345678' }))
    expect(mocks.rpc).not.toHaveBeenCalledWith('rider_update_job_status', { p_job_id: 'job-1', p_new_status: 'picked_up' })
  })

  it('lets an assigned rider accept the one-minute request and stop the phone alarm', async () => {
    mocks.getSession.mockResolvedValue({ data: { session: { user: { id: 'rider-1', user_metadata: { full_name: 'Ada' } } } } } as never)
    const postMessage = vi.fn()
    window.KwikParselNative = { postMessage } as typeof window.KwikParselNative
    let accepted = false
    mocks.rpc.mockImplementation(async (name: string) => {
      if (name === 'my_rider_dashboard_snapshot') return { data: dashboard({
        jobs: [{ job_id: 'job-1', job_number: 'JOB-1', status: 'partner_assigned', pickup_address: '1 Market Road', pickup_city: 'Lagos', delivery_address: '2 Market Road', delivery_city: 'Lagos', recipient_name: 'Receiver', recipient_phone: '08000000000', parcel_summary: 'Books', company_name: 'Quick Riders' }],
        assignment_responses: [{ job_id: 'job-1', deadline_at: new Date(Date.now() + 60000).toISOString(), accepted_at: accepted ? new Date().toISOString() : null }],
      }), error: null }
      if (name === 'accept_rider_assignment') { accepted = true; return { data: true, error: null } }
      return { data: [], error: null }
    })
    render(<RiderApp />)
    fireEvent.click(await screen.findByRole('button', { name: 'Accept ride' }))
    await waitFor(() => expect(mocks.rpc).toHaveBeenCalledWith('accept_rider_assignment', { p_job_id: 'job-1' }))
    expect(postMessage).toHaveBeenCalledWith(JSON.stringify({ type: 'ride:stop-alarm', jobId: 'job-1' }))
    delete window.KwikParselNative
  })

  it('shows delivery success without sending a second status update after code verification', async () => {
    mocks.getSession.mockResolvedValue({ data: { session: { user: { id: 'rider-1', user_metadata: { full_name: 'Ada' } } } } } as never)
    mocks.rpc.mockImplementation(async (name: string) => {
      if (name === 'my_rider_dashboard_snapshot') return { data: dashboard({ jobs: [{ job_id: 'job-1', job_number: 'JOB-1', status: 'in_transit', pickup_address: '1 Market Road', pickup_city: 'Lagos', delivery_address: '2 Market Road', delivery_city: 'Lagos', recipient_name: 'Receiver', recipient_phone: '08000000000', parcel_summary: 'Books', company_name: 'Quick Riders' }] }), error: null }
      if (name === 'verify_delivery_otp') return { data: { verified: true, status: 'delivered' }, error: null }
      return { data: [], error: null }
    })
    render(<RiderApp />)
    fireEvent.change(await screen.findByLabelText('Recipient code'), { target: { value: '123456' } })
    expect(screen.queryByRole('option', { name: 'Out for delivery' })).not.toBeInTheDocument()
    expect(screen.queryByLabelText('Update delivery')).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Report a problem' })).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Confirm delivery' }))
    await waitFor(() => expect(screen.getByText('JOB-1 delivered.')).toBeInTheDocument())
    expect(mocks.rpc).toHaveBeenCalledWith('verify_delivery_otp', { p_job_id: 'job-1', p_code: '123456' })
    expect(mocks.rpc).not.toHaveBeenCalledWith('rider_update_job_status', { p_job_id: 'job-1', p_new_status: 'delivered' })
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })

  it('shows the sender phone without a pickup pin and asks the customer to verify arrival', async () => {
    mocks.getSession.mockResolvedValue({ data: { session: { user: { id: 'rider-1', user_metadata: { full_name: 'Ada' } } } } } as never)
    mocks.rpc.mockImplementation(async (name: string) => {
      if (name === 'my_rider_dashboard_snapshot') return { data: dashboard({ jobs: [{ job_id: 'job-1', job_number: 'JOB-1', status: 'in_transit', pickup_address: '1 Market Road', pickup_city: 'Lagos', delivery_address: '2 Market Road', delivery_city: 'Lagos', recipient_name: 'Receiver', recipient_phone: '08000000000', sender_name: 'Sender', sender_phone: '08012345678', parcel_summary: 'Books', company_name: 'Quick Riders' }] }), error: null }
      if (name === 'request_sender_delivery_confirmation') return { data: { status: 'pending' }, error: null }
      return { data: [], error: null }
    })
    render(<RiderApp />)
    expect(await screen.findByText(/Sender: Sender.*08012345678/)).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Ask sender to confirm delivery' }))
    await waitFor(() => expect(mocks.rpc).toHaveBeenCalledWith('request_sender_delivery_confirmation', { p_job_id: 'job-1' }))
    expect(screen.getByRole('button', { name: 'Waiting for sender confirmation' })).toBeDisabled()
    expect(mocks.rpc).not.toHaveBeenCalledWith('rider_update_job_status', { p_job_id: 'job-1', p_new_status: 'delivered' })
  })
})

describe('independent rider access', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    window.history.replaceState({}, '', '/rider')
    mocks.getSession.mockResolvedValue({ data: { session: { user: {
      id: 'independent-1', user_metadata: { account_kind: 'independent_rider', phone: '08012345678' },
    } } } } as never)
  })

  it('lets a confirmed rider choose an active company without KYC fields', async () => {
    mocks.rpc.mockImplementation(async (name: string) => {
      if (name === 'my_rider_dashboard_snapshot') return { data: dashboard({ has_role: false, session_active: false }), error: null }
      if (name === 'list_independent_rider_companies') return { data: [{ id: 'company-1', name: 'Test Logistics' }], error: null }
      return { data: null, error: null }
    })
    render(<RiderApp />)
    expect(await screen.findByRole('heading', { name: 'Choose your logistics company' })).toBeInTheDocument()
    expect(screen.getByRole('option', { name: 'Test Logistics' })).toBeInTheDocument()
    expect(screen.queryByText(/NIN|licence/i)).not.toBeInTheDocument()
    fireEvent.change(screen.getByRole('combobox', { name: 'Company' }), { target: { value: 'company-1' } })
    fireEvent.submit(screen.getByRole('button', { name: 'Join company' }).closest('form')!)
    await waitFor(() => expect(mocks.rpc).toHaveBeenCalledWith('register_independent_rider', {
      p_partner_id: 'company-1', p_phone: '08012345678',
    }))
    expect(mocks.signOut).not.toHaveBeenCalled()
  })

  it('shows only its matched direct offer and accepts it at the fixed price', async () => {
    mocks.rpc.mockImplementation(async (name: string) => {
      if (name === 'my_rider_dashboard_snapshot') return { data: dashboard(), error: null }
      if (name === 'my_independent_rider_offers') return { data: [{
        request_id: 'request-1', request_number: 'REQ-1', pickup_address: 'Eliozu',
        delivery_address: 'Trans Amadi', parcel_summary: 'Books', customer_price_ngn: 2100,
        company_share_ngn: 1575, deadline_at: new Date(Date.now() + 60_000).toISOString(),
      }], error: null }
      return { data: true, error: null }
    })
    render(<RiderApp />)
    expect(await screen.findByText('REQ-1')).toBeInTheDocument()
    expect(screen.getByText(/Price: ₦2,100/)).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Accept delivery' }))
    await waitFor(() => expect(mocks.rpc).toHaveBeenCalledWith('respond_independent_rider_offer', {
      p_request_id: 'request-1', p_accept: true,
    }))
  })
})
