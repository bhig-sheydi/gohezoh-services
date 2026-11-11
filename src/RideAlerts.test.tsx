import { afterEach, expect, it, vi } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import RideAlerts from './RideAlerts'

afterEach(() => { delete window.KwikParselNative; vi.clearAllMocks() })

it('registers an opted-in Android phone for the signed-in rider', async () => {
  const postMessage = vi.fn()
  window.KwikParselNative = { postMessage }
  const rpc = vi.fn().mockResolvedValue({ error: null })
  render(<RideAlerts supabase={{ rpc } as never} userId="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" kind="rider" />)
  expect(postMessage).toHaveBeenCalledWith('{"type":"ride:status"}')
  expect(screen.getByText('Hear new assignments in time to accept them.')).toBeTruthy()
  fireEvent.click(screen.getByRole('button', { name: 'Allow phone ride alarms' }))
  expect(postMessage).toHaveBeenCalledWith('{"type":"ride:register"}')
  window.dispatchEvent(new CustomEvent('kwik-parsel:ride-push', { detail: {
    type: 'ride:token', deviceId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', fcmToken: 'c'.repeat(100),
  } }))
  await waitFor(() => expect(rpc).toHaveBeenCalledWith('register_ride_push_device', {
    p_device_id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', p_token: 'c'.repeat(100), p_kind: 'rider',
  }))
  await waitFor(() => expect(postMessage).toHaveBeenCalledWith(JSON.stringify({
    type: 'ride:registered', userId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  })))
})

it.each([
  ['customer', 'Hear when a rider is available for your delivery.'],
  ['company', 'Hear new delivery offers before they expire.'],
] as const)('prompts %s to enable alerts', (kind, copy) => {
  window.KwikParselNative = { postMessage: vi.fn() }
  render(<RideAlerts supabase={{ rpc: vi.fn() } as never} userId="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" kind={kind} />)
  expect(screen.getByText(copy)).toBeTruthy()
})

it('opens Android notification settings when alerts are disabled', async () => {
  const postMessage = vi.fn()
  window.KwikParselNative = { postMessage }
  render(<RideAlerts supabase={{ rpc: vi.fn() } as never} userId="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" kind="rider" />)
  window.dispatchEvent(new CustomEvent('kwik-parsel:ride-push', { detail: {
    type: 'ride:status', available: false, audible: false,
  } }))
  fireEvent.click(await screen.findByRole('button', { name: 'Open notification settings' }))
  expect(postMessage).toHaveBeenCalledWith('{"type":"ride:settings"}')
})

it('does not register a malformed phone token event', () => {
  const postMessage = vi.fn()
  window.KwikParselNative = { postMessage }
  const rpc = vi.fn()
  render(<RideAlerts supabase={{ rpc } as never} userId="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" kind="company" />)
  window.dispatchEvent(new CustomEvent('kwik-parsel:ride-push', { detail: {
    type: 'ride:token', deviceId: 'not-a-uuid', fcmToken: 'c'.repeat(100),
  } }))
  expect(rpc).not.toHaveBeenCalled()
})
