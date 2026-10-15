type StoredKey = { privateKey: CryptoKey; publicKey: CryptoKey }

function openStore(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open('kwik-parsel-rider-device', 1)
    request.onupgradeneeded = () => request.result.createObjectStore('keys')
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error)
  })
}

async function deviceKey(token: string): Promise<StoredKey> {
  const db = await openStore()
  const keyId = [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(token)))].map((byte) => byte.toString(16).padStart(2, '0')).join('')
  try {
    const existing = await new Promise<StoredKey | undefined>((resolve, reject) => {
      const request = db.transaction('keys', 'readonly').objectStore('keys').get(keyId)
      request.onsuccess = () => resolve(request.result as StoredKey | undefined)
      request.onerror = () => reject(request.error)
    })
    if (existing) return existing
    const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign', 'verify'])
    await new Promise<void>((resolve, reject) => {
      const transaction = db.transaction('keys', 'readwrite')
      transaction.objectStore('keys').put(pair, keyId)
      transaction.oncomplete = () => resolve()
      transaction.onerror = () => reject(transaction.error)
    })
    return pair
  } finally { db.close() }
}

export async function riderDeviceProof(token: string, challenge?: string): Promise<{ publicKey?: JsonWebKey; signature?: string }> {
  const key = await deviceKey(token)
  if (!challenge) return { publicKey: await crypto.subtle.exportKey('jwk', key.publicKey) }
  const signed = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key.privateKey, new TextEncoder().encode(challenge)))
  return { signature: [...signed].map((byte) => byte.toString(16).padStart(2, '0')).join('') }
}
