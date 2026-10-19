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
      if (name === 'list_my_selected_pickups') return { data: [{ request_id: 'request-1', request_number: 'REQ-001', pickup_city: 'Lagos', delivery_city: 'Ikeja', parcel_summary: 'Books', company_name: 'Quick Riders', selected_at: new Date().toISOString() }], error: null }
      if (name === 'my_rider_profile') return { data: [{ company_name: 'Quick Riders' }], error: null }
      return { data: [], error: null }
    })
    render(<RiderApp />)
    expect(await screen.findByText('Upcoming pickups')).toBeInTheDocument()
    expect(screen.getByText('Prepare for this pickup. Wait for the confirmed job here before contacting the customer or collecting the parcel.')).toBeInTheDocument()
    expect(screen.queryByText('Open pickup directions')).not.toBeInTheDocument()
    expect(screen.queryByText('Update delivery')).not.toBeInTheDocument()
  })
})
