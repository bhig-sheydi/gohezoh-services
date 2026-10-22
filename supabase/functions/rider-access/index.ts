import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { bytes, createPassword, hashPassword, hex, hmac, sha256, validPublicKey, verifyDeviceSignature } from '../_shared/rider-crypto.ts'

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization,apikey,content-type,x-client-info', 'Access-Control-Allow-Methods': 'POST,OPTIONS' }
const reply = (body: Record<string, unknown>, status = 200) => Response.json(body, { status, headers: cors })
async function canManageRiders(userClient: ReturnType<typeof createClient>, partnerId: string) {
  const { data, error } = await userClient.rpc('company_staff_allowed', { p_partner_id: partnerId, p_permission: 'riders' })
  return !error && data === true
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (request.method !== 'POST') return reply({ error: 'Method not allowed' }, 405)
  const url = Deno.env.get('SUPABASE_URL')
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  const riderSecret = Deno.env.get('RIDER_AUTH_SECRET')
  if (!url || !anonKey || !serviceKey || !riderSecret) return reply({ error: 'Rider access is not configured' }, 503)
  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
  let body: Record<string, unknown>
  try { body = await request.json() } catch { return reply({ error: 'Invalid request' }, 400) }
  const action = String(body.action ?? '')

  if (action === 'create' || action === 'reset' || action === 'list') {
    const authorization = request.headers.get('Authorization') ?? ''
    if (!authorization.startsWith('Bearer ')) return reply({ error: 'Company manager sign-in required' }, 401)
    const { data: { user } } = await admin.auth.getUser(authorization.slice(7))
    if (!user) return reply({ error: 'Company manager sign-in required' }, 401)
    const { data: partnerRole } = await admin.from('user_roles').select('user_id').eq('user_id', user.id).eq('role', 'partner').maybeSingle()
    if (!partnerRole) return reply({ error: 'Partner account required' }, 403)
    const partnerId = String(body.partnerId ?? '')
    const userClient = createClient(url, anonKey, { global: { headers: { Authorization: authorization } }, auth: { persistSession: false, autoRefreshToken: false } })
    if (!await canManageRiders(userClient, partnerId)) return reply({ error: 'Company rider-management permission is required' }, 403)
    if (action === 'list') {
      const { data, error } = await admin.from('company_riders').select('id,full_name,phone,status,rejection_reason,photo_path,source_vehicle_id,created_at,rider_credentials(user_id,device_bound_at,device_label,password_revoked_at,revoked_at)')
        .eq('partner_id', partnerId).order('created_at', { ascending: false }).limit(100)
      return error ? reply({ error: 'Could not load riders' }, 500) : reply({ riders: data })
    }
    const rosterId = String(body.rosterId ?? '')
    const { data: roster } = await admin.from('company_riders').select('id,full_name,status')
      .eq('id', rosterId).eq('partner_id', partnerId).maybeSingle()
    if (!roster || roster.status !== 'approved') return reply({ error: 'This rider needs Super Admin approval before access is issued' }, 403)
    const name = roster.full_name
    const token = hex(bytes(32))
    const requestedPassword = typeof body.password === 'string' ? body.password.trim() : ''
    if (requestedPassword && (requestedPassword.length < 12 || requestedPassword.length > 80 || !/[A-Za-z]/.test(requestedPassword) || !/[0-9]/.test(requestedPassword)))
      return reply({ error: 'Use 12-80 characters with letters and numbers for a custom rider password' }, 400)
    const password = requestedPassword || createPassword()
    const salt = hex(bytes(16))
    const passwordHash = await hashPassword(password, salt)
    const fingerprint = await hmac(riderSecret, `rider-password:${password}`)
    const linkHash = await sha256(token)
    if (action === 'reset') {
      const riderId = String(body.riderId ?? '')
      const { data: current } = await admin.from('rider_credentials').select('auth_secret_seed,roster_id').eq('user_id', riderId)
        .eq('partner_id', partnerId).is('revoked_at', null).maybeSingle()
      if (!current || current.roster_id !== rosterId) return reply({ error: 'This rider does not belong to your company' }, 404)
      const { data: identity } = await admin.auth.admin.getUserById(riderId)
      if (!identity.user?.email) return reply({ error: 'Could not reset this rider' }, 503)
      const auth = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
      const authPassword = await hmac(riderSecret, `rider-auth:${current.auth_secret_seed}`)
      const { data: signed } = await auth.auth.signInWithPassword({ email: identity.user.email, password: authPassword })
      if (!signed.session) return reply({ error: 'Could not revoke existing rider sessions' }, 503)
      const { error: revokeError } = await admin.auth.admin.signOut(signed.session.access_token, 'global')
      if (revokeError) return reply({ error: 'Could not revoke existing rider sessions' }, 503)
      const { data, error } = await admin.from('rider_credentials').update({ link_hash: linkHash, password_salt: salt,
        password_hash: passwordHash, password_fingerprint: fingerprint, device_public_key: null, device_bound_at: null,
        challenge: null, challenge_expires_at: null, failed_attempts: 0, locked_until: null,
        device_label: null, device_mismatch_attempts: 0, password_revoked_at: null })
        .eq('user_id', riderId).eq('partner_id', partnerId).is('revoked_at', null).select('user_id').maybeSingle()
      if (error?.code === '23505') return reply({ error: 'This password has been used by another rider. Choose a different one.' }, 409)
      if (error || !data) return reply({ error: 'Could not reset this rider' }, 400)
      return reply({ token, password })
    }
    const { data: existing } = await admin.from('rider_credentials').select('user_id').eq('roster_id', rosterId).maybeSingle()
    if (existing) return reply({ error: 'This rider already has access. Reset their password instead.' }, 409)
    const seed = hex(bytes(32))
    const authPassword = await hmac(riderSecret, `rider-auth:${seed}`)
    const email = `rider-${crypto.randomUUID()}@accounts.gohezohservices.org`
    const { data: created, error: createError } = await admin.auth.admin.createUser({ email, password: authPassword,
      email_confirm: true, user_metadata: { full_name: name, account_kind: 'company_rider' } })
    if (createError || !created.user) return reply({ error: 'Could not create rider account' }, 500)
    const riderId = created.user.id
    const { error: roleError } = await admin.from('user_roles').insert({ user_id: riderId, role: 'rider' })
    const { error: memberError } = roleError ? { error: roleError } : await admin.from('partner_users').insert({ partner_id: partnerId, user_id: riderId, membership_role: 'rider' })
    const { error: credentialError } = roleError || memberError ? { error: roleError ?? memberError } : await admin.from('rider_credentials').insert({
      user_id: riderId, partner_id: partnerId, roster_id: rosterId, rider_name: name, auth_secret_seed: seed, link_hash: linkHash,
      password_salt: salt, password_hash: passwordHash, password_fingerprint: fingerprint,
    })
    if (credentialError) {
      await admin.auth.admin.deleteUser(riderId)
      if (credentialError.code === '23505') return reply({ error: 'This password has been used by another rider. Choose a different one.' }, 409)
      return reply({ error: 'Could not finish creating rider access' }, 500)
    }
    await admin.from('audit_logs').insert({ entity_type: 'rider_credentials', entity_id: riderId,
      action: 'created', actor_id: user.id, changed_fields: ['partner_id', 'rider_name'] })
    return reply({ token, password, riderId })
  }

  const token = String(body.token ?? '')
  const companyId = String(body.companyId ?? '')
  const password = String(body.password ?? '')
  let lookup = admin.from('rider_credentials').select('*').is('revoked_at', null).is('password_revoked_at', null)
  if (/^[0-9a-f]{64}$/.test(token)) lookup = lookup.eq('link_hash', await sha256(token))
  else if (/^[0-9a-f-]{36}$/.test(companyId) && password) lookup = lookup.eq('partner_id', companyId)
    .eq('password_fingerprint', await hmac(riderSecret, `rider-password:${password}`))
  else return reply({ error: 'Invalid rider link or password' }, 400)
  const { data: rider } = await lookup.maybeSingle()
  if (!rider) return reply({ error: 'Invalid rider link or password' }, 401)
  const { data: roster } = await admin.from('company_riders').select('status').eq('id', rider.roster_id).maybeSingle()
  if (roster?.status !== 'approved') return reply({ error: 'Rider access is unavailable. Contact company management.' }, 403)
  if (action === 'challenge') {
    if (!rider.device_public_key) return reply({ firstDevice: true, riderId: rider.user_id })
    const challenge = hex(bytes(32))
    await admin.from('rider_credentials').update({ challenge, challenge_expires_at: new Date(Date.now() + 90_000).toISOString() }).eq('user_id', rider.user_id)
    return reply({ challenge, riderId: rider.user_id })
  }
  if (action !== 'login') return reply({ error: 'Unknown action' }, 400)
  if (rider.locked_until && new Date(rider.locked_until).getTime() > Date.now()) return reply({ error: 'Too many attempts. Contact your management or try again later.' }, 429)
  const calculated = await hashPassword(password, rider.password_salt)
  if (calculated !== rider.password_hash) {
    const attempts = Number(rider.failed_attempts ?? 0) + 1
    await admin.from('rider_credentials').update({ failed_attempts: attempts,
      locked_until: attempts >= 5 ? new Date(Date.now() + 15 * 60_000).toISOString() : null }).eq('user_id', rider.user_id)
    return reply({ error: 'Incorrect rider password' }, 401)
  }
  if (!rider.device_public_key) {
    if (!validPublicKey(body.publicKey)) return reply({ error: 'This phone cannot securely register. Use a supported browser.' }, 400)
    const { data: bound } = await admin.from('rider_credentials').update({ device_public_key: body.publicKey,
      device_bound_at: new Date().toISOString(),device_label: String(body.deviceLabel ?? '').slice(0, 120) || null })
      .eq('user_id', rider.user_id).is('device_public_key', null).select('user_id').maybeSingle()
    if (!bound) {
      const { data: attempts } = await admin.rpc('record_rider_device_mismatch', { p_user_id: rider.user_id })
      return reply({ error: Number(attempts) > 3 ? 'Someone may be trying to access this rider account. The password was removed. Ask management to create a new one.' : 'This password is registered to another phone. Contact management.' }, 403)
    }
  } else {
    if (!rider.challenge || !rider.challenge_expires_at || new Date(rider.challenge_expires_at).getTime() < Date.now())
      return reply({ error: 'Sign-in challenge expired. Try again.' }, 401)
    try {
      const valid = await verifyDeviceSignature(rider.device_public_key, rider.challenge, String(body.signature ?? ''))
      if (!valid) {
        const { data: attempts } = await admin.rpc('record_rider_device_mismatch', { p_user_id: rider.user_id })
        return reply({ error: Number(attempts) > 3 ? 'Someone may be trying to access this rider account. The password was removed. Ask management to create a new one.' : 'This password is registered to another phone. Contact management.' }, 403)
      }
    } catch {
      const { data: attempts } = await admin.rpc('record_rider_device_mismatch', { p_user_id: rider.user_id })
      return reply({ error: Number(attempts) > 3 ? 'Someone may be trying to access this rider account. The password was removed. Ask management to create a new one.' : 'This password is registered to another phone. Contact management.' }, 403)
    }
    const { data: consumed } = await admin.from('rider_credentials').update({ challenge: null, challenge_expires_at: null })
      .eq('user_id', rider.user_id).eq('challenge', rider.challenge).select('user_id').maybeSingle()
    if (!consumed) return reply({ error: 'Sign-in challenge expired. Try again.' }, 401)
  }
  await admin.from('rider_credentials').update({ failed_attempts: 0, locked_until: null }).eq('user_id', rider.user_id)
  const authPassword = await hmac(riderSecret, `rider-auth:${rider.auth_secret_seed}`)
  const { data: identity, error: identityError } = await admin.auth.admin.getUserById(rider.user_id)
  if (identityError || !identity.user?.email) return reply({ error: 'Rider sign-in is unavailable' }, 503)
  const auth = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data: signed, error: signError } = await auth.auth.signInWithPassword({ email: identity.user.email, password: authPassword })
  // The synthetic email is only used inside this server function.
  if (signError || !signed.session) return reply({ error: 'Rider sign-in is unavailable' }, 503)
  return reply({ session: signed.session, riderName: rider.rider_name })
})
