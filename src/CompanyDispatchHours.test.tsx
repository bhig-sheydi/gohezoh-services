import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { SupabaseClient } from '@supabase/supabase-js'
import CompanyDispatchHours from './CompanyDispatchHours'

describe('company dispatch hours', () => {
  it('shows a labelled rough estimate and saves the owner closing time', async () => {
    const rpc = vi.fn(async (name: string) => name === 'my_company_dispatch_hours'
      ? { data: [{ closes_at: '2026-10-23T17:00:00Z', source: 'registration', online_riders: 2, rough_extra_rides: 4 }], error: null }
      : { data: '2026-10-23T18:00:00Z', error: null })
    const notice = vi.fn()
    render(<CompanyDispatchHours supabase={{ rpc } as unknown as SupabaseClient} partnerId="company-1" onError={vi.fn()} onNotice={notice} />)
    expect(await screen.findByText(/roughly possible additional rides across 2 online riders/)).toBeInTheDocument()
    fireEvent.change(screen.getByLabelText('Change closing time'), { target: { value: '19:00' } })
    const nextDay = screen.getByLabelText('Tomorrow') as HTMLInputElement
    if (!nextDay.checked) fireEvent.click(nextDay)
    fireEvent.click(screen.getByRole('button', { name: 'Save closing time' }))
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('set_my_company_closing_time', {
      p_partner: 'company-1', p_time: '19:00', p_next_day: true,
    }))
    expect(notice).toHaveBeenCalled()
  })
})
