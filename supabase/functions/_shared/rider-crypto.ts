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
  const words = 'Market River Mango Basket Orange Pepper Tomato Garden Palm Table Chair School Letter Parcel Driver Bridge Banana Kettle Bottle Coffee Sugar Street Water Window Mother Father Brother Sister Family Doctor Teacher Farmer Trader Cotton Fabric Button Yellow Green Purple Silver Golden Happy Sunny Rainy Cloudy Morning Evening Sunday Monday Friday Lagos Abuja Kano Enugu Ibadan Kaduna Owerri Jos Aba Benin Uyo Akure Minna Lokoja Maiduguri Calabar Ilorin Yola Bauchi Zaria'.split(' ')
  const random = bytes(8)
  const chosen = [0, 1, 2, 3].map((index) => words[random[index] % words.length])
  const digits = (new DataView(random.buffer).getUint32(4) % 9000 + 1000).toString()
  return `${chosen.join('-')}-${digits}`
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
