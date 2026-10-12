import { describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { CustomerQuotePanel, PartnerBidQueue } from './QuotePanels'

function client(rows: Record<string, Array<Record<string, unknown>>>) {
  const rpc = vi.fn(async (name: string) => name === 'list_eligible_delivery_requests'
    ? { data: rows.eligible ?? [], error: null }
    : { data: null, error: null })
  const from = vi.fn((table: string) => {
    const query: Record<string, unknown> = {}
    for (const method of ['select', 'in']) query[method] = () => query
    query.then = (resolve: (value: unknown) => unknown) => Promise.resolve({ data: rows[table] ?? [], error: null }).then(resolve)
    return query
  })
  return { supabase: { from, rpc } as unknown as SupabaseClient, rpc, from }
}

describe('customer delivery quotes', () => {
  it('shows the final price and accepts only the customer quote for that request', async () => {
    const { supabase, rpc } = client({ customer_delivery_quotes: [{ request_id: 'request-1', customer_price_ngn: 10000, expires_at: '2030-01-01T12:00:00Z', status: 'sent' }] })
    const notice = vi.fn()
    render(<CustomerQuotePanel supabase={supabase} requestIds={['request-1']} onError={vi.fn()} onNotice={notice} onRefresh={vi.fn()} />)
    expect(await screen.findByText(/Delivery quote: ₦10,000.00/)).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Accept quote' }))
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('accept_customer_delivery_quote', { p_request_id: 'request-1' }))
    expect(notice).toHaveBeenCalledWith(expect.stringContaining('Quote accepted'))
  })

  it('does not offer acceptance before Management sends a final price', async () => {
    const { supabase } = client({ customer_delivery_quotes: [{ request_id: 'request-1', customer_price_ngn: null, expires_at: null, status: 'pending_price' }] })
    render(<CustomerQuotePanel supabase={supabase} requestIds={['request-1']} onError={vi.fn()} onNotice={vi.fn()} onRefresh={vi.fn()} />)
    expect(await screen.findByText('Quote under review')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Accept quote' })).not.toBeInTheDocument()
  })
})

describe('partner bidding', () => {
  it('uses the sanitized eligibility RPC and submits availability and declared conditions', async () => {
    const { supabase, rpc, from } = client({ eligible: [{ request_id: 'request-1', request_number: 'REQ-0001', pickup_city: 'Lagos', delivery_city: 'Aba', parcel_summary: 'Two cartons', preferred_pickup_at: null, special_instructions: null, deadline_at: '2030-01-01T12:00:00Z', own_bid_amount_ngn: null, own_bid_status: null }] })
    render(<PartnerBidQueue supabase={supabase} partnerIds={['partner-1']} onError={vi.fn()} onNotice={vi.fn()} />)
    expect(await screen.findByText('Two cartons')).toBeInTheDocument()
    expect(from).not.toHaveBeenCalledWith('partner_quotes')
    expect(from).not.toHaveBeenCalledWith('service_requests')
    fireEvent.change(screen.getByLabelText('Total price (NGN)'), { target: { value: '7500' } })
    fireEvent.change(screen.getByLabelText('Delivery estimate (hours)'), { target: { value: '24' } })
    fireEvent.change(screen.getByLabelText('Inclusions'), { target: { value: 'Pickup and delivery' } })
    fireEvent.change(screen.getByLabelText('Exclusions'), { target: { value: 'None' } })
    fireEvent.change(screen.getByLabelText('Surcharge conditions (write None if none)'), { target: { value: 'None' } })
    fireEvent.click(screen.getByLabelText(/I confirm availability/))
    fireEvent.submit(screen.getByRole('button', { name: 'Submit private quote' }).closest('form')!)
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('submit_partner_quote', { p_request_id: 'request-1', p_amount_ngn: 7500, p_eta_hours: 24, p_inclusions: 'Pickup and delivery', p_exclusions: 'None', p_availability_confirmed: true, p_surcharge_conditions: 'None' }))
  })

  it('shows only the caller’s own bid returned by the sanitized RPC', async () => {
    const { supabase, from } = client({ eligible: [{ request_id: 'request-1', request_number: 'REQ-0001', pickup_city: 'Lagos', delivery_city: 'Aba', parcel_summary: 'Two cartons', preferred_pickup_at: null, special_instructions: null, deadline_at: '2030-01-01T12:00:00Z', own_bid_amount_ngn: 7500, own_bid_status: 'valid' }] })
    render(<PartnerBidQueue supabase={supabase} partnerIds={['partner-1']} onError={vi.fn()} onNotice={vi.fn()} />)
    expect(await screen.findByText(/Your quote: ₦7,500.00/)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Submit private quote' })).not.toBeInTheDocument()
    expect(from).not.toHaveBeenCalled()
  })
})
