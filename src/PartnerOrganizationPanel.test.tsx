import { describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { PartnerInvitationClaim, PartnerOrganizationPanel } from './PartnerOrganizationPanel'

describe('partner organization invitations', () => {
  it('lets a company manager create a role-scoped invitation link', async () => {
    const rpc = vi.fn(async (name: string) => {
      if (name === 'list_my_partner_team') return { data: [{ partner_id: 'partner-1', partner_name: 'North Star Logistics', user_id: 'manager-1', email: 'manager@example.test', full_name: 'Manager', membership_role: 'manager', is_manager: true }], error: null }
      if (name === 'list_partner_staff_invitations') return { data: [], error: null }
      if (name === 'create_partner_staff_invitation') return { data: [{ invitation_id: 'invite-1', invite_token: 'a'.repeat(64), expires_at: '2026-11-01T00:00:00Z' }], error: null }
      return { data: [], error: null }
    })
    const supabase = { rpc } as unknown as Parameters<typeof PartnerOrganizationPanel>[0]['supabase']
    const user = userEvent.setup()
    render(<PartnerOrganizationPanel supabase={supabase} userId="manager-1" onError={vi.fn()} onNotice={vi.fn()} />)

    await user.type(await screen.findByLabelText('Invitee email address'), 'rider@example.test')
    await user.selectOptions(screen.getByLabelText('Team role'), 'rider')
    await user.click(screen.getByRole('button', { name: 'Create invitation link' }))

    await waitFor(() => expect(rpc).toHaveBeenCalledWith('create_partner_staff_invitation', {
      p_partner_id: 'partner-1', p_email: 'rider@example.test', p_membership_role: 'rider',
    }))
    const inviteLink = await screen.findByDisplayValue(/partner_invite=/)
    expect((inviteLink as HTMLInputElement).value).toContain('partner_invite=')
  })

  it('lets a partner manager assign an accepted pickup to an individual rider', async () => {
    const rpc = vi.fn(async (name: string) => {
      if (name === 'list_my_partner_team') return { data: [
        { partner_id: 'partner-1', partner_name: 'North Star Logistics', user_id: 'manager-1', email: 'manager@example.test', full_name: 'Manager', membership_role: 'manager', is_manager: true },
        { partner_id: 'partner-1', partner_name: 'North Star Logistics', user_id: 'rider-1', email: 'rider@example.test', full_name: 'Rider', membership_role: 'rider', is_manager: false },
      ], error: null }
      if (name === 'list_partner_rider_jobs') return { data: [{ partner_id: 'partner-1', job_id: 'job-1', job_number: 'JOB-12345', status: 'partner_assigned', assigned_rider_id: null }], error: null }
      if (name === 'list_partner_staff_invitations') return { data: [], error: null }
      return { data: { status: 'assigned' }, error: null }
    })
    const onNotice = vi.fn()
    const supabase = { rpc } as unknown as Parameters<typeof PartnerOrganizationPanel>[0]['supabase']
    render(<PartnerOrganizationPanel supabase={supabase} userId="manager-1" onError={vi.fn()} onNotice={onNotice} />)

    await userEvent.selectOptions(await screen.findByLabelText('Rider for JOB-12345'), 'rider-1')
    await userEvent.click(screen.getByRole('button', { name: 'Assign rider' }))

    await waitFor(() => expect(rpc).toHaveBeenCalledWith('assign_job_to_rider', { p_job_id: 'job-1', p_rider_user_id: 'rider-1' }))
    expect(onNotice).toHaveBeenCalledWith('Rider assigned to JOB-12345. A rider may have up to five active pickups.')
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
