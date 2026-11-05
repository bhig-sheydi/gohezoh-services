import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' }
const json = (value: unknown, status = 200) => Response.json(value, { status, headers: cors })

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  const auth = request.headers.get('Authorization')
  if (!auth?.startsWith('Bearer ')) return json({ error: 'Sign in as Super Admin' }, 401)
  const url = Deno.env.get('SUPABASE_URL') ?? ''
  const userClient = createClient(url, Deno.env.get('SUPABASE_ANON_KEY') ?? '', { global: { headers: { Authorization: auth } }, auth: { persistSession: false } })
  const { data: { user }, error: userError } = await userClient.auth.getUser()
  if (userError || !user) return json({ error: 'Sign in as Super Admin' }, 401)
  const { data: allowed, error: roleError } = await userClient.rpc('has_role', { _user_id: user.id, _role: 'admin' })
  if (roleError || allowed !== true) return json({ error: 'Super Admin access is required' }, 403)
  const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '', { auth: { persistSession: false } })
  const { data, error } = await admin.rpc('list_orphan_partner_verification_files', { p_limit: 100 })
  if (error) return json({ error: 'Could not list expired evidence' }, 500)
  const paths = ((data ?? []) as Array<{ path: string }>).map((row) => row.path)
  if (paths.length === 0) return json({ removed: 0 })
  const result = await admin.storage.from('partner-verification').remove(paths)
  if (result.error) return json({ error: 'Could not remove expired evidence' }, 500)
  return json({ removed: paths.length })
})
