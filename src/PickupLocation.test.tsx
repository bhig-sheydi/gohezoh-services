import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import type { SupabaseClient } from '@supabase/supabase-js'
import PickupLocation from './PickupLocation'

describe('pickup location selection', () => {
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
