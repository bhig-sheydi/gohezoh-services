// @vitest-environment node
import { describe, expect, it, vi } from 'vitest'
import { firebaseAccessToken, fcmSpikeMessage, parseFirebaseServiceAccount,
  sendFcmSpike, type SpikeDelivery } from './fcm-spike'

const delivery: SpikeDelivery = {
  delivery_id: '15bd1bd6-a0a2-4b5e-918c-291942423325',
  alert_id: '459f0c5c-b28a-4a1e-86b6-f55f7c89163f',
  device_token: 'phone-token-123456789012345678901234567890',
  severity: 'critical',
  source: 'route_queue',
  cause: 'Route planning events are overdue.',
}

describe('admin spike FCM messages', () => {
  it('puts a short, high-priority alarm on the dedicated Android channel', () => {
    expect(fcmSpikeMessage(delivery)).toMatchObject({ message: {
      token: delivery.device_token,
      notification: { title: 'Critical Kwik-Parsel spike' },
      data: { alert_id: delivery.alert_id },
      android: { priority: 'HIGH', notification: { channel_id: 'admin_spike_alarm_v1' } },
    } })
  })

  it('rejects malformed server credentials before making requests', () => {
    expect(() => parseFirebaseServiceAccount('{}')).toThrow('invalid')
  })

  it('mints a scoped OAuth token using the service account', async () => {
    const keys = await crypto.subtle.generateKey({ name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['sign', 'verify'])
    const der = new Uint8Array(await crypto.subtle.exportKey('pkcs8', keys.privateKey))
    const pem = `-----BEGIN PRIVATE KEY-----\n${Buffer.from(der).toString('base64')}\n-----END PRIVATE KEY-----`
    const account = parseFirebaseServiceAccount(JSON.stringify({
      project_id: 'kwik-parsel-test', client_email: 'service@kwik-parsel-test.iam.gserviceaccount.com',
      private_key: pem,
    }))
    const request = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
      const body = init?.body as URLSearchParams
      expect(body.get('grant_type')).toBe('urn:ietf:params:oauth:grant-type:jwt-bearer')
      const payload = JSON.parse(Buffer.from(body.get('assertion')!.split('.')[1], 'base64url').toString())
      expect(payload.scope).toBe('https://www.googleapis.com/auth/firebase.messaging')
      return Response.json({ access_token: 'short-lived-token', expires_in: 3600 })
    }) as typeof fetch
    const result = await firebaseAccessToken(account, request, () => 1_000_000)
    expect(result.token).toBe('short-lived-token')
    expect(request).toHaveBeenCalledOnce()
  })

  it('classifies invalid device tokens without exposing the token in the error', async () => {
    const request = vi.fn(async () => Response.json({ error: { status: 'NOT_FOUND',
      details: [{ errorCode: 'UNREGISTERED' }] } }, { status: 404 })) as typeof fetch
    const result = await sendFcmSpike({ project_id: 'kwik-parsel-test',
      client_email: 'service@kwik-parsel-test.iam.gserviceaccount.com', private_key: 'unused' },
    'access', delivery, request)
    expect(result).toEqual({ sent: false, code: 'UNREGISTERED', invalidToken: true })
    expect(String(result.code)).not.toContain(delivery.device_token)
  })
})
