const encoder = new TextEncoder()
export const bytes = (count: number) => crypto.getRandomValues(new Uint8Array(count))
export const hex = (value: Uint8Array) => [...value].map((byte) => byte.toString(16).padStart(2, '0')).join('')
export const unhex = (value: string) => new Uint8Array(value.match(/.{2}/g)?.map((part) => parseInt(part, 16)) ?? [])
export const sha256 = async (value: string) => hex(new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(value))))
export const hmac = async (key: string, message: string) => {
  const secret = await crypto.subtle.importKey('raw', encoder.encode(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  return hex(new Uint8Array(await crypto.subtle.sign('HMAC', secret, encoder.encode(message))))
}
export async function hashPassword(password: string, salt: string) {
  const material = await crypto.subtle.importKey('raw', encoder.encode(password), 'PBKDF2', false, ['deriveBits'])
  return hex(new Uint8Array(await crypto.subtle.deriveBits({ name: 'PBKDF2', salt: unhex(salt), iterations: 210_000, hash: 'SHA-256' }, material, 256)))
}
export function createPassword() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
  const random = bytes(20)
  return [...random].map((byte) => alphabet[byte % alphabet.length]).join('')
}
export function validPublicKey(key: unknown): key is JsonWebKey {
  if (!key || typeof key !== 'object') return false
  const candidate = key as JsonWebKey
  return candidate.kty === 'EC' && candidate.crv === 'P-256' && typeof candidate.x === 'string' && typeof candidate.y === 'string' && !candidate.d
}
export async function verifyDeviceSignature(publicKey: JsonWebKey, challenge: string, signature: string) {
  if (!/^[0-9a-f]+$/i.test(signature) || signature.length % 2 !== 0) return false
  const key = await crypto.subtle.importKey('jwk', publicKey, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify'])
  return crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, unhex(signature), encoder.encode(challenge))
}
