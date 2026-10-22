import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import type { SupabaseClient } from '@supabase/supabase-js'
import CompanyOperationsStaffPanel from './CompanyOperationsStaffPanel'
import { CompanyStaffDashboard } from './CompanyStaffApp'

describe('company operations delegation', () => {
  it('creates a password-only staff account with only checked permissions', async () => {
    const invoke = vi.fn(async (_name: string, options: { body: Record<string, unknown> }) => {
      if (options.body.action === 'list') return { data: { staff: [], alerts: [] }, error: null }
      return { data: { staffId: '11111111-1111-1111-1111-111111111111', password: 'Market-River-Mango-Table-1234' }, error: null }
    })
    const supabase = { functions: { invoke } } as unknown as SupabaseClient
    const user = userEvent.setup()
    render(<CompanyOperationsStaffPanel supabase={supabase} partnerId="partner-1" onError={vi.fn()} onNotice={vi.fn()} />)
    await user.click(screen.getByRole('button', { name: 'Add operations staff' }))
    await user.type(screen.getByLabelText('Full name'), 'Ada Okafor')
    await user.click(screen.getByLabelText('Place bids'))
    await user.click(screen.getByRole('button', { name: 'Create staff access' }))
    await waitFor(() => expect(invoke).toHaveBeenCalledWith('company-staff-access', { body: expect.objectContaining({
      action: 'create', partnerId: 'partner-1', fullName: 'Ada Okafor', canBid: true, canManageRiders: false, canWithdraw: false,
    }) }))
    expect(await screen.findByDisplayValue('Market-River-Mango-Table-1234')).toBeInTheDocument()
    expect(screen.getByDisplayValue(/company-staff#staff=11111111/)).toBeInTheDocument()
  })

  it('lets the owner change staff permissions without exposing account management to staff', async () => {
    const person = { id: 'staff-1', full_name: 'Ada Okafor', can_bid: true, can_manage_riders: false, can_withdraw: false,
      password_revoked_at: null, revoked_at: null, company_operations_staff_devices: [] }
    const invoke = vi.fn(async (_name: string, options: { body: Record<string, unknown> }) => options.body.action === 'list'
      ? { data: { staff: [person], alerts: [] }, error: null } : { data: { ok: true }, error: null })
    const supabase = { functions: { invoke } } as unknown as SupabaseClient
    const user = userEvent.setup()
    render(<CompanyOperationsStaffPanel supabase={supabase} partnerId="partner-1" onError={vi.fn()} onNotice={vi.fn()} />)
    await user.click(await screen.findByLabelText('Manage riders'))
    await user.click(screen.getByRole('button', { name: 'Save permissions' }))
    await waitFor(() => expect(invoke).toHaveBeenCalledWith('company-staff-access', { body: expect.objectContaining({
      action: 'permissions', staffId: 'staff-1', canBid: true, canManageRiders: true, canWithdraw: false,
    }) }))
  })

  it('hides actions without permission', async () => {
    const rpc = vi.fn(async () => ({ data: [{ staff_id: 'staff-1', partner_id: 'partner-1', full_name: 'Ada Okafor', can_bid: false, can_manage_riders: false, can_withdraw: false }], error: null }))
    const signOut = vi.fn(async () => ({ error: null }))
    const supabase = { rpc, auth: { signOut } } as unknown as SupabaseClient
    render(<CompanyStaffDashboard supabase={supabase} userId="staff-user" onError={vi.fn()} onNotice={vi.fn()} />)
    expect(await screen.findByLabelText('Bidding unavailable')).toBeInTheDocument()
    expect(screen.getByLabelText('Rider management unavailable')).toBeInTheDocument()
    expect(screen.getByLabelText('Withdrawals unavailable')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Add operations staff' })).not.toBeInTheDocument()
    expect(signOut).not.toHaveBeenCalled()
  })

  it('signs out when the database no longer reports active staff access', async () => {
    const signOut = vi.fn(async () => ({ error: null }))
    const supabase = { rpc: vi.fn(async () => ({ data: [], error: null })), auth: { signOut } } as unknown as SupabaseClient
    render(<CompanyStaffDashboard supabase={supabase} userId="staff-user" onError={vi.fn()} onNotice={vi.fn()} />)
    await waitFor(() => expect(signOut).toHaveBeenCalledOnce())
  })
})
