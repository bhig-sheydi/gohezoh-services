// Disposable live smoke test. Requires SUPABASE_URL, SUPABASE_ANON_KEY and
// SUPABASE_SERVICE_ROLE_KEY in the process environment. Prints no credentials.
import { createClient } from '@supabase/supabase-js'
import { randomBytes, randomUUID, webcrypto } from 'node:crypto'

const url = process.env.SUPABASE_URL
const anonKey = process.env.SUPABASE_ANON_KEY
const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY
if (!url || !anonKey || !serviceKey) throw new Error('Missing test connection settings')
const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
const anon = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
const managerEmail = `rider-smoke-${randomUUID()}@example.test`
const managerPassword = randomBytes(24).toString('hex')
let managerId = ''
let riderId = ''
let partnerId = ''
const assert = (condition, message) => { if (!condition) throw new Error(message) }
const call = async (payload, accessToken) => {
  const response = await fetch(`${url}/functions/v1/rider-access`, { method: 'POST', headers: {
    apikey: anonKey, 'content-type': 'application/json', ...(accessToken ? { Authorization: `Bearer ${accessToken}` } : {}),
  }, body: JSON.stringify(payload) })
  const result = await response.json()
  return { status: response.status, ...result }
}
const phone = async () => webcrypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign', 'verify'])
const signature = async (key, challenge) => Buffer.from(await webcrypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key.privateKey, new TextEncoder().encode(challenge))).toString('hex')

try {
  const { data: created, error: userError } = await admin.auth.admin.createUser({ email: managerEmail, password: managerPassword,
    email_confirm: true, user_metadata: { account_kind: 'company_rider', full_name: 'Temporary Manager' } })
  if (userError || !created.user) throw userError ?? new Error('Manager fixture failed')
  managerId = created.user.id
  const { data: partner, error: partnerError } = await admin.from('logistics_partners').insert({ partner_name: 'Temporary Rider Smoke Company',
    contact_person: 'Temporary Manager', phone: '+2348010000999', status: 'active' }).select('id').single()
  if (partnerError || !partner) throw partnerError ?? new Error('Partner fixture failed')
  partnerId = partner.id
  const { error: roleError } = await admin.from('user_roles').insert({ user_id: managerId, role: 'partner' })
  if (roleError) throw roleError
  const { error: memberError } = await admin.from('partner_users').insert({ partner_id: partnerId, user_id: managerId, membership_role: 'manager' })
  if (memberError) throw memberError
  const { data: signed, error: signError } = await anon.auth.signInWithPassword({ email: managerEmail, password: managerPassword })
  if (signError || !signed.session) throw signError ?? new Error('Manager sign-in failed')
  const managerToken = signed.session.access_token
  const createdRider = await call({ action: 'create', partnerId, name: 'Temporary Test Rider' }, managerToken)
  assert(createdRider.status === 200 && createdRider.token && createdRider.password && createdRider.riderId,
    `Rider creation failed (${createdRider.status}): ${createdRider.error ?? ''}`)
  riderId = createdRider.riderId
  const first = await call({ action: 'challenge', token: createdRider.token })
  assert(first.status === 200 && first.firstDevice === true, 'First phone was not offered enrollment')
  const firstPhone = await phone()
  const loggedIn = await call({ action: 'login', token: createdRider.token, password: createdRider.password,
    publicKey: await webcrypto.subtle.exportKey('jwk', firstPhone.publicKey) })
  assert(loggedIn.status === 200 && loggedIn.session?.access_token, `First rider login failed: ${loggedIn.error ?? ''}`)
  const rider = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${loggedIn.session.access_token}` } } })
  const team = await rider.rpc('list_my_partner_team')
  assert(Boolean(team.error), 'Rider gained owner team access')
  const jobs = await rider.rpc('list_my_rider_jobs')
  assert(!jobs.error && Array.isArray(jobs.data) && jobs.data.length === 0, 'Rider job scope failed')
  const profile = await rider.rpc('my_rider_profile')
  assert(!profile.error && profile.data?.[0]?.company_name === 'Temporary Rider Smoke Company', 'Rider company identity failed')
  const challenge = await call({ action: 'challenge', token: createdRider.token })
  assert(challenge.status === 200 && challenge.challenge, 'Bound phone challenge missing')
  const otherPhone = await phone()
  const rejected = await call({ action: 'login', token: createdRider.token, password: createdRider.password,
    signature: await signature(otherPhone, challenge.challenge) })
  assert(rejected.status === 403 && /changed your phone/i.test(rejected.error), 'Different phone was not rejected')
  const returning = await call({ action: 'login', token: createdRider.token, password: createdRider.password,
    signature: await signature(firstPhone, challenge.challenge) })
  assert(returning.status === 200 && returning.session?.access_token, 'Enrolled phone could not sign in again')
  const reset = await call({ action: 'reset', partnerId, riderId }, managerToken)
  assert(reset.status === 200 && reset.token && reset.password, `Management reset failed: ${reset.error ?? ''}`)
  assert((await call({ action: 'challenge', token: createdRider.token })).status === 401, 'Old rider link still works')
  const oldSession = await rider.rpc('list_my_rider_jobs')
  assert(Boolean(oldSession.error), 'Old rider session remained usable after management reset')
  const secondPhone = await phone()
  const again = await call({ action: 'login', token: reset.token, password: reset.password,
    publicKey: await webcrypto.subtle.exportKey('jwk', secondPhone.publicKey) })
  assert(again.status === 200 && again.session?.access_token, `Reset rider login failed: ${again.error ?? ''}`)
  console.log('Rider live smoke test passed: create, first and returning phone, role isolation, changed phone, reset, revoked session, new phone.')
} finally {
  if (riderId) await admin.from('audit_logs').delete().eq('entity_id', riderId)
  if (partnerId) await admin.from('audit_logs').delete().eq('entity_id', partnerId)
  if (managerId) await admin.from('audit_logs').delete().eq('actor_id', managerId)
  if (riderId) await admin.auth.admin.deleteUser(riderId)
  if (managerId) await admin.auth.admin.deleteUser(managerId)
  if (partnerId) await admin.from('logistics_partners').delete().eq('id', partnerId)
}
