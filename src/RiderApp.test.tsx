import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import RiderApp from './RiderApp'

const mocks = vi.hoisted(() => ({
  getSession: vi.fn(async () => ({ data: { session: null } })),
  setSession: vi.fn(async () => ({ error: null })),
  proof: vi.fn(async () => ({ publicKey: { kty: 'EC', crv: 'P-256', x: 'x', y: 'y' } })),
  rpc: vi.fn(),
  from: vi.fn(),
}))
vi.mock('./lib/supabase', () => ({ getSupabaseClient: () => ({ auth: {
  getSession: mocks.getSession, setSession: mocks.setSession,
  onAuthStateChange: () => ({ data: { subscription: { unsubscribe: vi.fn() } } }),
}, rpc: mocks.rpc, from: mocks.from }) }))
vi.mock('./lib/rider-device', () => ({ riderDeviceProof: mocks.proof }))

describe('company rider sign-in', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mocks.getSession.mockResolvedValue({ data: { session: null } })
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

  it('shows a chosen company pickup as preparation only, before an awarded job exists', async () => {
    mocks.getSession.mockResolvedValue({ data: { session: { user: { id: 'rider-1', user_metadata: { full_name: 'Ada' } } } } } as never)
    mocks.from.mockReturnValue({ select: () => ({ eq: () => ({ eq: () => ({ maybeSingle: async () => ({ data: { role: 'rider' } }) }) }) }) })
    mocks.rpc.mockImplementation(async (name: string) => {
      if (name === 'list_my_selected_pickups') return { data: [{ request_id: 'request-1', request_number: 'REQ-001', pickup_city: 'Port Harcourt', delivery_city: 'Port Harcourt', pickup_address: 'Police Post, Eliozu', delivery_address: 'Farm Road 2, Eliozu', parcel_summary: 'Books', company_name: 'Quick Riders', selected_at: new Date().toISOString() }], error: null }
      if (name === 'my_rider_profile') return { data: [{ company_name: 'Quick Riders' }], error: null }
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
    mocks.from.mockReturnValue({ select: () => ({ eq: () => ({ eq: () => ({ maybeSingle: async () => ({ data: { role: 'rider' } }) }) }) }) })
    mocks.rpc.mockImplementation(async (name: string) => {
      if (name === 'list_my_rider_jobs') return { data: [{ job_id: 'job-1', job_number: 'JOB-1', status: 'pickup_scheduled', pickup_address: '1 Market Road', pickup_city: 'Lagos', delivery_address: '2 Market Road', delivery_city: 'Lagos', recipient_name: 'Receiver', recipient_phone: '08000000000', parcel_summary: 'Books', company_name: 'Quick Riders' }], error: null }
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

  it('shows delivery success without sending a second status update after code verification', async () => {
    mocks.getSession.mockResolvedValue({ data: { session: { user: { id: 'rider-1', user_metadata: { full_name: 'Ada' } } } } } as never)
    mocks.from.mockReturnValue({ select: () => ({ eq: () => ({ eq: () => ({ maybeSingle: async () => ({ data: { role: 'rider' } }) }) }) }) })
    mocks.rpc.mockImplementation(async (name: string) => {
      if (name === 'list_my_rider_jobs') return { data: [{ job_id: 'job-1', job_number: 'JOB-1', status: 'in_transit', pickup_address: '1 Market Road', pickup_city: 'Lagos', delivery_address: '2 Market Road', delivery_city: 'Lagos', recipient_name: 'Receiver', recipient_phone: '08000000000', parcel_summary: 'Books', company_name: 'Quick Riders' }], error: null }
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
    mocks.from.mockReturnValue({ select: () => ({ eq: () => ({ eq: () => ({ maybeSingle: async () => ({ data: { role: 'rider' } }) }) }) }) })
    mocks.rpc.mockImplementation(async (name: string) => {
      if (name === 'list_my_rider_jobs') return { data: [{ job_id: 'job-1', job_number: 'JOB-1', status: 'in_transit', pickup_address: '1 Market Road', pickup_city: 'Lagos', delivery_address: '2 Market Road', delivery_city: 'Lagos', recipient_name: 'Receiver', recipient_phone: '08000000000', sender_name: 'Sender', sender_phone: '08012345678', parcel_summary: 'Books', company_name: 'Quick Riders' }], error: null }
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
