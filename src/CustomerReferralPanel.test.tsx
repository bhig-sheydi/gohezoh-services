import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import type { SupabaseClient } from '@supabase/supabase-js'
import CustomerReferralPanel from './CustomerReferralPanel'

describe('customer referral program', () => {
  it('requires opt-in before showing a code and then shows the shared signup link', async () => {
    let joined = false
    const rpc = vi.fn(async (name: string) => {
      if (name === 'join_customer_referral_program') { joined = true; return { data: 'KP1234567890', error: null } }
      return { data: { year: 2026, member: joined ? {
        code: 'KP1234567890', display_name: 'Ada', rank: 1,
        earned_ngn: 125, completed_job_value_ngn: 20000,
      } : null, leaders: [] }, error: null }
    })
    const supabase = { rpc } as unknown as SupabaseClient
    render(<CustomerReferralPanel supabase={supabase} onError={vi.fn()} onNotice={vi.fn()} />)
    const user = userEvent.setup()
    expect(await screen.findByRole('button', { name: 'Join referral program' })).toBeInTheDocument()
    expect(screen.queryByLabelText('Your customer referral code')).not.toBeInTheDocument()
    await user.type(screen.getByLabelText('Public leaderboard name'), 'Ada')
    await user.click(screen.getByRole('button', { name: 'Join referral program' }))
    await waitFor(() => expect(screen.getByLabelText('Your customer referral code')).toHaveValue('KP1234567890'))
    expect(screen.getByLabelText('Your customer referral link')).toHaveValue('https://gohezoh-services.vercel.app/?ref=KP1234567890')
    expect(screen.getByText(/20,000.*500,000/)).toBeInTheDocument()
  })
})
