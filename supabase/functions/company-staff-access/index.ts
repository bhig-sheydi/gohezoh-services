import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { bytes, createPassword, hashPassword, hex, hmac, validPublicKey, verifyDeviceSignature } from '../_shared/rider-crypto.ts'

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization,apikey,content-type,x-client-info', 'Access-Control-Allow-Methods': 'POST,OPTIONS' }
const reply = (value: Record<string, unknown>, status = 200) => Response.json(value, { status, headers: cors })
const uuid = (value: unknown): value is string => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)
type Staff = { id: string; partner_id: string; user_id: string | null; full_name: string; password_salt: string; password_hash: string;
  auth_secret_seed: string; failed_attempts: number; device_mismatch_attempts: number; revoked_at: string | null; password_revoked_at: string | null }

async function revokeSessions(admin: ReturnType<typeof createClient>, anonKey: string, url: string, secret: string, staff: Staff) {
  if (!staff.user_id) return
  const { data: identity } = await admin.auth.admin.getUserById(staff.user_id)
  if (!identity.user?.email) return
  const auth = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const authPassword = await hmac(secret, `company-staff-auth:${staff.auth_secret_seed}`)
  const { data: signed } = await auth.auth.signInWithPassword({ email: identity.user.email, password: authPassword })
  if (signed.session) await admin.auth.admin.signOut(signed.session.access_token, 'global')
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (request.method !== 'POST') return reply({ error: 'Method not allowed' }, 405)
  const url = Deno.env.get('SUPABASE_URL') ?? ''
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
  const secret = Deno.env.get('RIDER_AUTH_SECRET') ?? ''
  if (!url || !anonKey || !serviceKey || !secret) return reply({ error: 'Company staff access is not configured' }, 503)
  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
  let body: Record<string, unknown>
  try { body = await request.json() } catch { return reply({ error: 'Invalid request' }, 400) }
  const action = String(body.action ?? '')
  if (['create', 'reset', 'permissions', 'remove', 'list'].includes(action)) {
    const authorization = request.headers.get('Authorization') ?? ''
    if (!authorization.startsWith('Bearer ')) return reply({ error: 'Company owner sign-in required' }, 401)
    const { data: { user } } = await admin.auth.getUser(authorization.slice(7))
    if (!user || !uuid(body.partnerId)) return reply({ error: 'Company owner sign-in required' }, 401)
    const partnerId = body.partnerId
    const { data: manager } = await admin.from('partner_users').select('partner_id').eq('user_id', user.id)
      .eq('partner_id', partnerId).eq('membership_role', 'manager').maybeSingle()
    const { data: partnerRole } = await admin.from('user_roles').select('user_id').eq('user_id', user.id).eq('role', 'partner').maybeSingle()
    const { data: partner } = await admin.from('logistics_partners').select('status').eq('id', partnerId).maybeSingle()
    if (!manager || !partnerRole || partner?.status !== 'active') return reply({ error: 'Only the company owner can manage operations staff' }, 403)
    if (action === 'list') {
      const { data: rows, error: listError } = await admin.from('company_operations_staff')
        .select('id,full_name,can_bid,can_manage_riders,can_withdraw,password_revoked_at,revoked_at,company_operations_staff_devices(kind,label)')
        .eq('partner_id', partnerId).order('created_at', { ascending: false }).limit(100)
      const { data: alerts } = await admin.from('company_operations_staff_alerts').select('staff_id,message,created_at')
        .eq('partner_id', partnerId).order('created_at', { ascending: false }).limit(20)
      return listError ? reply({ error: 'Could not load operations staff' }, 500) : reply({ staff: rows, alerts: alerts ?? [] })
    }
    const staffId = String(body.staffId ?? '')
    const { data: existing } = uuid(staffId) ? await admin.from('company_operations_staff').select('*')
      .eq('id', staffId).eq('partner_id', partnerId).maybeSingle() : { data: null }
    if (action !== 'create' && !existing) return reply({ error: 'Staff member not found' }, 404)
    if (action === 'permissions' || action === 'remove') {
      if (existing.revoked_at) return reply({ error: 'Staff member was already removed' }, 409)
      const changes = action === 'remove' ? { revoked_at: new Date().toISOString(), session_not_before: new Date().toISOString() } : {
        session_not_before: new Date().toISOString(),
        can_bid: body.canBid === true, can_manage_riders: body.canManageRiders === true, can_withdraw: body.canWithdraw === true,
        updated_at: new Date().toISOString(),
      }
      const { error } = await admin.from('company_operations_staff').update(changes).eq('id', staffId).eq('partner_id', partnerId)
      if (error) return reply({ error: 'Could not update staff access' }, 500)
      if (action === 'remove') {
        await admin.from('partner_users').delete().eq('partner_id', partnerId).eq('user_id', existing.user_id)
        await admin.from('user_roles').delete().eq('user_id', existing.user_id).eq('role', 'partner')
      }
      await revokeSessions(admin, anonKey, url, secret, existing as Staff)
      await admin.from('audit_logs').insert({ entity_type: 'company_operations_staff', entity_id: staffId,
        action: action === 'remove' ? 'removed' : 'permissions_changed', actor_id: user.id,
        changed_fields: action === 'remove' ? ['revoked_at'] : ['can_bid', 'can_manage_riders', 'can_withdraw'] })
      return reply({ ok: true })
    }
    const requested = typeof body.password === 'string' ? body.password.trim() : ''
    if (requested && (requested.length < 12 || requested.length > 80 || !/[A-Za-z]/.test(requested) || !/[0-9]/.test(requested)))
      return reply({ error: 'Use 12-80 characters with letters and numbers' }, 400)
    const password = requested || createPassword()
    const salt = hex(bytes(16))
    const passwordHash = await hashPassword(password, salt)
    const fingerprint = await hmac(secret, `staff-password:${password}`)
    const { data: usedByRider } = await admin.from('rider_credentials').select('user_id')
      .eq('password_fingerprint', await hmac(secret, `rider-password:${password}`)).maybeSingle()
    if (usedByRider) return reply({ error: 'That password is already used by a rider. Choose another.' }, 409)
    if (action === 'reset') {
      if (existing.revoked_at) return reply({ error: 'Removed staff cannot be reset' }, 409)
      await revokeSessions(admin, anonKey, url, secret, existing as Staff)
      const { error } = await admin.from('company_operations_staff').update({ password_salt: salt, password_hash: passwordHash,
        password_fingerprint: fingerprint, password_revoked_at: null, failed_attempts: 0, device_mismatch_attempts: 0,
        session_not_before: new Date().toISOString(),
        updated_at: new Date().toISOString() }).eq('id', staffId).eq('partner_id', partnerId)
      if (error?.code === '23505') return reply({ error: 'This password is already used by another staff member' }, 409)
      if (error) return reply({ error: 'Could not reset password' }, 500)
      await admin.from('company_operations_staff_devices').delete().eq('staff_id', staffId)
      return reply({ password })
    }
    const name = String(body.fullName ?? '').trim()
    if (name.length < 3 || name.length > 120) return reply({ error: 'Enter the staff member’s full name' }, 400)
    const seed = hex(bytes(32))
    const authPassword = await hmac(secret, `company-staff-auth:${seed}`)
    const email = `operator-${crypto.randomUUID()}@accounts.gohezohservices.org`
    const { data: created, error: createError } = await admin.auth.admin.createUser({ email, password: authPassword,
      email_confirm: true, user_metadata: { full_name: name, account_kind: 'company_operator' } })
    if (createError || !created.user) return reply({ error: 'Could not create staff account' }, 500)
    const userId = created.user.id
    const { error: roleError } = await admin.from('user_roles').insert({ user_id: userId, role: 'partner' })
    const { error: membershipError } = roleError ? { error: roleError } : await admin.from('partner_users').insert({ partner_id: partnerId, user_id: userId, membership_role: 'dispatcher' })
    const { data: staff, error: staffError } = roleError || membershipError ? { data: null, error: roleError ?? membershipError } : await admin.from('company_operations_staff').insert({
      partner_id: partnerId, user_id: userId, full_name: name, auth_secret_seed: seed,
      password_salt: salt, password_hash: passwordHash, password_fingerprint: fingerprint,
      can_bid: body.canBid === true, can_manage_riders: body.canManageRiders === true, can_withdraw: body.canWithdraw === true,
    }).select('id').single()
    if (staffError || !staff) {
      await admin.auth.admin.deleteUser(userId)
      return reply({ error: staffError?.code === '23505' ? 'This password is already used by another staff member' : 'Could not finish creating staff access' }, staffError?.code === '23505' ? 409 : 500)
    }
    await admin.from('audit_logs').insert({ entity_type: 'company_operations_staff', entity_id: staff.id,
      action: 'created', actor_id: user.id, changed_fields: ['partner_id', 'can_bid', 'can_manage_riders', 'can_withdraw'] })
    return reply({ staffId: staff.id, password })
  }

  if (!uuid(body.staffId) || typeof body.password !== 'string') return reply({ error: 'Invalid staff link or password' }, 400)
  const staffId = body.staffId
  const kind = body.deviceKind === 'phone' ? 'phone' : body.deviceKind === 'desktop' ? 'desktop' : null
  if (!kind) return reply({ error: 'Use a phone or laptop browser' }, 400)
  const { data: staff } = await admin.from('company_operations_staff').select('*').eq('id', staffId).maybeSingle()
  if (!staff || staff.revoked_at || staff.password_revoked_at) return reply({ error: 'Staff access is unavailable. Contact the company owner.' }, 403)
  const fail = async (deviceMismatch = false) => {
    const { data, error } = await admin.rpc('record_company_staff_auth_failure', { p_staff_id: staffId, p_device_mismatch: deviceMismatch })
    if (error) return reply({ error: 'Could not check staff access. Try again.' }, 503)
    const count = Number(data)
    const revoked = count > 3
    if (revoked) {
      await revokeSessions(admin, anonKey, url, secret, staff as Staff)
    }
    return reply({ error: revoked ? 'Staff password revoked after repeated attempts. Contact your company owner.' :
      deviceMismatch ? 'This device is not registered. Contact your company owner.' : 'Incorrect staff password' }, revoked ? 403 : 401)
  }
  if (await hashPassword(body.password, staff.password_salt) !== staff.password_hash) return fail()
  const { data: device } = await admin.from('company_operations_staff_devices').select('*').eq('staff_id', staffId).eq('kind', kind).maybeSingle()
  if (action === 'challenge') {
    if (!device) return reply({ firstDevice: true })
    const challenge = hex(bytes(32))
    await admin.from('company_operations_staff_devices').update({ challenge, challenge_expires_at: new Date(Date.now() + 90_000).toISOString() })
      .eq('staff_id', staffId).eq('kind', kind)
    return reply({ challenge })
  }
  if (action !== 'login') return reply({ error: 'Unknown action' }, 400)
  if (!device) {
    if (!validPublicKey(body.publicKey)) return reply({ error: 'This browser cannot securely register a device' }, 400)
    const { error } = await admin.from('company_operations_staff_devices').insert({ staff_id: staffId, kind, public_key: body.publicKey,
      label: String(body.deviceLabel ?? '').slice(0, 120) })
    if (error) return fail(true)
  } else {
    if (!device.challenge || !device.challenge_expires_at || new Date(device.challenge_expires_at).getTime() < Date.now())
      return reply({ error: 'Sign-in challenge expired. Try again.' }, 401)
    let valid = false
    try { valid = await verifyDeviceSignature(device.public_key, device.challenge, String(body.signature ?? '')) } catch { /* Invalid device proof. */ }
    if (!valid) return fail(true)
    const { data: consumed } = await admin.from('company_operations_staff_devices').update({ challenge: null, challenge_expires_at: null })
      .eq('staff_id', staffId).eq('kind', kind).eq('challenge', device.challenge).select('staff_id').maybeSingle()
    if (!consumed) return reply({ error: 'Sign-in challenge expired. Try again.' }, 401)
  }
  await admin.from('company_operations_staff').update({ failed_attempts: 0, device_mismatch_attempts: 0 }).eq('id', staffId)
  const { data: identity } = await admin.auth.admin.getUserById(staff.user_id)
  if (!identity.user?.email) return reply({ error: 'Staff sign-in is unavailable' }, 503)
  const auth = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const authPassword = await hmac(secret, `company-staff-auth:${staff.auth_secret_seed}`)
  const { data: signed, error } = await auth.auth.signInWithPassword({ email: identity.user.email, password: authPassword })
  if (error || !signed.session) return reply({ error: 'Staff sign-in is unavailable' }, 503)
  return reply({ session: signed.session, staffName: staff.full_name })
})
