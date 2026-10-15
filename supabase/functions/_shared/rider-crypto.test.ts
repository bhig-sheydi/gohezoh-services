import { webcrypto } from 'node:crypto'
import { describe, expect, it, vi } from 'vitest'
import { createPassword, hashPassword, hex, hmac, sha256, validPublicKey, verifyDeviceSignature } from './rider-crypto'

describe('rider credentials and phone proof', () => {
  it('generates distinct passwords and verifies salted hashes without exposing the internal account password', async () => {
    vi.stubGlobal('crypto', webcrypto)
    const first = createPassword()
    const second = createPassword()
    expect(first).toMatch(/^[A-Za-z2-9]{20}$/)
    expect(first).not.toBe(second)
    const salt = hex(webcrypto.getRandomValues(new Uint8Array(16)))
    expect(await hashPassword(first, salt)).toBe(await hashPassword(first, salt))
    expect(await hashPassword(first, salt)).not.toBe(await hashPassword(second, salt))
    expect(await hmac('server-only-secret', `rider-auth:${first}`)).not.toBe(await sha256(first))
    vi.unstubAllGlobals()
  })

  it('accepts a challenge from the enrolled key and rejects a different phone key', async () => {
    vi.stubGlobal('crypto', webcrypto)
    const original = await webcrypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign', 'verify'])
    const other = await webcrypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign', 'verify'])
    const publicKey = await webcrypto.subtle.exportKey('jwk', original.publicKey)
    const challenge = hex(webcrypto.getRandomValues(new Uint8Array(32)))
    const sign = async (key: CryptoKey) => hex(new Uint8Array(await webcrypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(challenge))))
    expect(validPublicKey(publicKey)).toBe(true)
    expect(await verifyDeviceSignature(publicKey, challenge, await sign(original.privateKey))).toBe(true)
    expect(await verifyDeviceSignature(publicKey, challenge, await sign(other.privateKey))).toBe(false)
    expect(await verifyDeviceSignature(publicKey, challenge, 'not-a-signature')).toBe(false)
    vi.unstubAllGlobals()
  })
})
