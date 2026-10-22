import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it, vi } from 'vitest'
import PartnerCompanyWelcome from './PartnerCompanyWelcome'
import { getSupabaseClient } from './lib/supabase'

afterEach(() => vi.useRealTimers())

describe('company welcome', () => {
  it('uses the device clock, shows confirmed earnings, and replaces the logo', async () => {
    vi.setSystemTime(new Date(2026, 9, 15, 9, 30))
    const record = { partner_id: 'company-1', partner_name: 'Swift Movers', ceo_name: 'Ada Okafor', logo_path: null as string | null, earnings_ngn: 24500 }
    const rpc = vi.fn(async (name: string, args?: { p_path?: string }) => {
      if (name === 'set_my_partner_logo') { record.logo_path = args?.p_path ?? null; return { data: record.logo_path, error: null } }
      if (name === 'get_my_partner_payables') return { data: [{ partner_id: 'company-1', currency: 'NGN', available_ngn: 5000, pending_delivery_ngn: 2500, withdrawal_pending_ngn: 0, total_paid_ngn: 0 }], error: null }
      if (name === 'list_my_partner_withdrawals') return { data: [], error: null }
      return { data: [record], error: null }
    })
    const upload = vi.fn(async () => ({ error: null }))
    const remove = vi.fn(async () => ({ error: null }))
    const createSignedUrl = vi.fn(async () => ({ data: { signedUrl: 'https://example.test/logo' }, error: null }))
    const invoke = vi.fn(async (_name: string, args: { body: { action: string } }) => args.body.action === 'account'
      ? { data: { account: { bankName: 'Access Bank', accountLast4: '7890', accountName: 'Swift Movers', verifiedAt: '2026-10-15T00:00:00Z' } }, error: null }
      : args.body.action === 'withdraw' ? { data: { withdrawalId: 'withdrawal-1', status: 'queued', amountNgn: 5000 }, error: null }
      : { data: {}, error: null })
    const supabase = { rpc, functions: { invoke }, storage: { from: () => ({ upload, remove, createSignedUrl }) } } as unknown as ReturnType<typeof getSupabaseClient>
    const onError = vi.fn(), onNotice = vi.fn()
    const user = userEvent.setup()
    render(<PartnerCompanyWelcome supabase={supabase} onError={onError} onNotice={onNotice} />)
    expect(await screen.findByRole('heading', { name: 'Good morning, Ada Okafor' })).toBeInTheDocument()
    expect(screen.getByText('₦24,500.00')).toBeInTheDocument()
    expect(screen.getByText('Available to withdraw')).toBeInTheDocument()
    expect(screen.getByText('Paid deliveries awaiting confirmation')).toBeInTheDocument()
    await user.click(await screen.findByRole('button', { name: 'Withdraw' }))
    expect(screen.getByText(/ending 7890/)).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Confirm withdrawal' }))
    await waitFor(() => expect(invoke).toHaveBeenCalledWith('flutterwave-payout', { body: expect.objectContaining({ action: 'withdraw', partnerId: 'company-1', amountNgn: 5000 }) }))
    expect(onNotice).toHaveBeenCalledWith('Withdrawal submitted. Check its status below.')
    expect(rpc).toHaveBeenCalledWith('my_partner_company_welcome', {
      p_day_start: new Date(2026, 9, 15).toISOString(),
      p_day_end: new Date(2026, 9, 16).toISOString(),
    })
    await user.upload(screen.getByLabelText('Company logo image'), new File(['logo'], 'logo.png', { type: 'image/png' }))
    await waitFor(() => expect(upload).toHaveBeenCalledOnce())
    expect(await screen.findByAltText('Swift Movers logo')).toHaveAttribute('src', 'https://example.test/logo')
    expect(onNotice).toHaveBeenCalledWith('Company logo saved.')
    expect(onError).not.toHaveBeenCalled()
  })

  it('removes an uploaded logo when metadata saving fails', async () => {
    const remove = vi.fn(async () => ({ error: null }))
    const supabase = {
      rpc: vi.fn(async (name: string) => name === 'set_my_partner_logo'
        ? { error: { message: 'Saving denied' } }
        : name === 'list_my_partner_withdrawals' ? { data: [], error: null }
        : name === 'get_my_partner_payables' ? { data: [], error: null }
        : { data: [{ partner_id: 'company-1', partner_name: 'Swift Movers', ceo_name: 'Ada', logo_path: null, earnings_ngn: 0 }], error: null }),
      functions: { invoke: vi.fn(async () => ({ data: { account: null }, error: null })) },
      storage: { from: () => ({ upload: vi.fn(async () => ({ error: null })), remove }) },
    } as unknown as ReturnType<typeof getSupabaseClient>
    const onError = vi.fn()
    render(<PartnerCompanyWelcome supabase={supabase} onError={onError} onNotice={vi.fn()} />)
    await screen.findByRole('heading', { name: /Ada/ })
    await userEvent.setup().upload(screen.getByLabelText('Company logo image'), new File(['logo'], 'logo.png', { type: 'image/png' }))
    await waitFor(() => expect(remove).toHaveBeenCalledOnce())
    expect(onError).toHaveBeenCalledWith('Saving denied')
  })

  it('does not request another withdrawal when all funds are pending or already reserved', async () => {
    const rpc = vi.fn(async (name: string) => name === 'get_my_partner_payables'
      ? { data: [{ partner_id: 'company-1', currency: 'NGN', available_ngn: 0, pending_delivery_ngn: 750, withdrawal_pending_ngn: 300, total_paid_ngn: 0 }], error: null }
      : name === 'list_my_partner_withdrawals' ? { data: [], error: null }
      : { data: [{ partner_id: 'company-1', partner_name: 'Swift Movers', ceo_name: 'Ada', logo_path: null, earnings_ngn: 0 }], error: null })
    const supabase = { rpc, functions: { invoke: vi.fn(async () => ({ data: { account: null }, error: null })) } } as unknown as ReturnType<typeof getSupabaseClient>
    render(<PartnerCompanyWelcome supabase={supabase} onError={vi.fn()} onNotice={vi.fn()} />)
    expect(await screen.findByText('Paid deliveries awaiting confirmation')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Withdraw' })).toBeDisabled()
    expect(screen.getByText(/Transfer in progress/)).toBeInTheDocument()
  })

  it('verifies a bank account and requires confirmation before saving the destination', async () => {
    const rpc = vi.fn(async (name: string) => name === 'get_my_partner_payables'
      ? { data: [{ partner_id: 'company-1', currency: 'NGN', available_ngn: 3000, pending_delivery_ngn: 0, withdrawal_pending_ngn: 0, total_paid_ngn: 0 }], error: null }
      : name === 'list_my_partner_withdrawals' ? { data: [], error: null }
      : { data: [{ partner_id: 'company-1', partner_name: 'Swift Movers', ceo_name: 'Ada', logo_path: null, earnings_ngn: 0 }], error: null })
    const invoke = vi.fn(async (_name: string, args: { body: { action: string } }) => {
      if (args.body.action === 'banks') return { data: { banks: [{ code: '044', name: 'Access Bank' }] }, error: null }
      if (args.body.action === 'resolve') return { data: { bankCode: '044', bankName: 'Access Bank', accountNumber: '1234567890', accountName: 'Swift Movers' }, error: null }
      if (args.body.action === 'save-account') return { data: { account: { bankName: 'Access Bank', accountLast4: '7890', accountName: 'Swift Movers', verifiedAt: '2026-10-15T00:00:00Z' } }, error: null }
      return { data: { account: null }, error: null }
    })
    const supabase = { rpc, functions: { invoke } } as unknown as ReturnType<typeof getSupabaseClient>
    const user = userEvent.setup()
    render(<PartnerCompanyWelcome supabase={supabase} onError={vi.fn()} onNotice={vi.fn()} />)
    await user.click(await screen.findByRole('button', { name: 'Add bank account' }))
    await user.selectOptions(await screen.findByLabelText('Bank'), '044')
    await user.type(screen.getByLabelText('Account number'), '1234567890')
    await user.click(screen.getByRole('button', { name: 'Verify account' }))
    expect(await screen.findByText('Swift Movers', { selector: '.partner-payout-resolved strong' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Verify account' })).toBeDisabled()
    expect(invoke).not.toHaveBeenCalledWith('flutterwave-payout', { body: expect.objectContaining({ action: 'save-account' }) })
    await user.click(screen.getByRole('button', { name: 'Confirm and save' }))
    expect(await screen.findByText(/7890/, { selector: '.partner-payout-destination small' })).toBeInTheDocument()
    expect(invoke).toHaveBeenCalledWith('flutterwave-payout', { body: expect.objectContaining({ action: 'save-account', partnerId: 'company-1', accountName: 'Swift Movers' }) })
  })

  it('shows the bank verification response instead of the generic Edge Function error', async () => {
    const rpc = vi.fn(async (name: string) => name === 'get_my_partner_payables'
      ? { data: [{ partner_id: 'company-1', available_ngn: 0, pending_delivery_ngn: 0, withdrawal_pending_ngn: 0 }], error: null }
      : name === 'list_my_partner_withdrawals' ? { data: [], error: null }
      : { data: [{ partner_id: 'company-1', partner_name: 'Swift Movers', ceo_name: 'Ada', logo_path: null, earnings_ngn: 0 }], error: null })
    const onError = vi.fn()
    const invoke = vi.fn(async (_name: string, args: { body: { action: string } }) => args.body.action === 'banks'
      ? { data: { banks: [{ code: '044', name: 'Access Bank' }], testMode: true, verificationTestMode: true }, error: null }
      : args.body.action === 'resolve'
        ? { data: null, error: { message: 'Edge Function returned a non-2xx status code', context: new Response(JSON.stringify({ error: 'Flutterwave test mode accepts sample bank accounts only.' }), { status: 422 }) } }
        : { data: { account: null }, error: null })
    const supabase = { rpc, functions: { invoke } } as unknown as ReturnType<typeof getSupabaseClient>
    const user = userEvent.setup()
    render(<PartnerCompanyWelcome supabase={supabase} onError={onError} onNotice={vi.fn()} />)
    await user.click(await screen.findByRole('button', { name: 'Add bank account' }))
    expect(screen.getByText(/Flutterwave accepts Access Bank sample accounts/)).toBeInTheDocument()
    await user.selectOptions(await screen.findByLabelText('Bank'), '044')
    await user.type(screen.getByLabelText('Account number'), '1234567890')
    await user.click(screen.getByRole('button', { name: 'Verify account' }))
    await waitFor(() => expect(onError).toHaveBeenCalledWith('Flutterwave test mode accepts sample bank accounts only.'))
  })
})
