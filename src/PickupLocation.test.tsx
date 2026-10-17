import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import type { SupabaseClient } from '@supabase/supabase-js'
import PickupLocation from './PickupLocation'

describe('pickup location selection', () => {
  it('suggests communities and streets as the customer types and keeps the selected street', async () => {
    const query = { select: () => query, eq: () => query, order: async () => ({ data: [], error: null }) }
    const community = { address: 'Eliozu', city: 'Port Harcourt', state: 'Rivers', latitude: 4.83, longitude: 7.02, placeId: '51f07665660fc4024059dc0a96dfac6c',
      specificity: 'area', resultType: 'suburb', distanceMetres: null, confidence: 0.9 }
    const street = { ...community, address: 'Orji Woko Close', latitude: 4.831, longitude: 7.021, specificity: 'street', resultType: 'street' }
    const invoke = vi.fn(async (_name: string, options: { body: { action: string; text?: string } }) => ({
      data: { suggestions: [options.body.text?.startsWith('Eliozu') ? community : street] }, error: null,
    }))
    const supabase = { from: () => query, functions: { invoke } } as unknown as SupabaseClient
    render(<form><select name="pickup_city" defaultValue="Port Harcourt"><option>Port Harcourt</option></select>
      <input name="pickup_community" aria-label="Pickup community" /><input name="pickup_address" aria-label="Pickup street" />
      <PickupLocation supabase={supabase} userId="user-1" onCitySelected={vi.fn()} /></form>)
    const user = userEvent.setup()
    await user.type(screen.getByLabelText('Pickup community'), 'Eliozu')
    await user.click(await screen.findByRole('button', { name: /Eliozu/ }))
    expect(screen.getByLabelText('Pickup community')).toHaveValue('Eliozu')
    await user.type(screen.getByLabelText('Pickup street'), 'Orji')
    await user.click(await screen.findByRole('button', { name: /Orji Woko Close/ }))
    expect(screen.getByLabelText('Pickup street')).toHaveValue('Orji Woko Close')
    expect(document.querySelector('[name=pickup_latitude]')).toHaveValue('4.831')
    expect(screen.getByRole('button', { name: 'Adjust pin' })).toBeInTheDocument()
    await waitFor(() => expect(invoke).toHaveBeenCalledWith('location-address', expect.objectContaining({ body: { action: 'suggest', text: 'Orji', placeId: community.placeId } })))
  })
  it('uses saved coordinates and removes them when the address is edited', async () => {
    const saved = [{ slot: 1, label: 'Work', address: '12 Market Road', city: 'Lagos', state: 'Lagos',
      latitude: 6.45, longitude: 3.4, location_source: 'browser', location_accuracy_metres: 18 }]
    const query = { select: () => query, eq: () => query, order: async () => ({ data: saved, error: null }) }
    const supabase = { from: () => query } as unknown as SupabaseClient
    const onCitySelected = vi.fn()
    render(<form><input name="pickup_address" aria-label="Pickup address" /><PickupLocation supabase={supabase} userId="user-1" onCitySelected={onCitySelected} /></form>)
    const user = userEvent.setup()
    await user.selectOptions(await screen.findByLabelText('My pickup addresses'), '1')
    expect(screen.getByLabelText('Pickup address')).toHaveValue('12 Market Road')
    expect(onCitySelected).toHaveBeenCalledWith('Lagos')
    expect(screen.getByText(/saved location/)).toBeInTheDocument()
    expect((document.querySelector('[name=pickup_latitude]') as HTMLInputElement).value).toBe('6.45')
    await user.clear(screen.getByLabelText('Pickup address'))
    await user.type(screen.getByLabelText('Pickup address'), 'Other street')
    expect(document.querySelector('[name=pickup_latitude]')).toBeNull()
  })
})
