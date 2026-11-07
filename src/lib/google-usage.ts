import { getSupabaseClient } from './supabase'

export type GoogleBrowserSku = 'places_text' | 'places_nearby' | 'geocoding' | 'dynamic_maps' | 'autocomplete_requests' | 'place_details'
const pending: Partial<Record<GoogleBrowserSku, number>> = {}
let timer: ReturnType<typeof setTimeout> | undefined
let sending = false

async function flush() {
  timer = undefined
  if (sending || !Object.keys(pending).length) return
  sending = true
  const batch = { ...pending }
  for (const key of Object.keys(batch) as GoogleBrowserSku[]) delete pending[key]
  try {
    const client = getSupabaseClient()
    const { data: { session } } = await client.auth.getSession()
    if (!session) return
    const { error } = await client.rpc('record_google_browser_usage', { p_counts: batch })
    if (error) throw error
  } catch {
    // Usage telemetry must never block address selection. The next batch retries it.
    for (const key of Object.keys(batch) as GoogleBrowserSku[]) {
      const room = 100 - Object.values(pending).reduce((sum, count) => sum + (count ?? 0), 0)
      if (room <= 0) break
      pending[key] = (pending[key] ?? 0) + Math.min(room, batch[key] ?? 0)
    }
  } finally {
    sending = false
    if (Object.keys(pending).length && !timer) timer = setTimeout(() => void flush(), 60_000)
  }
}

export function recordGoogleBrowserUsage(sku: GoogleBrowserSku) {
  if (Object.values(pending).reduce((sum, count) => sum + (count ?? 0), 0) >= 100) return
  pending[sku] = (pending[sku] ?? 0) + 1
  if (!timer && !sending) timer = setTimeout(() => void flush(), 60_000)
}
