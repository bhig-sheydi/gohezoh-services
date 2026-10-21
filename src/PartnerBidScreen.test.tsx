import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { SupabaseClient } from '@supabase/supabase-js'
import PartnerBidScreen from './PartnerBidScreen'

function setup(jobs: Record<string, unknown>[], routes: Record<string, unknown>[] = []) {
  const rpc = vi.fn(async (name: string) => name === 'list_partner_bid_screen'
    ? { data: jobs, error: null } : name === 'list_partner_bid_route_addresses'
      ? { data: routes, error: null } : { data: 'bid-1', error: null })
  const createSignedUrl = vi.fn(async () => ({ data: { signedUrl: 'https://example.test/parcel' }, error: null }))
  let onWindowChange = () => {}
  const channel = { on: vi.fn((_type, _filter, callback: () => void) => { onWindowChange = callback; return channel }), subscribe: vi.fn(() => channel) }
  const removeChannel = vi.fn(async () => 'ok')
  const supabase = { rpc, channel: vi.fn(() => channel), removeChannel, storage: { from: () => ({ createSignedUrl }) } } as unknown as SupabaseClient
  return { supabase, rpc, createSignedUrl, broadcastWindowChange: () => onWindowChange(), removeChannel }
}

describe('company bidding screen', () => {
  it('shows an empty screen when no eligible job exists', async () => {
    const { supabase } = setup([])
    render(<PartnerBidScreen supabase={supabase} partnerIds={['partner-1']} onError={vi.fn()} onNotice={vi.fn()} />)
    expect(await screen.findByLabelText('Bidding screen')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Bid' })).not.toBeInTheDocument()
  })

  it('shows parcel details and submits a bid before the deadline', async () => {
    const { supabase, rpc, createSignedUrl } = setup([{
      request_id: 'request-1', request_number: 'REQ-1', pickup_city: 'Umuahia', delivery_city: 'Port Harcourt',
      parcel_summary: 'Books', parcel_items: [{ quantity: 2, weight_kg: 1.5, length_cm: 30, width_cm: 20, height_cm: 10 }],
      photo_path: 'user-1/books.jpg', deadline_at: new Date(Date.now() + 60_000).toISOString(),
      own_bid_amount_ngn: null, own_bid_status: null,
    }])
    const notice = vi.fn()
    render(<PartnerBidScreen supabase={supabase} partnerIds={['partner-1']} onError={vi.fn()} onNotice={notice} />)
    expect(await screen.findByText('Books')).toBeInTheDocument()
    expect(screen.getByText('1.5 kg each')).toBeInTheDocument()
    expect(screen.getByText('30 × 20 × 10 cm each')).toBeInTheDocument()
    expect(await screen.findByAltText('Goods for REQ-1')).toBeInTheDocument()
    expect(createSignedUrl).toHaveBeenCalledWith('user-1/books.jpg', 75)
    fireEvent.click(screen.getByRole('button', { name: 'Bid' }))
    expect(screen.getByLabelText('Total price (NGN)')).toHaveAttribute('min', '1000')
    fireEvent.change(screen.getByLabelText('Total price (NGN)'), { target: { value: '7500' } })
    fireEvent.change(screen.getByLabelText('Delivery estimate (hours)'), { target: { value: '3' } })
    fireEvent.click(screen.getByLabelText(/I confirm availability/))
    fireEvent.submit(screen.getByRole('button', { name: 'Submit bid' }).closest('form')!)
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('submit_partner_quote', expect.objectContaining({ p_request_id: 'request-1', p_amount_ngn: 7500, p_eta_hours: 3 })))
    expect(notice).toHaveBeenCalledWith('Your private bid was submitted.')
  })

  it('shows the saved pickup and drop-off instead of repeating the city', async () => {
    const { supabase } = setup([{
      request_id: 'request-1', request_number: 'REQ-1', pickup_city: 'Port Harcourt', delivery_city: 'Port Harcourt',
      parcel_summary: 'Parcel', parcel_items: [], photo_path: null,
      deadline_at: new Date(Date.now() + 60_000).toISOString(), own_bid_amount_ngn: null,
    }], [{ request_id: 'request-1', pickup_address: 'Police Post, Eliozu', delivery_address: 'Farm Road 2, Eliozu' }])
    render(<PartnerBidScreen supabase={supabase} partnerIds={['partner-1']} onError={vi.fn()} onNotice={vi.fn()} />)
    expect(await screen.findByText('Police Post, Eliozu')).toBeInTheDocument()
    expect(screen.getByText('Farm Road 2, Eliozu')).toBeInTheDocument()
  })

  it('does not show expired jobs', async () => {
    const { supabase } = setup([{ request_id: 'expired', deadline_at: new Date(Date.now() - 1000).toISOString() }])
    render(<PartnerBidScreen supabase={supabase} partnerIds={['partner-1']} onError={vi.fn()} onNotice={vi.fn()} />)
    await screen.findByLabelText('Bidding screen')
    await waitFor(() => expect(screen.queryByRole('button', { name: 'Bid' })).not.toBeInTheDocument())
  })

  it('receives a new eligible job without a manual refresh', async () => {
    const { supabase, rpc, broadcastWindowChange } = setup([])
    render(<PartnerBidScreen supabase={supabase} partnerIds={['partner-1']} onError={vi.fn()} onNotice={vi.fn()} />)
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('list_partner_bid_screen'))
    rpc.mockImplementation(async (name: string) => name === 'list_partner_bid_screen'
      ? { data: [{ request_id: 'new-job', request_number: 'REQ-NEW', pickup_city: 'Lagos', delivery_city: 'Lagos', parcel_summary: 'Test parcel', parcel_items: [], photo_path: null, deadline_at: new Date(Date.now() + 60_000).toISOString(), own_bid_amount_ngn: null }], error: null }
      : { data: 'bid-1', error: null })
    broadcastWindowChange()
    expect(await screen.findByText('REQ-NEW')).toBeInTheDocument()
  })
})
