import { describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { getSupabaseClient } from './lib/supabase'
import ParcelPalsPanel from './ParcelPalsPanel'
import { getAddressFromCurrentPosition } from './lib/geoapify-geocoding'

vi.mock('./lib/geoapify-geocoding', () => ({ getAddressFromCurrentPosition: vi.fn() }))

type Client = ReturnType<typeof getSupabaseClient>

function makeClient(rpc: ReturnType<typeof vi.fn>, ownPhoto: string | null = null) {
  const upsert = vi.fn(() => ({ abortSignal: vi.fn(async () => ({ error: null })) }))
  const profileQuery = {
    select: vi.fn(() => profileQuery),
    eq: vi.fn(() => profileQuery),
    order: vi.fn(() => profileQuery),
    upsert,
    maybeSingle: vi.fn(async () => ({ data: { avatar_path: ownPhoto }, error: null })),
  }
  const createSignedUrl = vi.fn(async (path: string) => ({ data: { signedUrl: `https://photos.example.test/${path}` }, error: null }))
  const upload = vi.fn(async () => ({ data: { path: 'uploaded' }, error: null }))
  const remove = vi.fn(async () => ({ data: [], error: null }))
  const supabase = {
    rpc,
    from: vi.fn(() => profileQuery),
    storage: { from: vi.fn(() => ({ createSignedUrl, upload, remove })) },
  } as unknown as Client
  return { supabase, createSignedUrl, upload, remove, upsert }
}

describe('Parcel Pals privacy and requests', () => {
  it('searches by six-digit code without exposing details before acceptance', async () => {
    const rpc = vi.fn(async (name: string) => {
      if (name === 'get_my_parcel_pal_code') return { data: '123456', error: null }
      if (name === 'list_parcel_pal_requests' || name === 'list_my_parcel_pals') return { data: [], error: null }
      if (name === 'search_parcel_pals') return { data: { found: true, code: '654321', status: 'none', direction: null }, error: null }
      if (name === 'send_parcel_pal_request') return { data: { status: 'pending' }, error: null }
      return { data: null, error: null }
    })
    const { supabase } = makeClient(rpc, 'user-1/photo.webp')
    const user = userEvent.setup()
    render(<ParcelPalsPanel supabase={supabase} userId="user-1" onError={vi.fn()} onNotice={vi.fn()} />)

    expect(await screen.findByText('123456')).toBeInTheDocument()
    const ownPhotoButton = screen.getByRole('button', { name: 'Change profile picture' })
    expect(ownPhotoButton.querySelector('img')).toHaveAttribute('src', 'https://photos.example.test/user-1/photo.webp')
    expect(ownPhotoButton.parentElement).toHaveClass('parcel-pal-own-code')
    expect(ownPhotoButton).toHaveClass('parcel-pal-avatar-own')
    expect(within(ownPhotoButton.parentElement!).getByText('YOUR PARCEL PAL NUMBER')).toBeInTheDocument()
    await user.type(screen.getByLabelText('Search by Parcel Pal number'), '654321')
    await user.click(screen.getByRole('button', { name: 'Search' }))
    expect(await screen.findByText('Parcel Pal number 654321 found')).toBeInTheDocument()
    expect(screen.queryByText('Protected Name')).not.toBeInTheDocument()
    expect(screen.queryByText('08012345678')).not.toBeInTheDocument()
    expect(screen.queryByText(/12 Private Road/)).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Send Parcel Pal request' }))
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('send_parcel_pal_request', { p_code: '654321' }))
    expect(await screen.findByText('Request sent. Waiting for them to accept.')).toBeInTheDocument()
    expect(screen.queryByText('Protected Name')).not.toBeInTheDocument()
    expect(screen.queryByText('08012345678')).not.toBeInTheDocument()
  })

  it('shows the incoming sender name and photo, but private contact details only after acceptance', async () => {
    let accepted = false
    const rpc = vi.fn(async (name: string) => {
      if (name === 'get_my_parcel_pal_code') return { data: '123456', error: null }
      if (name === 'list_parcel_pal_requests') return { data: accepted ? [] : [{ code: '654321', status: 'pending', direction: 'received', full_name: 'Protected Name', avatar_path: 'sender/avatar.png', created_at: '2026-10-14T10:00:00Z' }], error: null }
      if (name === 'list_my_parcel_pals') return { data: accepted ? [{ code: '654321', full_name: 'Protected Name', phone: '08012345678', avatar_path: 'sender/avatar.png', address: '12 Private Road', city: 'Lagos', state: 'Lagos', connected_at: '2026-10-14T10:01:00Z' }] : [], error: null }
      if (name === 'respond_to_parcel_pal_request') { accepted = true; return { data: 'accepted', error: null } }
      return { data: null, error: null }
    })
    const { supabase } = makeClient(rpc)
    const user = userEvent.setup()
    render(<ParcelPalsPanel supabase={supabase} userId="user-2" onError={vi.fn()} onNotice={vi.fn()} />)

    const senderName = await screen.findByText('Protected Name')
    expect(senderName).toBeInTheDocument()
    expect(senderName.closest('article')?.querySelector('.parcel-pal-avatar img')).toHaveAttribute('src', 'https://photos.example.test/sender/avatar.png')
    expect(screen.queryByText('08012345678')).not.toBeInTheDocument()
    expect(screen.queryByText(/12 Private Road/)).not.toBeInTheDocument()
    await user.click(within(senderName.closest('article')!).getByRole('button', { name: 'Accept' }))

    expect(await screen.findByText('Protected Name')).toBeInTheDocument()
    expect(screen.getByText('Phone:')).toHaveTextContent('08012345678')
    expect(screen.getByText(/Address:/)).toHaveTextContent('12 Private Road, Lagos, Lagos')
  })

  it('uploads and saves a profile picture from the Parcel Pal number card', async () => {
    const rpc = vi.fn(async (name: string) => {
      if (name === 'get_my_parcel_pal_code') return { data: '123456', error: null }
      if (name === 'list_parcel_pal_requests' || name === 'list_my_parcel_pals') return { data: [], error: null }
      if (name === 'set_my_parcel_pal_photo') return { data: 'user-1/123.jpg', error: null }
      return { data: null, error: null }
    })
    const { supabase, upload } = makeClient(rpc)
    const user = userEvent.setup()
    render(<ParcelPalsPanel supabase={supabase} userId="user-1" onError={vi.fn()} onNotice={vi.fn()} />)

    expect(await screen.findByRole('dialog', { name: 'Add a profile picture' })).toBeInTheDocument()
    const image = new File(['profile picture'], 'logo.png', { type: 'image/png' })
    await user.upload(screen.getByLabelText('Choose a profile picture'), image)

    await waitFor(() => expect(upload).toHaveBeenCalledWith(expect.stringMatching(/^user-1\//), image, expect.objectContaining({ contentType: 'image/png', upsert: false })))
    expect(rpc).toHaveBeenCalledWith('set_my_parcel_pal_photo', { p_path: expect.stringMatching(/^user-1\//) })
    expect(screen.getByRole('button', { name: 'Change profile picture' }).querySelector('img')).toHaveAttribute('src', expect.stringContaining('user-1/'))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  })

  it('offers an accepted Parcel Pal preferred destination for the delivery form', async () => {
    const rpc = vi.fn(async (name: string) => {
      if (name === 'get_my_parcel_pal_code') return { data: '123456', error: null }
      if (name === 'list_parcel_pal_requests') return { data: [], error: null }
      if (name === 'list_my_parcel_pals') return { data: [{ code: '654321', full_name: 'Ada Pal', phone: '08011112222', avatar_path: null, address: null, city: null, state: null, destinations: [{ slot: 2, label: 'Home', address: '4 Palm Street', city: 'Umuahia', state: 'Abia', secondary_phone: '08033334444' }] }], error: null }
      return { data: null, error: null }
    })
    const { supabase } = makeClient(rpc)
    const onUseDestination = vi.fn()
    render(<ParcelPalsPanel supabase={supabase} userId="user-1" onError={vi.fn()} onNotice={vi.fn()} onUseDestination={onUseDestination} />)
    const destination = await screen.findByText(/4 Palm Street/)
    expect(destination.closest('.parcel-pal-contact-destination')).toHaveTextContent('Umuahia')
    expect(destination.closest('.parcel-pal-contact-destination')).toHaveTextContent('08033334444')
    await userEvent.setup().click(within(destination.closest('.parcel-pal-contact-destination')!).getByRole('button', { name: 'Use this destination' }))
    expect(onUseDestination).toHaveBeenCalledWith(expect.objectContaining({ full_name: 'Ada Pal', phone: '08011112222' }), expect.objectContaining({ label: 'Home', city: 'Umuahia' }))
  })

  it('keeps saved address forms hidden until opened and fills them from the current Geoapify location', async () => {
    const rpc = vi.fn(async (name: string) => {
      if (name === 'get_my_parcel_pal_code') return { data: '123456', error: null }
      if (name === 'list_parcel_pal_requests' || name === 'list_my_parcel_pals') return { data: [], error: null }
      return { data: null, error: null }
    })
    const { supabase, upsert } = makeClient(rpc)
    vi.mocked(getAddressFromCurrentPosition).mockResolvedValueOnce({ address: '10 Palm Street', city: 'Umuahia', state: 'Abia', latitude: 5.5, longitude: 7.5, specificity: 'building', resultType: 'building', distanceMetres: 12, confidence: null, evidence: { latitude: 5.5, longitude: 7.5, accuracyMetres: 18, capturedAt: Date.now(), source: 'browser' }, qualityNote: 'Building suggestion; verify the house/building before saving. Device-reported accuracy: about 18 m.' })
    const user = userEvent.setup()
    const view = render(<ParcelPalsPanel supabase={supabase} userId="user-1" onError={vi.fn()} onNotice={vi.fn()} />)
    expect(screen.queryByRole('heading', { name: 'Your delivery locations' })).not.toBeInTheDocument()
    view.rerender(<ParcelPalsPanel supabase={supabase} userId="user-1" onError={vi.fn()} onNotice={vi.fn()} isEditingDestinations />)
    const workCard = screen.getByText('Work').closest('form')!
    await user.click(within(workCard).getByRole('button', { name: 'Get address' }))
    await waitFor(() => {
      expect(within(workCard).getByLabelText('Address')).toHaveValue('10 Palm Street')
      expect(within(workCard).getByLabelText('City')).toHaveValue('Umuahia')
      expect(within(workCard).getByLabelText('State')).toHaveValue('Abia')
    })
    expect(await within(workCard).findByRole('status')).toHaveTextContent('Address filled. Check before saving.')
    await user.click(within(workCard).getByRole('checkbox', { name: 'Address is correct.' }))
    await user.click(within(workCard).getByRole('button', { name: 'Save location' }))
    await waitFor(() => expect(upsert).toHaveBeenCalledWith({ user_id: 'user-1', slot: 1, label: 'Work', address: '10 Palm Street', city: 'Umuahia', state: 'Abia', secondary_phone: null,
      latitude: 5.5, longitude: 7.5, location_source: 'browser', location_accuracy_metres: 18 }, { onConflict: 'user_id,slot' }))
  })

  it('reminds again on the next app open while the profile still has no picture', async () => {
    const rpc = vi.fn(async (name: string) => {
      if (name === 'get_my_parcel_pal_code') return { data: '123456', error: null }
      if (name === 'list_parcel_pal_requests' || name === 'list_my_parcel_pals') return { data: [], error: null }
      return { data: null, error: null }
    })
    const { supabase } = makeClient(rpc)
    const user = userEvent.setup()
    const view = render(<ParcelPalsPanel supabase={supabase} userId="user-1" onError={vi.fn()} onNotice={vi.fn()} />)
    await user.click(await screen.findByRole('button', { name: "Don't remind me again" }))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    view.unmount()
    render(<ParcelPalsPanel supabase={supabase} userId="user-1" onError={vi.fn()} onNotice={vi.fn()} />)
    expect(await screen.findByRole('dialog', { name: 'Add a profile picture' })).toBeInTheDocument()
  })
})
