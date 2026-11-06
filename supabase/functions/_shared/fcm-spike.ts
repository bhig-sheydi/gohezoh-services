export type FirebaseServiceAccount = {
  project_id: string
  client_email: string
  private_key: string
}

export type SpikeDelivery = {
  delivery_id: string
  alert_id: string
  device_token: string
  severity: 'warning' | 'critical'
  source: string
  cause: string
}

const encoder = new TextEncoder()

function base64url(value: Uint8Array): string {
  let binary = ''
  for (const byte of value) binary += String.fromCharCode(byte)
  return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '')
}

export function parseFirebaseServiceAccount(raw: string): FirebaseServiceAccount {
  const value = JSON.parse(raw) as Partial<FirebaseServiceAccount>
  if (!value || typeof value.project_id !== 'string' ||
      !/^[a-z0-9][a-z0-9-]{4,63}$/.test(value.project_id) ||
      typeof value.client_email !== 'string' ||
      !value.client_email.endsWith('.gserviceaccount.com') ||
      typeof value.private_key !== 'string' ||
      !value.private_key.includes('BEGIN PRIVATE KEY')) {
    throw new Error('Firebase service account is invalid')
  }
  return value as FirebaseServiceAccount
}

export async function firebaseAccessToken(
  account: FirebaseServiceAccount,
  request: typeof fetch = fetch,
  clock: () => number = () => Date.now(),
): Promise<{ token: string; expiresAt: number }> {
  const issuedAt = Math.floor(clock() / 1000)
  const header = base64url(encoder.encode(JSON.stringify({ alg: 'RS256', typ: 'JWT' })))
  const claims = base64url(encoder.encode(JSON.stringify({
    iss: account.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: issuedAt,
    exp: issuedAt + 3600,
  })))
  const der = Uint8Array.from(atob(account.private_key.replace(/-----[^-]+-----|\s/g, '')),
    (char) => char.charCodeAt(0))
  const key = await crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false, ['sign'])
  const unsigned = `${header}.${claims}`
  const signature = base64url(new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key,
    encoder.encode(unsigned))))
  const response = await request('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${unsigned}.${signature}`,
    }),
    signal: AbortSignal.timeout(8000),
  })
  if (!response.ok) throw new Error(`Firebase authentication failed (${response.status})`)
  const payload = await response.json() as { access_token?: string; expires_in?: number }
  if (typeof payload.access_token !== 'string' || !payload.access_token)
    throw new Error('Firebase authentication returned no token')
  return { token: payload.access_token, expiresAt: clock() +
    Math.max(60, Math.min(3600, Number(payload.expires_in) || 3600) - 60) * 1000 }
}

export function fcmSpikeMessage(delivery: SpikeDelivery) {
  const label = delivery.source.replaceAll('_', ' ')
  return {
    message: {
      token: delivery.device_token,
      notification: {
        title: delivery.severity === 'critical' ? 'Critical Kwik-Parsel spike' : 'Kwik-Parsel spike',
        body: `${label}: ${delivery.cause}`.slice(0, 220),
      },
      data: { alert_id: delivery.alert_id },
      android: {
        priority: 'HIGH',
        ttl: '300s',
        collapse_key: `spike-${delivery.alert_id}`,
        notification: { channel_id: 'admin_spike_alarm_v1', tag: delivery.alert_id },
      },
    },
  }
}

export async function sendFcmSpike(
  account: FirebaseServiceAccount,
  accessToken: string,
  delivery: SpikeDelivery,
  request: typeof fetch = fetch,
): Promise<{ sent: boolean; code: string; invalidToken: boolean }> {
  const response = await request(`https://fcm.googleapis.com/v1/projects/${account.project_id}/messages:send`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${accessToken}` },
    body: JSON.stringify(fcmSpikeMessage(delivery)),
    signal: AbortSignal.timeout(8000),
  })
  if (response.ok) return { sent: true, code: 'sent', invalidToken: false }
  const result = await response.json().catch(() => ({})) as {
    error?: { status?: string; details?: Array<{ errorCode?: string }> }
  }
  const code = result.error?.details?.find((part) => part.errorCode)?.errorCode ||
    result.error?.status || `HTTP_${response.status}`
  return { sent: false, code: code.slice(0, 80), invalidToken: code === 'UNREGISTERED' }
}
