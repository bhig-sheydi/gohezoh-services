import { describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { CustomerQuotePanel, PartnerBidQueue } from './QuotePanels'

function client(rows: Record<string, Array<Record<string, unknown>>>) {
  const rpc = vi.fn(async (name: string) => name === 'list_eligible_delivery_requests'
    ? { data: rows.eligible ?? [], error: null }
    : name === 'list_partner_bid_route_addresses' ? { data: rows.routes ?? [], error: null }
    : name === 'list_customer_bid_offers' ? { data: rows.offers ?? [], error: null }
    : name === 'list_customer_bid_state' ? { data: { windows: rows.delivery_quote_windows ?? [], quotes: rows.customer_delivery_quotes ?? [], holds: rows.holds ?? [] }, error: null }
    : name === 'list_my_flutterwave_holds' ? { data: rows.holds ?? [], error: null }
    : { data: null, error: null })
  const functions = { invoke: vi.fn(async () => ({ data: { status: 'pending' }, error: null })) }
  const from = vi.fn((table: string) => {
    const query: Record<string, unknown> = {}
    for (const method of ['select', 'in']) query[method] = () => query
    query.then = (resolve: (value: unknown) => unknown) => Promise.resolve({ data: rows[table] ?? [], error: null }).then(resolve)
    return query
  })
  const storage = { from: vi.fn(() => ({ createSignedUrl: vi.fn(async () => ({ data: { signedUrl: 'https://example.test/rider-photo' }, error: null })) })) }
  return { supabase: { from, rpc, storage, functions } as unknown as SupabaseClient, rpc, from, functions }
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

  it('shows matching progress while the one-minute window is open', async () => {
    const { supabase } = client({ delivery_quote_windows: [{ request_id: 'request-1', deadline_at: new Date(Date.now() + 45_000).toISOString(), status: 'open' }] })
    render(<CustomerQuotePanel supabase={supabase} requestIds={['request-1']} pendingRequestIds={['request-1']} onError={vi.fn()} onNotice={vi.fn()} onRefresh={vi.fn()} />)
    expect(await screen.findByRole('progressbar', { name: 'Company response window' })).toBeInTheDocument()
    expect(screen.getByText('Finding interested riders')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Choose this company' })).not.toBeInTheDocument()
  })

  it('shows company and rider details only after closing, then saves the customer choice', async () => {
    const { supabase, functions } = client({
      delivery_quote_windows: [{ request_id: 'request-1', deadline_at: '2020-01-01T00:00:00Z', status: 'awaiting_customer_selection' }],
      offers: [{ bid_id: 'bid-1', partner_name: 'Swift Bikes', partner_phone: '08012345678', rider_name: 'Ada Rider',
        rider_phone: null, rider_photo_path: 'photo.jpg', bid_amount_ngn: 2500, eta_hours: 1 }],
    })
    render(<CustomerQuotePanel supabase={supabase} requestIds={['request-1']} onError={vi.fn()} onNotice={vi.fn()} onRefresh={vi.fn()} />)
    expect(await screen.findByText('You have 1 interested company')).toBeInTheDocument()
    expect(screen.getByAltText('Ada Rider profile')).toHaveAttribute('src', 'https://example.test/rider-photo')
    expect(screen.getByText('Rider: Number not supplied')).toBeInTheDocument()
    expect(screen.getByText('Company: 08012345678')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Choose this company' }))
    await waitFor(() => expect(functions.invoke).toHaveBeenCalledWith('flutterwave-payment', { body: { action: 'start', requestId: 'request-1', bidId: 'bid-1' } }))
  })

  it('shows the temporary account and exact selected bid amount', async () => {
    const { supabase } = client({ holds: [{ request_id: 'request-1', status: 'pending', amount_ngn: 2500,
      account_number: '1234567890', bank_name: 'Test Bank', expires_at: new Date(Date.now() + 120_000).toISOString(), reference: 'test-ref' }] })
    render(<CustomerQuotePanel supabase={supabase} requestIds={['request-1']} onError={vi.fn()} onNotice={vi.fn()} onRefresh={vi.fn()} />)
    expect(await screen.findByText('1234567890')).toBeInTheDocument()
    expect(screen.getByText(/Pay ₦2,500.00/)).toBeInTheDocument()
    expect(screen.getByText(/Your rider waits until payment is confirmed/)).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Copy account' }))
    expect(await screen.findByText(/Press and hold the account number/)).toBeInTheDocument()
  })

  it('hides old paid and expired notices but keeps recent payment and review notices', async () => {
    const old = new Date(Date.now() - 12 * 60_000).toISOString()
    const recent = new Date(Date.now() - 5 * 60_000).toISOString()
    const { supabase } = client({ holds: [
      { request_id: 'old-paid', status: 'paid', amount_ngn: 2000, account_number: null, bank_name: null, expires_at: old, reference: 'p1' },
      { request_id: 'recent-paid', status: 'paid', amount_ngn: 2000, account_number: null, bank_name: null, expires_at: old, reference: 'p2' },
      { request_id: 'old-expired', status: 'expired', amount_ngn: 2000, account_number: null, bank_name: null, expires_at: old, reference: 'p3' },
      { request_id: 'review', status: 'review', amount_ngn: 2000, account_number: null, bank_name: null, expires_at: old, reference: 'p4' },
    ] })
    render(<CustomerQuotePanel supabase={supabase} requestIds={['old-paid', 'recent-paid', 'old-expired', 'review']} paymentReceivedAtByRequest={{ 'old-paid': old, 'recent-paid': recent }} onError={vi.fn()} onNotice={vi.fn()} onRefresh={vi.fn()} />)
    await waitFor(() => expect(screen.getAllByRole('status', { name: 'Delivery payment' })).toHaveLength(2))
    expect(screen.getByText('Payment confirmed')).toBeInTheDocument()
    expect(screen.getByText('Payment needs review')).toBeInTheDocument()
    expect(screen.getAllByAltText('Kwik-Parsel logo')).toHaveLength(2)
    expect(screen.queryByText('Booking expired')).not.toBeInTheDocument()
  })

  it('marks a recent expired booking as an alert with the app logo', async () => {
    const expiresAt = new Date(Date.now() - 60_000).toISOString()
    const { supabase } = client({ holds: [{ request_id: 'request-1', status: 'expired', amount_ngn: 2000,
      account_number: null, bank_name: null, expires_at: expiresAt, reference: 'p1' }] })
    render(<CustomerQuotePanel supabase={supabase} requestIds={['request-1']} onError={vi.fn()} onNotice={vi.fn()} onRefresh={vi.fn()} />)
    const alert = await screen.findByRole('status', { name: 'Delivery payment' })
    expect(alert).toHaveClass('customer-payment-expired')
    expect(screen.getByAltText('Kwik-Parsel logo')).toHaveAttribute('src', '/favicon.svg')
  })

  it('removes a paid notice when its ten-minute browser timer ends', async () => {
    const receivedAt = new Date(Date.now() - 10 * 60_000 + 1500).toISOString()
    const { supabase } = client({ holds: [{ request_id: 'request-1', status: 'paid', amount_ngn: 2000,
      account_number: null, bank_name: null, expires_at: receivedAt, reference: 'p1' }] })
    render(<CustomerQuotePanel supabase={supabase} requestIds={['request-1']} paymentReceivedAtByRequest={{ 'request-1': receivedAt }} onError={vi.fn()} onNotice={vi.fn()} onRefresh={vi.fn()} />)
    expect(await screen.findByText('Payment confirmed')).toBeInTheDocument()
    await waitFor(() => expect(screen.queryByText('Payment confirmed')).not.toBeInTheDocument(), { timeout: 3000 })
  })
})

describe('partner bidding', () => {
  it('shows saved route addresses when pickup and drop-off share a city', async () => {
    const { supabase } = client({ eligible: [{ request_id: 'request-1', request_number: 'REQ-0001', pickup_city: 'Port Harcourt', delivery_city: 'Port Harcourt', parcel_summary: 'Parcel', deadline_at: '2030-01-01T12:00:00Z' }], routes: [{ request_id: 'request-1', pickup_address: 'Police Post, Eliozu', delivery_address: 'Farm Road 2, Eliozu' }] })
    render(<PartnerBidQueue supabase={supabase} partnerIds={['partner-1']} onError={vi.fn()} onNotice={vi.fn()} />)
    expect(await screen.findByText(/Police Post, Eliozu → Farm Road 2, Eliozu/)).toBeInTheDocument()
  })
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
