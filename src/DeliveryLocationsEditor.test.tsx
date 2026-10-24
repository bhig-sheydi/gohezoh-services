import { describe, expect, it, vi } from 'vitest'
import { act, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { SupabaseClient } from '@supabase/supabase-js'
import DeliveryLocationsEditor from './DeliveryLocationsEditor'
import { getAddressFromCurrentPosition, suggestAddresses, type AddressSuggestion } from './lib/geoapify-geocoding'

vi.mock('./lib/geoapify-geocoding', () => ({ getAddressFromCurrentPosition: vi.fn(), suggestAddresses: vi.fn() }))
const result: AddressSuggestion = { address: '10 Palm Street', city: 'Umuahia', state: 'Abia', latitude: 5.5, longitude: 7.5, specificity: 'building', resultType: 'building', confidence: null, distanceMetres: 10, evidence: { latitude: 5.5, longitude: 7.5, accuracyMetres: 12, capturedAt: Date.now(), source: 'browser' }, qualityNote: 'Building-level suggestion; check the building and street.' }
function setup() {
  const upsert = vi.fn(() => ({ abortSignal: vi.fn(async () => ({ error: null })) }))
  const supabase = { from: vi.fn(() => ({ upsert })) } as unknown as SupabaseClient
  const props = { supabase, userId: 'user-1', destinations: [], onSaved: vi.fn(async () => {}), onError: vi.fn(), onNotice: vi.fn(), onClose: vi.fn() }
  return { props, upsert }
}

describe('delivery location editor', () => {
  it('searches a free-form place name without a city or minimum address shape', async () => {
    vi.mocked(suggestAddresses).mockResolvedValueOnce([result])
    const { props } = setup()
    render(<DeliveryLocationsEditor {...props} />)
    const card = screen.getByText('Work').closest('form')!
    const user = userEvent.setup()
    await user.type(within(card).getByLabelText('Address'), 'HQ')
    await user.click(within(card).getByRole('button', { name: 'Find options' }))
    await waitFor(() => expect(suggestAddresses).toHaveBeenCalledWith(expect.anything(), 'HQ, Nigeria', expect.anything()))
    expect(await within(card).findByRole('group', { name: /address suggestions/ })).toHaveTextContent('10 Palm Street')
  })
  it('fills area-only results, allows corrections and offers no map', async () => {
    vi.mocked(getAddressFromCurrentPosition).mockResolvedValueOnce({ ...result, address: 'Ibeku', specificity: 'area', evidence: { ...result.evidence, accuracyMetres: 500 } })
    const { props, upsert } = setup()
    render(<DeliveryLocationsEditor {...props} />)
    const card = screen.getByText('Work').closest('form')!
    const user = userEvent.setup()
    expect(screen.queryByRole('button', { name: /map/i })).not.toBeInTheDocument()
    await user.click(within(card).getByRole('button', { name: 'Get address' }))
    expect(within(card).getByLabelText('Address')).toHaveValue('Ibeku')
    expect(within(card).getByLabelText('City')).toHaveValue('Umuahia')
    expect(within(card).getByLabelText('State')).toHaveValue('Abia')
    expect(within(card).getByRole('status')).toHaveTextContent('The map found only an area, not your building or street. Phone accuracy ±500 m.')
    await user.clear(within(card).getByLabelText('Address'))
    await user.type(within(card).getByLabelText('Address'), '12 Palm Street')
    expect(within(card).queryByRole('checkbox')).not.toBeInTheDocument()
    await user.click(within(card).getByRole('button', { name: 'Save location' }))
    expect(upsert).toHaveBeenCalledWith(expect.objectContaining({ address: '12 Palm Street', latitude: null, longitude: null }), expect.anything())
  })
  it('keeps manual entry usable after permission denial and saves no location metadata', async () => {
    vi.mocked(getAddressFromCurrentPosition).mockRejectedValueOnce(new Error('Location permission was denied.'))
    const { props, upsert } = setup()
    render(<DeliveryLocationsEditor {...props} />)
    expect(getAddressFromCurrentPosition).not.toHaveBeenCalled()
    const card = screen.getByText('Work').closest('form')!
    const user = userEvent.setup()
    await user.type(within(card).getByLabelText('Address'), '20 Market Road')
    await user.type(within(card).getByLabelText('City'), 'Umuahia')
    await user.type(within(card).getByLabelText('State'), 'Abia')
    await user.click(within(card).getByRole('button', { name: 'Get address' }))
    expect(await within(card).findByRole('alert')).toHaveTextContent('permission was denied')
    expect(within(card).getByLabelText('Address')).toHaveValue('20 Market Road')
    await user.click(within(card).getByRole('button', { name: 'Save location' }))
    await waitFor(() => expect(upsert).toHaveBeenCalledWith({ user_id: 'user-1', slot: 1, label: 'Work', address: '20 Market Road', city: 'Umuahia', state: 'Abia', secondary_phone: null,
      latitude: null, longitude: null, location_source: null, location_accuracy_metres: null }, { onConflict: 'user_id,slot' }))
  })
  it('deduplicates clicks and prevents input edits while a result is pending', async () => {
    let resolve!: (value: AddressSuggestion) => void
    vi.mocked(getAddressFromCurrentPosition).mockReturnValueOnce(new Promise((done) => { resolve = done }))
    const { props } = setup()
    render(<DeliveryLocationsEditor {...props} />)
    const card = screen.getByText('Work').closest('form')!
    const user = userEvent.setup()
    await user.dblClick(within(card).getByRole('button', { name: 'Get address' }))
    expect(getAddressFromCurrentPosition).toHaveBeenCalledTimes(1)
    expect(within(card).getByLabelText('Address')).toBeDisabled()
    expect(within(card).getByRole('button', { name: 'Save location' })).toHaveTextContent('Save location')
    await act(async () => resolve(result))
    expect(within(card).getByLabelText('Address')).toHaveValue('10 Palm Street')
    expect(within(card).getByRole('checkbox')).toBeRequired()
  })
  it('aborts a lookup on editor closure and ignores a late result after reopening', async () => {
    let resolve!: (value: AddressSuggestion) => void
    vi.mocked(getAddressFromCurrentPosition).mockReturnValueOnce(new Promise((done) => { resolve = done }))
    const { props } = setup()
    const view = render(<DeliveryLocationsEditor {...props} />)
    await userEvent.setup().click(screen.getAllByRole('button', { name: 'Get address' })[0])
    const signal = vi.mocked(getAddressFromCurrentPosition).mock.calls[0][1]!.signal!
    view.unmount()
    expect(signal.aborted).toBe(true)
    render(<DeliveryLocationsEditor {...props} />)
    await act(async () => resolve(result))
    expect(screen.getAllByLabelText('Address')[0]).toHaveValue('')
    expect(screen.queryByText('Building-level suggestion; check the building and street.')).not.toBeInTheDocument()
  })
})
