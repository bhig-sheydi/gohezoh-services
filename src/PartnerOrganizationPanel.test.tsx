import { afterEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { PartnerInvitationClaim, PartnerRidersPanel } from './PartnerOrganizationPanel'

describe('partner organization invitations', () => {
  afterEach(() => vi.unstubAllGlobals())
  it('shows only rider management, without obsolete company-team controls', async () => {
    const rpc = vi.fn(async (name: string) => name === 'list_my_partner_team'
      ? { data: [{ partner_id: 'partner-1', partner_name: 'North Star Logistics', user_id: 'manager-1', is_manager: true }], error: null }
      : { data: [], error: null })
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: true, json: async () => ({ riders: [] }) })))
    const supabase = { rpc, auth: { getSession: vi.fn(async () => ({ data: { session: { access_token: 'manager-token' } } })) } } as unknown as Parameters<typeof PartnerRidersPanel>[0]['supabase']
    render(<PartnerRidersPanel supabase={supabase} userId="manager-1" onError={vi.fn()} onNotice={vi.fn()} />)

    expect(await screen.findByRole('heading', { name: 'Company riders' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Copy rider link' })).toBeInTheDocument()
    expect(screen.queryByText('Company team')).not.toBeInTheDocument()
    expect(screen.queryByText('Invite a team member')).not.toBeInTheDocument()
    expect(screen.queryByText('Company invitations')).not.toBeInTheDocument()
    expect(rpc).not.toHaveBeenCalledWith('list_partner_staff_invitations')
  })

  it('does not show manual rider assignment controls on the company dashboard', async () => {
    const rpc = vi.fn(async (name: string) => name === 'list_my_partner_team'
      ? { data: [{ partner_id: 'partner-1', partner_name: 'North Star Logistics', user_id: 'manager-1', email: 'manager@example.test', full_name: 'Manager', membership_role: 'manager', is_manager: true }], error: null }
      : { data: [], error: null })
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: true, json: async () => ({ riders: [] }) })))
    const supabase = { rpc, auth: { getSession: vi.fn(async () => ({ data: { session: { access_token: 'manager-token' } } })) } } as unknown as Parameters<typeof PartnerRidersPanel>[0]['supabase']
    render(<PartnerRidersPanel supabase={supabase} userId="manager-1" onError={vi.fn()} onNotice={vi.fn()} />)

    await screen.findByText('Company riders')
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('list_my_partner_team'))
    expect(screen.queryByRole('button', { name: 'Assign rider' })).not.toBeInTheDocument()
    expect(screen.queryByLabelText('Rider pickup assignments')).not.toBeInTheDocument()
    expect(rpc).not.toHaveBeenCalledWith('list_partner_rider_jobs')
  })

  it('shows compact rider cards and loads assigned deliveries only for the opened rider', async () => {
    const riders = ['Amina Yusuf', 'Tunde Okoro'].map((full_name, index) => ({
      id: `roster-${index + 1}`, full_name, status: 'approved', phone: null, photo_path: null,
      rider_credentials: { user_id: `rider-${index + 1}`, device_bound_at: null, device_label: null, password_revoked_at: null, revoked_at: null },
    }))
    const rpc = vi.fn(async (name: string) => name === 'list_my_partner_team'
      ? { data: [{ partner_id: 'partner-1', partner_name: 'North Star Logistics', user_id: 'manager-1', email: 'manager@example.test', full_name: 'Manager', membership_role: 'manager', is_manager: true }], error: null }
      : { data: [], error: null })
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: true, json: async () => ({ riders }) })))
    const limit = vi.fn(async () => ({ data: [{ id: 'job-1', job_number: 'JOB-12345', status: 'delivered', pickup_address: 'Eliozu', delivery_address: 'Rumuokoro', updated_at: '2026-10-22T00:00:00Z' }], error: null }))
    const eq = vi.fn(() => ({ eq, order: () => ({ limit }) }))
    const from = vi.fn(() => ({ select: () => ({ eq }) }))
    const supabase = { rpc, from, auth: { getSession: vi.fn(async () => ({ data: { session: { access_token: 'manager-token' } } })) } } as unknown as Parameters<typeof PartnerRidersPanel>[0]['supabase']
    const user = userEvent.setup()
    render(<PartnerRidersPanel supabase={supabase} userId="manager-1" onError={vi.fn()} onNotice={vi.fn()} />)

    expect(await screen.findByText('Amina Yusuf')).toBeInTheDocument()
    expect(screen.getByText('Tunde Okoro')).toBeInTheDocument()
    expect(screen.queryByText('Assigned deliveries')).not.toBeInTheDocument()
    expect(from).not.toHaveBeenCalled()
    await user.click(screen.getAllByRole('button', { name: 'Show & edit rider info' })[0])
    expect(await screen.findByText('JOB-12345')).toBeInTheDocument()
    expect(screen.getByText('Eliozu to Rumuokoro')).toBeInTheDocument()
    expect(from).toHaveBeenCalledWith('jobs')
    expect(screen.queryByRole('button', { name: /proof photo/i })).not.toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Show & edit rider info' }))
    expect(screen.getAllByRole('button', { name: 'Hide rider info' })).toHaveLength(1)
    expect(screen.queryByText('Amina Yusuf', { selector: '.rider-details-heading h4' })).not.toBeInTheDocument()
  })

  it('routes a newly invited person through the Super Admin partner application flow', async () => {
    window.history.replaceState({}, '', `/#partner_invite=${'a'.repeat(64)}`)
    const replaceState = vi.spyOn(window.history, 'replaceState')
    const onApplicationRequired = vi.fn()
    const rpc = vi.fn(async () => ({ data: { status: 'application_required', partner_name: 'North Star Logistics', application_id: 'app-1' }, error: null }))
    const supabase = { rpc } as unknown as Parameters<typeof PartnerInvitationClaim>[0]['supabase']
    render(<PartnerInvitationClaim supabase={supabase} onError={vi.fn()} onNotice={vi.fn()} onApplicationRequired={onApplicationRequired} />)

    await userEvent.click(screen.getByRole('button', { name: 'Accept partner invitation' }))

    await waitFor(() => expect(rpc).toHaveBeenCalledWith('accept_partner_staff_invitation', { p_token: 'a'.repeat(64) }))
    expect(onApplicationRequired).toHaveBeenCalledOnce()
    expect(replaceState).toHaveBeenCalled()
    replaceState.mockRestore()
    window.history.replaceState({}, '', '/')
  })
})
