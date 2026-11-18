export type DojahRiderEvent = {
  reference_id?: unknown
  widget_id?: unknown
  id_type?: unknown
  value?: unknown
  status?: unknown
  verification_status?: unknown
  data?: { government_data?: { status?: unknown }; selfie?: { status?: unknown }; address?: { status?: unknown } }
}

export function assessDojahRiderEvent(event: DojahRiderEvent, widgetId: string): 'passed' | 'failed' | 'pending' {
  if (!widgetId || event.widget_id !== widgetId || typeof event.reference_id !== 'string'
    || !/^KWP-RIDER-[0-9a-f-]{36}$/.test(event.reference_id)) return 'failed'
  if (event.verification_status === 'Pending' || event.verification_status === 'Ongoing') return 'pending'
  if (event.verification_status !== 'Completed' || event.status !== true
    || String(event.id_type).toUpperCase() !== 'NIN' || !/^[0-9]{11}$/.test(String(event.value ?? ''))
    || event.data?.government_data?.status !== true || event.data?.selfie?.status !== true
    || event.data?.address?.status !== true) return 'failed'
  return 'passed'
}

export async function verifyDojahSignature(raw: string, signature: string, secret: string): Promise<boolean> {
  if (!secret || !/^[a-f0-9]{64}$/i.test(signature)) return false
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['verify'])
  const bytes = Uint8Array.from(signature.match(/../g)!, pair => parseInt(pair, 16))
  return crypto.subtle.verify('HMAC', key, bytes, new TextEncoder().encode(raw))
}
