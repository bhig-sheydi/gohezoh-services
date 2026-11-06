import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { SupabaseClient } from '@supabase/supabase-js'
import AdminTrafficSpikePanel from './AdminTrafficSpikePanel'

const alert = {
  id: '459f0c5c-b28a-4a1e-86b6-f55f7c89163f', severity: 'critical', source: 'route_queue',
  cause: 'Route planning events are overdue.', observed: 28, baseline: 0, threshold: 25,
  detected_at: '2026-11-06T06:00:00Z', resolved_at: null, acknowledged_at: null,
}
const snapshot = {
  checked_at: new Date().toISOString(), window_minutes: 1,
  metrics: [{ key: 'route_queue', label: 'Overdue route jobs', current: 28,
    baseline: 0, unit: 'jobs', status: 'critical' }], alerts: [alert],
}

function client(value: unknown = snapshot) {
  const rpc = vi.fn(async (name: string) => {
    if (name === 'admin_traffic_spike_snapshot') return { data: value, error: null }
    if (name === 'admin_spike_push_configuration') return { data: { enabled: true }, error: null }
    return { data: null, error: null }
  })
  return { supabase: { rpc } as unknown as SupabaseClient, rpc }
}

describe('super-admin traffic monitor', () => {
  beforeEach(() => { window.localStorage.clear() })
  afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); delete window.KwikParselNative })

  it('shows the source, likely cause and visual alarm; acknowledgement silences this admin', async () => {
    const { supabase, rpc } = client()
    render(<AdminTrafficSpikePanel supabase={supabase} />)
    expect(await screen.findByText('1 spike need attention')).toBeInTheDocument()
    expect(screen.getByText('Route planning events are overdue.')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Acknowledge' }))
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('admin_acknowledge_traffic_spike',
      { p_alert_id: alert.id }))
    expect(screen.getByText('No active spikes detected')).toBeInTheDocument()
  })

  it('does not sound an incident that has already resolved', async () => {
    const { supabase } = client({ ...snapshot, alerts: [{ ...alert, resolved_at: '2026-11-06T06:01:00Z' }] })
    render(<AdminTrafficSpikePanel supabase={supabase} />)
    expect(await screen.findByText('No active spikes detected')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Acknowledge' })).not.toBeInTheDocument()
  })

  it('rings only after the admin enables browser audio for an active spike', async () => {
    const oscillator = vi.fn(() => ({ type: 'sine', frequency: { value: 0 },
      connect: vi.fn(), start: vi.fn(), stop: vi.fn() }))
    class FakeAudioContext {
      state = 'running'
      currentTime = 0
      destination = {}
      createOscillator = oscillator
      createGain = () => ({ gain: { setValueAtTime: vi.fn(),
        exponentialRampToValueAtTime: vi.fn() }, connect: vi.fn() })
      resume = async () => undefined
      close = async () => undefined
    }
    vi.stubGlobal('AudioContext', FakeAudioContext)
    const { supabase } = client()
    render(<AdminTrafficSpikePanel supabase={supabase} />)
    await screen.findByText('1 spike need attention')
    expect(oscillator).not.toHaveBeenCalled()
    await userEvent.click(screen.getByRole('button', { name: 'Enable alarm' }))
    await waitFor(() => expect(oscillator).toHaveBeenCalledTimes(2))
  })

  it('registers only a super-admin Android phone after notifications were enabled', async () => {
    const postMessage = vi.fn()
    window.KwikParselNative = { postMessage }
    window.localStorage.setItem('kwik-parsel-admin-push-enabled', '1')
    window.localStorage.setItem('kwik-parsel-admin-push-device-id', '62947c6b-6317-46bb-bb6a-98e189a87a37')
    const { supabase, rpc } = client()
    render(<AdminTrafficSpikePanel supabase={supabase} />)
    await waitFor(() => expect(postMessage).toHaveBeenCalledWith('{"type":"admin:push-status"}'))
    window.dispatchEvent(new CustomEvent('kwik-parsel:admin-push', { detail: {
      type: 'admin:push-state', status: 'token', token: 'phone-token-123456789012345678901234567890',
      message: 'Phone notifications are ready.',
    } }))
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('admin_register_spike_push_device', {
      p_device_id: '62947c6b-6317-46bb-bb6a-98e189a87a37',
      p_token: 'phone-token-123456789012345678901234567890',
    }))
    expect(await screen.findByText(/Enabled on this phone/)).toBeInTheDocument()
  })
})
