import { describe, expect, it, vi } from 'vitest'
import { sendDeliveryCode } from './delivery-sms'

describe('delivery SMS adapter', () => {
  it('sends a delivery code through Messaging.ng transactional SMS', async () => {
    const fetcher = vi.fn(async (_input: RequestInfo | URL, _init?: RequestInit) => new Response('{"accepted":[{"id":"msg-1"}],"failures":[]}', { status: 200 }))
    await expect(sendDeliveryCode({ provider: 'messaging_ng', messagingNgPublicKey: 'public', messagingNgSecretKey: 'secret', messagingNgSenderId: 'KWIKPARSEL' }, '08012345678', 'JOB-3', '004219', fetcher)).resolves.toBeUndefined()
    const [url, init] = fetcher.mock.calls[0]
    expect(String(url)).toBe('https://messaging.ng/api/v1/messages/send')
    expect(init?.headers).toMatchObject({ 'X-Public-Key': 'public', authorization: 'Bearer secret' })
    expect(JSON.parse(String(init?.body))).toMatchObject({ recipients: ['2348012345678'], sender_id: 'KWIKPARSEL', channel: 'sms', route: 'transactional' })
  })

  it('rejects a Messaging.ng response that reports no accepted message', async () => {
    const fetcher = vi.fn(async () => new Response('{"accepted":[],"failures":[{"reason":"sender ID pending"}]}', { status: 200 }))
    await expect(sendDeliveryCode({ provider: 'messaging_ng', messagingNgPublicKey: 'public', messagingNgSecretKey: 'secret', messagingNgSenderId: 'KWIKPARSEL' }, '08012345678', 'JOB-3', '004219', fetcher)).rejects.toThrow('did not accept')
  })

  it('formats Termii recipient numbers without exposing the code from its function result', async () => {
    const fetcher = vi.fn(async (_input: RequestInfo | URL, _init?: RequestInit) => new Response('{"code":"ok"}', { status: 200 }))
    await expect(sendDeliveryCode({ provider: 'termii', termiiApiKey: 'secret', termiiSenderId: 'Gohezoh' }, '08012345678', 'JOB-3', '004219', fetcher)).resolves.toBeUndefined()
    const request = JSON.parse(String(fetcher.mock.calls[0][1]?.body)) as { to: string; sms: string; api_key: string }
    expect(String(fetcher.mock.calls[0][0])).toBe('https://api.ng.termii.com/api/sms/send')
    expect(request.to).toBe('2348012345678')
    expect(request.sms).toContain('004219')
    expect(request.api_key).toBe('secret')
  })

  it('rejects provider failures and missing credentials', async () => {
    const failingFetch = vi.fn(async () => new Response('no', { status: 503 }))
    await expect(sendDeliveryCode({ provider: 'termii', termiiApiKey: 'secret', termiiSenderId: 'Gohezoh' }, '+2348012345678', 'JOB-4', '123456', failingFetch)).rejects.toThrow('503')
    await expect(sendDeliveryCode({ provider: 'twilio' }, '+2348012345678', 'JOB-4', '123456')).rejects.toThrow('not configured')
  })

  it('treats a Termii application-level rejection as a send failure', async () => {
    const acceptedHttpButRejectedMessage = vi.fn(async () => new Response('{"code":"error"}', { status: 200 }))
    await expect(sendDeliveryCode({ provider: 'termii', termiiApiKey: 'secret', termiiSenderId: 'Gohezoh' }, '08012345678', 'JOB-4', '123456', acceptedHttpButRejectedMessage)).rejects.toThrow('did not accept')
  })

  it('uses the transactional Termii route for delivery verification codes', async () => {
    const fetcher = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      expect(JSON.parse(String(init?.body))).toMatchObject({ channel: 'dnd', type: 'plain' })
      return new Response('{"code":"ok"}', { status: 200 })
    })
    await sendDeliveryCode({ provider: 'termii', termiiApiKey: 'secret', termiiSenderId: 'Gohezoh' }, '08012345678', 'JOB-5', '123456', fetcher)
  })

  it('converts Nigerian local numbers to E.164 for Twilio', async () => {
    const fetcher = vi.fn(async (_input: RequestInfo | URL, _init?: RequestInit) => new Response('{}', { status: 201 }))
    await sendDeliveryCode({ provider: 'twilio', twilioAccountSid: 'AC123', twilioAuthToken: 'secret', twilioFrom: '+15005550006' }, '08012345678', 'JOB-6', '123456', fetcher)
    expect(new URLSearchParams(String(fetcher.mock.calls[0][1]?.body)).get('To')).toBe('+2348012345678')
  })
})
