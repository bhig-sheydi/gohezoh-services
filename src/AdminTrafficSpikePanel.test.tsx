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
    if (name === 'admin_traffic_spike_snapshot_page') return { data: value, error: null }
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

  it('shows one server page of alerts and requests the next page', async () => {
    const first = { ...snapshot, alerts_total: 9, active_alerts_total: 1, alerts_page: 1 }
    const rpc = vi.fn(async (name: string, args?: { p_page?: number }) => {
      if (name === 'admin_traffic_spike_snapshot_page') return { data: args?.p_page === 2
        ? { ...first, alerts_page: 2, alerts: [{ ...alert, id: 'second', cause: 'Second page cause' }] }
        : first, error: null }
      return { data: null, error: null }
    })
    render(<AdminTrafficSpikePanel supabase={{ rpc } as unknown as SupabaseClient} />)
    expect(await screen.findByText('Page 1 of 2')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Next' }))
    expect(await screen.findByText('Second page cause')).toBeInTheDocument()
    expect(rpc).toHaveBeenCalledWith('admin_traffic_spike_snapshot_page', { p_page: 2, p_page_size: 8 })
  })

  it('rings only after the admin enables browser audio for an active spike', async () => {
    const start = vi.fn()
    const source = vi.fn(() => ({ buffer: null, connect: vi.fn(), start }))
    const fetchSound = vi.fn(async () => ({ ok: true, arrayBuffer: async () => new ArrayBuffer(8) }))
    vi.stubGlobal('fetch', fetchSound)
    class FakeAudioContext {
      state = 'running'
      destination = {}
      createBufferSource = source
      decodeAudioData = async () => ({} as AudioBuffer)
      resume = async () => undefined
      close = async () => undefined
    }
    vi.stubGlobal('AudioContext', FakeAudioContext)
    const { supabase } = client()
    render(<AdminTrafficSpikePanel supabase={supabase} />)
    await screen.findByText('1 spike need attention')
    expect(start).not.toHaveBeenCalled()
    await userEvent.click(screen.getByRole('button', { name: 'Enable alarm' }))
    await waitFor(() => expect(start).toHaveBeenCalledTimes(1))
    expect(fetchSound).toHaveBeenCalledWith('/sounds/admin_alarm.wav', { cache: 'force-cache' })
  })

  it('registers only a super-admin Android phone after notifications were enabled', async () => {
    const postMessage = vi.fn()
    window.KwikParselNative = { postMessage }
    window.localStorage.setItem('kwik-parsel-admin-alarm-enabled', '1')
    const { supabase, rpc } = client()
    render(<AdminTrafficSpikePanel supabase={supabase} />)
    await waitFor(() => expect(postMessage).toHaveBeenCalledWith('{"type":"admin:poll-status"}'))
    window.dispatchEvent(new CustomEvent('kwik-parsel:admin-push', { detail: {
      type: 'admin:poll-state', status: 'credentials',
      deviceId: '62947c6b-6317-46bb-bb6a-98e189a87a37', deviceSecret: 'a'.repeat(43),
      message: 'Phone notifications are ready.', lastPollAttemptAt: 0, lastServerCheckAt: 0,
    } }))
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('admin_register_alarm_device', {
      p_device_id: '62947c6b-6317-46bb-bb6a-98e189a87a37',
      p_secret: 'a'.repeat(43),
    }))
    expect(postMessage).toHaveBeenCalledWith('{"type":"admin:poll-registered"}')
    window.dispatchEvent(new CustomEvent('kwik-parsel:admin-push', { detail: {
      type: 'admin:poll-state', status: 'enabled', message: 'Ready',
      deviceId: '62947c6b-6317-46bb-bb6a-98e189a87a37', fcmToken: 'f'.repeat(64),
    } }))
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('admin_register_spike_push_device', {
      p_device_id: '62947c6b-6317-46bb-bb6a-98e189a87a37', p_token: 'f'.repeat(64),
    }))
    expect(await screen.findByText(/Remote push is awaiting server setup/)).toBeInTheDocument()
    expect(screen.getByText('Last server check: Never')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Test phone alarm' }))
    expect(postMessage).toHaveBeenCalledWith('{"type":"admin:test-notification"}')
    await userEvent.click(screen.getByRole('button', { name: 'Sound settings' }))
    expect(postMessage).toHaveBeenCalledWith('{"type":"admin:open-notification-settings"}')
  })

  it('stops phone polling immediately when alerts are disabled, even if unregister is slow', async () => {
    const postMessage = vi.fn()
    window.KwikParselNative = { postMessage }
    window.localStorage.setItem('kwik-parsel-admin-alarm-enabled', '1')
    window.localStorage.setItem('kwik-parsel-admin-alarm-device-id', '62947c6b-6317-46bb-bb6a-98e189a87a37')
    let completeUnregister: ((value: { data: null; error: null }) => void) | undefined
    const rpc = vi.fn((name: string) => name === 'admin_unregister_alarm_device'
      ? new Promise<{ data: null; error: null }>((resolve) => { completeUnregister = resolve })
      : Promise.resolve({ data: name === 'admin_traffic_spike_snapshot_page' ? snapshot : null, error: null }))
    render(<AdminTrafficSpikePanel supabase={{ rpc } as unknown as SupabaseClient} />)
    await waitFor(() => expect(postMessage).toHaveBeenCalledWith('{"type":"admin:poll-status"}'))
    window.dispatchEvent(new CustomEvent('kwik-parsel:admin-push', { detail: {
      type: 'admin:poll-state', status: 'enabled', message: 'Ready',
    } }))
    await userEvent.click(await screen.findByRole('button', { name: 'Disable phone alerts' }))
    expect(postMessage).toHaveBeenCalledWith('{"type":"admin:disable-poll"}')
    expect(window.localStorage.getItem('kwik-parsel-admin-alarm-enabled')).toBe('0')
    completeUnregister?.({ data: null, error: null })
  })
})
