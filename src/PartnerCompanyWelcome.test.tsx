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
      return { data: [record], error: null }
    })
    const upload = vi.fn(async () => ({ error: null }))
    const remove = vi.fn(async () => ({ error: null }))
    const createSignedUrl = vi.fn(async () => ({ data: { signedUrl: 'https://example.test/logo' }, error: null }))
    const supabase = { rpc, storage: { from: () => ({ upload, remove, createSignedUrl }) } } as unknown as ReturnType<typeof getSupabaseClient>
    const onError = vi.fn(), onNotice = vi.fn()
    const user = userEvent.setup()
    render(<PartnerCompanyWelcome supabase={supabase} onError={onError} onNotice={onNotice} />)
    expect(await screen.findByRole('heading', { name: 'Good morning, Ada Okafor' })).toBeInTheDocument()
    expect(screen.getByText('₦24,500.00')).toBeInTheDocument()
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
        : { data: [{ partner_id: 'company-1', partner_name: 'Swift Movers', ceo_name: 'Ada', logo_path: null, earnings_ngn: 0 }], error: null }),
      storage: { from: () => ({ upload: vi.fn(async () => ({ error: null })), remove }) },
    } as unknown as ReturnType<typeof getSupabaseClient>
    const onError = vi.fn()
    render(<PartnerCompanyWelcome supabase={supabase} onError={onError} onNotice={vi.fn()} />)
    await screen.findByRole('heading', { name: /Ada/ })
    await userEvent.setup().upload(screen.getByLabelText('Company logo image'), new File(['logo'], 'logo.png', { type: 'image/png' }))
    await waitFor(() => expect(remove).toHaveBeenCalledOnce())
    expect(onError).toHaveBeenCalledWith('Saving denied')
  })
})
