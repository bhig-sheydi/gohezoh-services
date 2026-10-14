import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.117.2'
import { createLocationAddressHandler } from '../_shared/location-address.ts'

const supabaseUrl = Deno.env.get('SUPABASE_URL')
const anonKey = Deno.env.get('SUPABASE_ANON_KEY')

// JWT validation is performed with Auth rather than trusting unverified token claims.
// Deploy with verify_jwt=false to support current Supabase signing keys; all POSTs
// still require auth.getUser(). No service role credentials or database writes are used.
Deno.serve(createLocationAddressHandler({
  apiKey: Deno.env.get('GEOAPIFY_API_KEY'),
  productionOrigin: Deno.env.get('PUBLIC_APP_URL') || 'https://gohezoh-services.vercel.app',
  async authenticate(authorization) {
    if (!supabaseUrl || !anonKey) throw new Error('Authentication is not configured')
    const client = createClient(supabaseUrl, anonKey, {
      global: {
        headers: { Authorization: authorization },
        fetch: (input, init) => fetch(input, { ...init, signal: AbortSignal.timeout(5000) }),
      },
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    })
    const { data: { user }, error } = await client.auth.getUser(authorization.slice(7))
    if (error && (!error.status || error.status >= 500)) throw new Error('Authentication is unavailable')
    if (error) return null
    return user?.id ?? null
  },
}))
