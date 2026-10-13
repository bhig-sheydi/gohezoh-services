import { describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MarketerPortal } from './MarketerPortal'

describe('marketer portal', () => {
  it('shows the marketer-specific referral link and attributed customer count', async () => {
    const rpc = vi.fn(async (name: string) => name === 'get_my_marketer_referral_code'
      ? { data: 'M123456789AB', error: null }
      : name === 'get_my_marketer_referral_count' ? { data: 7, error: null } : { data: [{ id: 'earning-1', job_id: '12345678-1234', eligible_amount_ngn: 25000, calculated_amount_ngn: 2500, status: 'calculated', payment_reference: 'RCPT-1', created_at: '2026-10-13T00:00:00Z' }], error: null })
    const supabase = { rpc } as unknown as Parameters<typeof MarketerPortal>[0]['supabase']
    render(<MarketerPortal supabase={supabase} onError={vi.fn()} />)
    expect(await screen.findByLabelText('Personal marketer referral link')).toHaveValue(`${window.location.origin}/?ref=M123456789AB`)
    expect(screen.getByText('7')).toBeInTheDocument()
    expect(await screen.findByText('Job 12345678')).toBeInTheDocument()
    expect(screen.getByText(/Earned ₦2,500/)).toBeInTheDocument()
  })
})
