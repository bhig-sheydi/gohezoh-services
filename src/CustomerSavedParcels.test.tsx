import { describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { getSupabaseClient } from './lib/supabase'
import CustomerSavedParcels, { type SavedParcel } from './CustomerSavedParcels'
import { BIKE_BOX } from './lib/bike-item-space'

type Client = ReturnType<typeof getSupabaseClient>

function makeClient() {
  const saved: SavedParcel[] = []
  const inserts: Record<string, unknown>[] = []
  const upload = vi.fn(async () => ({ data: { path: 'user-1/photo.jpg' }, error: null }))
  const remove = vi.fn(async () => ({ data: [], error: null }))
  const createSignedUrl = vi.fn(async (path: string) => ({ data: { signedUrl: `https://saved.example.test/${path}` }, error: null }))
  const supabase = {
    from: vi.fn((table: string) => {
      let inserted: Record<string, unknown> | null = null
      const query: Record<string, unknown> = {}
      for (const method of ['select','eq','order']) query[method] = vi.fn(() => query)
      query.insert = vi.fn((data: Record<string, unknown>) => { inserted = data; inserts.push(data); return query })
      query.delete = vi.fn(() => query)
      query.then = (resolve: (value: unknown) => unknown) => {
        if (inserted) {
          saved.push({ id: 'saved-1', created_at: '2026-10-14T10:00:00Z', ...inserted } as SavedParcel)
          resolve({ data: null, error: null })
        } else resolve({ data: table === 'bike_item_catalogue' ? [{ code: 'textbook', category: 'Documents', label: 'Textbook', length_cm: 29, width_cm: 23, height_cm: 6, estimated_weight_kg: 1.2, measurement: 'unit' }] : saved, error: null })
      }
      return query
    }),
    storage: { from: vi.fn(() => ({ upload, remove, createSignedUrl })) },
  } as unknown as Client
  return { supabase, inserts, upload, remove, createSignedUrl }
}

describe('customer saved parcel templates', () => {
  it('uses a conservative bike box estimate', () => {
    expect(BIKE_BOX).toEqual({ lengthCm: 38, widthCm: 32, heightCm: 32, volumeCm3: 38912, safetyKg: 25 })
  })

  it('saves a photo and full item details, then lets the customer reuse the item', async () => {
    const { supabase, inserts, upload } = makeClient()
    const onUse = vi.fn()
    const user = userEvent.setup()
    render(<CustomerSavedParcels supabase={supabase} userId="user-1" onError={vi.fn()} onNotice={vi.fn()} onUse={onUse} />)

    await user.click(await screen.findByText('Add items to send'))
    await user.upload(screen.getByLabelText('Parcel photo'), new File(['photo'], 'item.jpg', { type: 'image/jpeg' }))
    await user.type(screen.getByLabelText('Item name'), 'Books')
    await user.type(screen.getByLabelText('Parcel description'), 'Two textbooks')
    await user.type(screen.getByLabelText('Declared worth (₦)'), '25000')
    await user.type(screen.getByLabelText('Price paid (₦)'), '18000')
    await screen.findByRole('option', { name: 'Textbook · Documents' })
    await user.selectOptions(screen.getByLabelText('Item type'), 'textbook')
    await user.click(screen.getByRole('button', { name: 'Save item' }))

    await waitFor(() => expect(upload).toHaveBeenCalled())
    await waitFor(() => expect(inserts).toContainEqual(expect.objectContaining({ item_name: 'Books', declared_value: 25000, price: 18000, catalog_code: 'textbook', length_cm: 29, width_cm: 23, height_cm: 6, weight_kg: 1.2 })))
    await user.click(await screen.findByRole('button', { name: 'Use item' }))
    expect(onUse).toHaveBeenCalledWith(expect.objectContaining({ item_name: 'Books', photo_url: expect.stringContaining('user-1/') }))
  })
})
