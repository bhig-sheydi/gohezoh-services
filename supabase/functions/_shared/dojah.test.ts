import { describe, expect, it } from 'vitest'
import { webcrypto } from 'node:crypto'
import { assessDojahRiderEvent, verifyDojahSignature } from './dojah'

const valid = { reference_id: 'KWP-RIDER-12345678-1234-1234-1234-123456789abc', widget_id: 'rider-flow',
  id_type: 'NIN', value: '12345678901', status: true, verification_status: 'Completed',
  data: { government_data: { status: true }, selfie: { status: true }, address: { status: true } } }
describe('Dojah rider verification', () => {
  it('requires NIN, selfie and address to pass', () => {
    expect(assessDojahRiderEvent(valid, 'rider-flow')).toBe('passed')
    expect(assessDojahRiderEvent({ ...valid, data: { ...valid.data, address: { status: false } } }, 'rider-flow')).toBe('failed')
    expect(assessDojahRiderEvent({ ...valid, id_type: 'BVN' }, 'rider-flow')).toBe('failed')
    expect(assessDojahRiderEvent({ ...valid, verification_status: 'Pending' }, 'rider-flow')).toBe('pending')
    expect(assessDojahRiderEvent(valid, 'other-flow')).toBe('failed')
  })
  it('rejects unsigned and altered payloads', async () => {
    const key = await webcrypto.subtle.importKey('raw', new TextEncoder().encode('test-secret'), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
    const sig = Array.from(new Uint8Array(await webcrypto.subtle.sign('HMAC', key, new TextEncoder().encode('{}'))),
      byte => byte.toString(16).padStart(2, '0')).join('')
    const oldCrypto = globalThis.crypto
    Object.defineProperty(globalThis, 'crypto', { value: webcrypto, configurable: true })
    try {
    expect(await verifyDojahSignature('{}', sig, 'test-secret')).toBe(true)
    expect(await verifyDojahSignature('{ }', sig, 'test-secret')).toBe(false)
    expect(await verifyDojahSignature('{}', '', 'test-secret')).toBe(false)
    } finally { Object.defineProperty(globalThis, 'crypto', { value: oldCrypto, configurable: true }) }
  })
})
