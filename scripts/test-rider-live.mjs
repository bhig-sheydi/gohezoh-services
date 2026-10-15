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
let rosterId = ''
let evidencePaths = []
let partnerId = ''
let customerId = ''
let requestId = ''
let orderId = ''
let jobId = ''
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
  const manager = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${managerToken}` } } })
  const sampleImage = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL/nwAAAABJRU5ErkJggg==', 'base64')
  evidencePaths = ['nin', 'licence'].map((kind) => `${partnerId}/${managerId}/${randomUUID()}-${kind}.png`)
  for (const path of evidencePaths) {
    const uploaded = await manager.storage.from('rider-evidence').upload(path, sampleImage, { contentType: 'image/png' })
    if (uploaded.error) throw uploaded.error
  }
  const { data: registered, error: rosterError } = await manager.rpc('register_company_rider', { p_partner_id: partnerId,
    p_full_name: 'Temporary Test Rider', p_nin: '12345678901', p_nin_document_path: evidencePaths[0],
    p_licence_document_path: evidencePaths[1], p_photo_path: null })
  if (rosterError || !registered) throw rosterError ?? new Error('Rider registration failed')
  rosterId = registered
  const premature = await call({ action: 'create', partnerId, rosterId }, managerToken)
  assert(premature.status === 403, 'Unapproved rider received a password')
  const pending = await manager.from('company_riders').select('status,nin_document_path,licence_document_path').eq('id', rosterId).single()
  assert(!pending.error && pending.data?.status === 'pending' && pending.data.nin_document_path === evidencePaths[0],
    'Company manager could not see the pending documented rider')
  // Super Admin review is exercised separately in a rollback-only SQL test with an allowlisted admin identity.
  const approved = await admin.from('company_riders').update({ status: 'approved', reviewed_at: new Date().toISOString() }).eq('id', rosterId)
  if (approved.error) throw approved.error
  const createdRider = await call({ action: 'create', partnerId, rosterId }, managerToken)
  assert(createdRider.status === 200 && createdRider.token && createdRider.password && createdRider.riderId,
    `Rider creation failed (${createdRider.status}): ${createdRider.error ?? ''}`)
  riderId = createdRider.riderId
  const rosterList = await call({ action: 'list', partnerId }, managerToken)
  assert(rosterList.status === 200 && rosterList.riders?.some((entry) => entry.id === rosterId &&
    (Array.isArray(entry.rider_credentials) ? entry.rider_credentials[0]?.user_id : entry.rider_credentials?.user_id) === riderId),
  `Company roster did not link the approved rider account: ${rosterList.error ?? ''}`)
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
  const { data: service } = await admin.from('services').select('id').eq('code', 'SRV-0001').single()
  assert(service?.id, 'Local delivery service is missing')
  const customer = await admin.from('customers').insert({ company_name: 'Temporary Rider Test Customer', contact_person: 'Test Customer',
    phone: '+2348010000998', created_by: managerId }).select('id').single()
  if (customer.error || !customer.data) throw customer.error ?? new Error('Customer fixture failed')
  customerId = customer.data.id
  const request = await admin.from('service_requests').insert({ customer_id: customerId, service_id: service.id, created_by: managerId,
    pickup_address: '1 Test Road', pickup_city: 'Lagos', sender_name: 'Test Sender', sender_phone: '+2348010000997',
    delivery_address: '2 Test Road', delivery_city: 'Lagos', recipient_name: 'Test Recipient', recipient_phone: '+2348010000996',
    parcel_summary: 'Test parcel' }).select('id').single()
  if (request.error || !request.data) throw request.error ?? new Error('Request fixture failed')
  requestId = request.data.id
  const order = await admin.from('orders').insert({ service_request_id: requestId, customer_id: customerId, service_id: service.id,
    customer_price: 1500, confirmed_by: managerId }).select('id').single()
  if (order.error || !order.data) throw order.error ?? new Error('Order fixture failed')
  orderId = order.data.id
  const job = await admin.from('jobs').insert({ order_id: orderId, customer_id: customerId, service_id: service.id, partner_id: partnerId,
    status: 'partner_assigned', pickup_address: '1 Test Road', pickup_city: 'Lagos', sender_name: 'Test Sender', sender_phone: '+2348010000997',
    delivery_address: '2 Test Road', delivery_city: 'Lagos', recipient_name: 'Test Recipient', recipient_phone: '+2348010000996' }).select('id').single()
  if (job.error || !job.data) throw job.error ?? new Error('Job fixture failed')
  jobId = job.data.id
  const assignment = await admin.from('partner_assignments').insert({ job_id: jobId, partner_id: partnerId, status: 'accepted',
    assigned_by: managerId, responded_at: new Date().toISOString() })
  if (assignment.error) throw assignment.error
  const assigned = await admin.from('jobs').update({ assigned_rider_id: riderId }).eq('id', jobId)
  if (assigned.error) throw assigned.error
  const assignedJobs = await rider.rpc('list_my_rider_jobs')
  assert(!assignedJobs.error && assignedJobs.data?.length === 1 && assignedJobs.data[0].job_id === jobId, 'Assigned rider job is missing')
  const advanced = await rider.rpc('rider_update_job_status', { p_job_id: jobId, p_new_status: 'pickup_scheduled' })
  assert(!advanced.error && advanced.data?.status === 'pickup_scheduled', `Assigned rider could not update progress: ${advanced.error?.message ?? ''}`)
  const managerRiderUpdate = await anon.rpc('rider_update_job_status', { p_job_id: jobId, p_new_status: 'picked_up' })
  assert(Boolean(managerRiderUpdate.error), 'Company owner used rider-only progress action')
  const challenge = await call({ action: 'challenge', token: createdRider.token })
  assert(challenge.status === 200 && challenge.challenge, 'Bound phone challenge missing')
  const otherPhone = await phone()
  const rejected = await call({ action: 'login', token: createdRider.token, password: createdRider.password,
    signature: await signature(otherPhone, challenge.challenge) })
  assert(rejected.status === 403 && /another phone/i.test(rejected.error), 'Different phone was not rejected')
  const returning = await call({ action: 'login', token: createdRider.token, password: createdRider.password,
    signature: await signature(firstPhone, challenge.challenge) })
  assert(returning.status === 200 && returning.session?.access_token, 'Enrolled phone could not sign in again')
  for (let attempt = 0; attempt < 3; attempt++) {
    const foreignChallenge = await call({ action: 'challenge', companyId: partnerId, password: createdRider.password })
    const foreign = await call({ action: 'login', companyId: partnerId, password: createdRider.password,
      signature: await signature(otherPhone, foreignChallenge.challenge) })
    assert(foreign.status === 403, 'Another phone was not refused')
  }
  const revokedPassword = await call({ action: 'challenge', companyId: partnerId, password: createdRider.password })
  assert(revokedPassword.status === 401, 'Password survived four other-phone attempts')
  const reset = await call({ action: 'reset', partnerId, rosterId, riderId }, managerToken)
  assert(reset.status === 200 && reset.token && reset.password, `Management reset failed: ${reset.error ?? ''}`)
  assert((await call({ action: 'challenge', token: createdRider.token })).status === 401, 'Old rider link still works')
  const oldSession = await rider.rpc('list_my_rider_jobs')
  assert(Boolean(oldSession.error), 'Old rider session remained usable after management reset')
  const secondPhone = await phone()
  const again = await call({ action: 'login', companyId: partnerId, password: reset.password,
    publicKey: await webcrypto.subtle.exportKey('jwk', secondPhone.publicKey) })
  assert(again.status === 200 && again.session?.access_token, `Reset rider login failed: ${again.error ?? ''}`)
  const archived = await manager.rpc('archive_company_rider', { p_rider_id: rosterId })
  if (archived.error) throw archived.error
  assert((await call({ action: 'challenge', companyId: partnerId, password: reset.password })).status === 401,
    'Archived rider could still sign in')
  console.log('Rider live smoke test passed: roster access, first and returning phone, assigned job update, role isolation, four-attempt lockout, reset, and archive.')
} finally {
  if (jobId) await admin.from('jobs').delete().eq('id', jobId)
  if (orderId) await admin.from('orders').delete().eq('id', orderId)
  if (requestId) await admin.from('service_requests').delete().eq('id', requestId)
  if (customerId) await admin.from('customers').delete().eq('id', customerId)
  if (riderId) await admin.auth.admin.deleteUser(riderId)
  if (rosterId) await admin.from('company_riders').delete().eq('id', rosterId)
  if (evidencePaths.length) await admin.storage.from('rider-evidence').remove(evidencePaths)
  if (managerId) await admin.auth.admin.deleteUser(managerId)
  if (partnerId) await admin.from('logistics_partners').delete().eq('id', partnerId)
  for (const id of [jobId, orderId, requestId, customerId, riderId, rosterId, partnerId]) {
    if (id) await admin.from('audit_logs').delete().eq('entity_id', id)
  }
  if (managerId) await admin.from('audit_logs').delete().eq('actor_id', managerId)
}
