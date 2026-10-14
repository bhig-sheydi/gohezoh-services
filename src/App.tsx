import { useCallback, useEffect, useId, useState, type ChangeEvent, type FormEvent } from 'react'
import type { Session } from '@supabase/supabase-js'
import { getSupabaseClient } from './lib/supabase'
import WarehouseConsole from './WarehouseConsole'
import { ParcelMeasureFields, ParcelWeightField } from './ParcelLimitFields'
import { assessParcelCapacity } from './lib/parcel-capacity'
import { weightInKilograms } from './lib/weight'
import AdminConsole from './AdminConsole'
import StaffAccessPanel from './StaffAccessPanel'
import { BDOMarketersPanel } from './BDOMarketersPanel'
import { MarketerPortal } from './MarketerPortal'
import { CustomerQuotePanel, PartnerBidQueue } from './QuotePanels'
import ProximityPanel from './ProximityPanel'
import { requestPosition, type PositionFix } from './lib/proximity'
import PortHarcourtHubPanel from './PortHarcourtHubPanel'
import BdoTransparencyPanel from './BdoTransparencyPanel'
import { CommissionPlansPanel } from './CommissionPlansPanel'
import { MarketerCommissionPlansPanel } from './MarketerCommissionPlansPanel'
import { BdoMarketerSharePlansPanel } from './BdoMarketerSharePlansPanel'
import { CommissionPayoutPanel } from './CommissionPayoutPanel'
import { PartnerInvitationClaim, PartnerOrganizationPanel } from './PartnerOrganizationPanel'
import InternalExceptionInbox from './InternalExceptionInbox'
import ParcelIdentifiers, { type ParcelIdentifier } from './ParcelIdentifiers'
import ParcelPalsPanel, { type ParcelDestination, type ParcelPalContact } from './ParcelPalsPanel'
import CustomerSavedParcels, { type SavedParcel } from './CustomerSavedParcels'
import { PARCEL_LIMITS, PARCEL_MAX_QUANTITY } from './lib/parcel-limits'
import './App.css'
import './dark.css'

type Customer = { id: string; company_name: string; status: string }
type DeliveryRequest = {
  id: string
  request_number: string
  status: string
  pickup_city: string
  delivery_city: string
  recipient_name: string
  created_at: string
  order_number?: string
  job_number?: string
  job_status?: string
  parcels?: ParcelIdentifier[]
  job_history?: Array<{ status: string; changed_at: string }>
  proofs?: Array<{ storage_path: string; signed_url: string; created_at: string; recipient_name: string | null }>
  customer_price?: number | null
  customer_currency?: string
  payments?: Array<{ payment_number: string; amount: number; currency: string; method: string; received_at: string; status: string }>
}
type JobProgress = { id: string; job_number: string; status: string; customer_id: string; customer_name?: string; partner_id: string | null; partner_name?: string; route_id: string | null; pickup_city: string; delivery_city: string; updated_at: string }
type DeliveryRoute = { id: string; route_number: string; route_name: string; origin_city: string; destination_city: string; partner_id: string | null; is_active: boolean }
type LogisticsPartner = { id: string; partner_number: string; partner_name: string; status: string }
const jobProgressSteps = ['order_confirmed', 'partner_assigned', 'pickup_scheduled', 'picked_up', 'in_transit', 'out_for_delivery', 'delivered', 'closed']
const jobStatusLabels: Record<string, string> = {
  order_confirmed: 'Order confirmed', partner_assigned: 'Partner assigned', pickup_scheduled: 'Pickup scheduled',
  picked_up: 'Picked up', in_transit: 'In transit', out_for_delivery: 'Out for delivery', delivered: 'Delivered',
  exception: 'Needs attention', closed: 'Completed', cancelled: 'Cancelled',
}
const formatStatus = (status: string) => jobStatusLabels[status] ?? status.replaceAll('_', ' ')
const requestStatusLabels: Record<string, string> = { submitted: 'Received', under_review: 'Under review', approved: 'Approved', rejected: 'Not accepted', converted: 'Order confirmed', cancelled: 'Cancelled' }
const formatRequestStatus = (status: string) => requestStatusLabels[status] ?? status.replaceAll('_', ' ')
const siteUrl = 'https://gohezoh-services.vercel.app/'
const publicAppOrigin = (import.meta.env.VITE_PUBLIC_APP_URL || siteUrl).replace(/\/+$/, '')
type Service = { id: string; code: string; name: string; description: string | null }
type CoverageLocation = { id: string; name: string; state: string | null; is_enabled: boolean }
type CoverageCorridor = { id: string; origin_id: string; destination_id: string; service_code: string; is_enabled: boolean }
type QuoteWindow = { request_id: string; deadline_at: string; status: string }
type CustomerNotification = { id: string; job_id: string | null; event_type: string; title: string; body: string; created_at: string; read_at: string | null; payload: Record<string, unknown> }
type FinanceJob = {
  id: string
  job_number: string
  status: string
  customer_id: string
  partner_id: string | null
  customer_name?: string
  partner_name?: string
  financials?: { customer_revenue: number; partner_cost: number; other_direct_cost: number; currency: string }
  payments: Array<{ id: string; job_id: string; payment_number: string; amount: number; currency: string; method: string; reference: string | null; received_at: string; status: string; reversal_reason: string | null }>
  settlements: Array<{ id: string; job_id: string; settlement_number: string; amount: number; currency: string; status: string; request_reference: string; reference: string | null; created_by: string; approved_by: string | null }>
}
type FinanceTotal = { currency: string; customer_revenue: number; received: number; outstanding: number; partner_cost: number; direct_cost: number; gross_profit: number; settlements_due: number }

function App() {
  const [theme, setTheme] = useState<'light' | 'dark'>(() => {
    try {
      const stored = window.localStorage.getItem('gohezoh-theme')
      if (stored === 'light' || stored === 'dark') return stored
      return window.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'
    } catch { return 'light' }
  })
  useEffect(() => {
    document.documentElement.dataset.theme = theme
    document.querySelector('meta[name="theme-color"]')?.setAttribute('content', theme === 'dark' ? '#101a19' : '#f4f6ef')
    try { window.localStorage.setItem('gohezoh-theme', theme) } catch { /* The theme still works for this visit. */ }
  }, [theme])
  const supabase = getSupabaseClient()
  const [session, setSession] = useState<Session | null>(null)
  const [authReady, setAuthReady] = useState(false)
  const [roles, setRoles] = useState<string[]>([])
  const [rolesForUserId, setRolesForUserId] = useState('')
  const [workspace, setWorkspace] = useState<'account' | 'operations' | 'finance' | 'bdo' | 'warehouse' | 'staff' | 'marketer'>('account')
  const [recovery, setRecovery] = useState(false)
  const [customer, setCustomer] = useState<Customer | null>(null)
  const [loadingProfile, setLoadingProfile] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [requests, setRequests] = useState<DeliveryRequest[]>([])
  const [notifications, setNotifications] = useState<CustomerNotification[]>([])
  const [services, setServices] = useState<Service[]>([])
  const [coverageLocations, setCoverageLocations] = useState<CoverageLocation[]>([])
  const [coverageCorridors, setCoverageCorridors] = useState<CoverageCorridor[]>([])
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session)
      if (data.session && new URLSearchParams(window.location.search).get('setup') === '1') setRecovery(true)
      setAuthReady(true)
    })
    const { data: { subscription } } = supabase.auth.onAuthStateChange((event, nextSession) => {
      setSession(nextSession)
      if (event === 'PASSWORD_RECOVERY') setRecovery(true)
      if (nextSession && new URLSearchParams(window.location.search).get('setup') === '1') setRecovery(true)
      if (event === 'SIGNED_OUT') {
        setRecovery(false)
        setCustomer(null)
        setRequests([])
        setNotifications([])
        setRoles([])
        setRolesForUserId('')
      }
    })
    return () => subscription.unsubscribe()
  }, [supabase])

  useEffect(() => {
    if (!session?.user) return

    let active = true
    const refresh = () => { void supabase.from('user_roles').select('role').eq('user_id', session.user.id)
      .then(({ data, error: roleError }) => {
        if (!active) return
        if (roleError) setError(roleError.message)
        const nextRoles = (data ?? []).map((entry) => String(entry.role)).sort()
        setRoles((current) => current.length === nextRoles.length && current.every((role, index) => role === nextRoles[index]) ? current : nextRoles)
        setRolesForUserId(session.user.id)
      }) }
    refresh()
    const timer = window.setInterval(refresh, 30000)
    window.addEventListener('focus', refresh)

    return () => { active = false; window.clearInterval(timer); window.removeEventListener('focus', refresh) }
  }, [session, supabase])

  const loadCustomer = useCallback(async () => {
    if (!session?.user) return
    setLoadingProfile(true)
    setError('')
    const { data: existingMembership, error: membershipError } = await supabase
      .from('customer_users').select('customer_id').eq('user_id', session.user.id).maybeSingle()
    if (membershipError) {
      setError(membershipError.message)
      setLoadingProfile(false)
      return
    }
    let membership = existingMembership
    if (!membership && roles.includes('customer') && session.user.user_metadata?.phone) {
      const { data: createdCustomerId, error: createError } = await supabase.rpc('ensure_customer_profile')
      if (createError) setError(createError.message)
      else if (createdCustomerId) membership = { customer_id: String(createdCustomerId) }
    }
    if (!membership) {
      setCustomer(null)
      setLoadingProfile(false)
      return
    }
    const [{ data: customerData, error: customerError }, { data: requestData, error: requestError }, { data: serviceData }, { data: notificationData, error: notificationError }, { data: locationData, error: locationError }, { data: corridorData, error: corridorError }] = await Promise.all([
      supabase.from('customers').select('id, company_name, status').eq('id', membership.customer_id).single(),
      supabase.from('service_requests').select('id, request_number, status, pickup_city, delivery_city, recipient_name, created_at').eq('customer_id', membership.customer_id).order('created_at', { ascending: false }).limit(20),
      supabase.from('services').select('id, code, name, description').eq('is_active', true).in('code', ['SRV-0001', 'SRV-0002']).order('name'),
      supabase.from('notifications').select('id, job_id, event_type, title, body, created_at, read_at, payload').eq('user_id', session.user.id).order('created_at', { ascending: false }).limit(30),
      supabase.from('coverage_locations').select('id, name, state, is_enabled').eq('is_enabled', true).order('name'),
      supabase.from('coverage_corridors').select('id, origin_id, destination_id, service_code, is_enabled').eq('is_enabled', true),
    ])
    if (customerError) setError(customerError.message)
    else setCustomer(customerData)
    if (requestError) setError(requestError.message)
    else {
      const requestRows = requestData ?? []
      const { data: orders, error: ordersError } = requestRows.length
        ? await supabase.from('orders').select('service_request_id, order_number, customer_price, currency, jobs(id, job_number, status, job_status_history(new_status, changed_at), proof_of_delivery(storage_path, created_at, recipient_name), job_parcels(tracking_code, parcel_number, description, quantity))').in('service_request_id', requestRows.map((request) => request.id))
        : { data: [], error: null }
      if (ordersError) setError(ordersError.message)
      const orderReferences = new Map<string, { order_number: string; customer_price: number | null; customer_currency: string; job_id?: string; job_number?: string; job_status?: string; job_history?: Array<{ status: string; changed_at: string }>; parcels?: ParcelIdentifier[]; proofs?: Array<{ storage_path: string; created_at: string; recipient_name: string | null }>; payments?: DeliveryRequest['payments'] }>()
      for (const order of (orders ?? []) as unknown as Array<{ service_request_id: string; order_number: string; customer_price: number | null; currency: string; jobs: { id: string; job_number: string; status: string; job_status_history: Array<{ new_status: string; changed_at: string }>; proof_of_delivery: Array<{ storage_path: string; created_at: string; recipient_name: string | null }>; job_parcels: ParcelIdentifier[] } | Array<{ id: string; job_number: string; status: string; job_status_history: Array<{ new_status: string; changed_at: string }>; proof_of_delivery: Array<{ storage_path: string; created_at: string; recipient_name: string | null }>; job_parcels: ParcelIdentifier[] } | null> | null }>) {
        const job = Array.isArray(order.jobs) ? order.jobs[0] : order.jobs
        orderReferences.set(order.service_request_id, { order_number: order.order_number, customer_price: order.customer_price, customer_currency: order.currency, job_id: job?.id, job_number: job?.job_number, job_status: job?.status, job_history: job?.job_status_history?.map((event) => ({ status: event.new_status, changed_at: event.changed_at })), parcels: job?.job_parcels, proofs: job?.proof_of_delivery })
      }
      const customerJobIds = [...new Set([...orderReferences.values()].flatMap((reference) => reference.job_id ? [reference.job_id] : []))]
      const { data: receiptRows, error: receiptsError } = customerJobIds.length ? await supabase.rpc('list_my_customer_payments') : { data: [], error: null }
      if (receiptsError) setError(receiptsError.message)
      const receiptsByJob = new Map<string, NonNullable<DeliveryRequest['payments']>>()
      for (const receipt of (receiptRows ?? []) as Array<NonNullable<DeliveryRequest['payments']>[number] & { job_id: string }>) receiptsByJob.set(receipt.job_id, [...(receiptsByJob.get(receipt.job_id) ?? []), receipt])
      for (const reference of orderReferences.values()) if (reference.job_id) reference.payments = receiptsByJob.get(reference.job_id) ?? []
      const paths = [...new Set([...orderReferences.values()].flatMap((reference) => reference.proofs?.map((proof) => proof.storage_path) ?? []))]
      const { data: signedRows, error: signedError } = paths.length
        ? await supabase.storage.from('proof-of-delivery').createSignedUrls(paths, 300)
        : { data: [], error: null }
      if (signedError) setError(signedError.message)
      const signedByPath = new Map((signedRows ?? []).flatMap((row) => row.signedUrl ? [[row.path, row.signedUrl] as const] : []))
      setRequests(requestRows.map((request) => {
        const reference = orderReferences.get(request.id)
        return { ...request, ...reference, proofs: reference?.proofs?.flatMap((proof) => {
          const signedUrl = signedByPath.get(proof.storage_path)
          return signedUrl ? [{ ...proof, signed_url: signedUrl }] : []
        }) }
      }))
    }
    if (notificationError) setError(notificationError.message)
    else setNotifications((notificationData ?? []) as CustomerNotification[])
    setServices(serviceData ?? [])
    if (locationError || corridorError) setError((locationError ?? corridorError)?.message ?? 'Could not load service coverage.')
    else { setCoverageLocations((locationData ?? []) as CoverageLocation[]); setCoverageCorridors((corridorData ?? []) as CoverageCorridor[]) }
    setLoadingProfile(false)
  }, [roles, session, supabase])

  useEffect(() => {
    const timer = window.setTimeout(() => { void loadCustomer() }, 0)
    return () => window.clearTimeout(timer)
  }, [loadCustomer])

  async function submitProfile(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!session) return
    const form = new FormData(event.currentTarget)
    setBusy(true); setError(''); setNotice('')
    const { error: rpcError } = await supabase.rpc('register_customer_profile', {
      p_company_name: String(form.get('company_name') || session.user.user_metadata?.company_name || session.user.user_metadata?.full_name || session.user.email?.split('@')[0] || 'Customer'),
      p_customer_type: String(form.get('customer_type') || 'individual'),
      p_contact_person: String(form.get('contact_person') || session.user.user_metadata?.full_name || session.user.email?.split('@')[0] || 'Customer'),
      p_email: session.user.email ?? '',
      p_phone: String(form.get('phone') || session.user.user_metadata?.phone || ''),
      p_address: String(form.get('address') || ''),
      p_city: String(form.get('city') || ''),
      p_state: String(form.get('state') || ''),
    })
    if (rpcError) setError(rpcError.message)
    else { setNotice('Your customer profile is ready. You can now send a delivery request.'); await loadCustomer() }
    setBusy(false)
  }

  async function submitRequest(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!session || !customer) return
    const formElement = event.currentTarget
    const form = new FormData(formElement)
    if (!form.get('recipient_location_confirmed')) { setError('Confirm the recipient has agreed to this delivery location before you submit.'); return }
    setBusy(true); setError(''); setNotice('')
    let weightKg: number | null
    try { weightKg = weightInKilograms(form.get('parcel_weight'), String(form.get('parcel_weight_unit'))) }
    catch (error) { setError((error as Error).message); setBusy(false); return }
    if (weightKg !== null && weightKg > PARCEL_LIMITS.weightKg) { setError(`Parcel weight must not exceed ${PARCEL_LIMITS.weightKg} kg.`); setBusy(false); return }
    const parcelQuantity = Number(form.get('parcel_quantity'))
    const parcelDimensions = {
      length: Number(form.get('parcel_length_cm')),
      width: Number(form.get('parcel_width_cm')),
      height: Number(form.get('parcel_height_cm')),
      weight: weightKg ?? 0,
    }
    const capacity = assessParcelCapacity(parcelQuantity, parcelDimensions)
    if (!Number.isInteger(parcelQuantity) || parcelQuantity < 1 || parcelQuantity > PARCEL_MAX_QUANTITY || !capacity.ready || !capacity.fitsWeight || !capacity.fitsDimensions) {
      setError(!capacity.fitsWeight ? 'The selected item count exceeds the total weight capacity. Reduce the count or per-item weight.' : 'The selected item count does not fit within the shipment size limits. Reduce the count or per-item size.')
      setBusy(false)
      return
    }
    const preferred = String(form.get('preferred_pickup_at') || '')
    const parcelItem: Record<string, string | number | null> = {
      description: String(form.get('parcel_description')).trim(),
      quantity: Number(form.get('parcel_quantity')),
      weight_kg: weightKg,
    }
    for (const [formName, parcelName] of [['parcel_length_cm','length_cm'],['parcel_width_cm','width_cm'],['parcel_height_cm','height_cm'],['parcel_declared_value','declared_value'],['parcel_price','price']] as const) {
      const value = String(form.get(formName) ?? '').trim()
      if (value) parcelItem[parcelName] = Number(value)
    }
    const { error: requestError } = await supabase.from('service_requests').insert({
      customer_id: customer.id,
      service_id: String(form.get('service_id')),
      created_by: session.user.id,
      pickup_address: String(form.get('pickup_address')),
      pickup_city: String(form.get('pickup_city')),
      pickup_state: String(form.get('pickup_state') || '') || null,
      sender_name: String(form.get('sender_name')),
      sender_phone: String(form.get('sender_phone')),
      delivery_address: String(form.get('delivery_address')),
      delivery_city: String(form.get('delivery_city')),
      delivery_state: String(form.get('delivery_state') || '') || null,
      recipient_name: String(form.get('recipient_name')),
      recipient_phone: String(form.get('recipient_phone')),
      recipient_phone_secondary: String(form.get('recipient_phone_secondary') || '') || null,
      preferred_pickup_at: preferred ? new Date(preferred).toISOString() : null,
      parcel_summary: String(form.get('parcel_description')).trim(),
      parcel_items: [parcelItem],
      special_instructions: String(form.get('special_instructions') || '') || null,
    })
    if (requestError) setError(requestError.message)
    else { setNotice('Delivery request submitted. Kwik-Parsel operations will review it and publish it for partner quotes.'); formElement.reset(); await loadCustomer() }
    setBusy(false)
  }

  async function updatePassword(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const form = new FormData(event.currentTarget)
    const password = String(form.get('password'))
    if (password !== String(form.get('confirm_password'))) { setError('Those passwords do not match.'); return }
    setBusy(true); setError('')
    const { error: updateError } = await supabase.auth.updateUser({ password })
    if (updateError) setError(updateError.message)
    else { setRecovery(false); window.history.replaceState({}, '', window.location.pathname); setNotice('Password updated. You are signed in.') }
    setBusy(false)
  }

  async function signOut() { await supabase.auth.signOut() }

  async function markNotificationRead(notification: CustomerNotification) {
    if (notification.read_at) return
    const { data, error: readError } = await supabase.rpc('mark_customer_notification_read', { p_notification_id: notification.id })
    if (readError) setError(readError.message)
    else setNotifications((current) => current.map((item) => item.id === notification.id ? { ...item, read_at: String(data) } : item))
  }

  const operationsAccess = roles.some((role) => ['operations', 'admin', 'management'].includes(role))
  const financeAccess = roles.some((role) => ['finance', 'admin', 'management'].includes(role))
  const bdoAccess = roles.some((role) => ['bdo', 'admin', 'management'].includes(role))
  const warehouseAccess = roles.some((role) => ['warehouse','operations','admin','management'].includes(role))
  const customerAccess = roles.includes('customer')
  const marketerAccess = roles.includes('marketer')
  const customerInventoryAccess = customerAccess && !roles.some((role)=>['warehouse','operations','partner','finance','admin','management','bdo'].includes(role))
  // The admin role is granted and revoked through the staff approval controls.
  // Keep the frontend aligned with the database authorization check instead of
  // maintaining a separate, stale email allowlist here.
  const superAdmin = roles.includes('admin')
  const adminScreen = superAdmin && workspace === 'account'
  const operationsScreen = workspace === 'operations' && operationsAccess || workspace === 'account' && !superAdmin && operationsAccess
  const partnerAccess = roles.includes('partner')
  const partnerScreen = workspace === 'account' && partnerAccess && !operationsAccess
  const customerScreen = workspace === 'account' && customerAccess && !partnerAccess && !operationsAccess && !financeAccess && !bdoAccess && !roles.includes('warehouse')
  const financeScreen = workspace === 'finance' && financeAccess || workspace === 'account' && financeAccess && !operationsAccess
  const bdoScreen = workspace === 'bdo' && bdoAccess || workspace === 'account' && bdoAccess && !financeAccess && !operationsAccess && !partnerAccess
  const marketerScreen = (workspace === 'marketer' || workspace === 'account') && marketerAccess && !bdoAccess && !financeAccess && !operationsAccess && !partnerAccess
  const warehouseScreen = workspace === 'warehouse' && (warehouseAccess || customerInventoryAccess) || workspace === 'account' && roles.includes('warehouse') && !financeAccess && !operationsAccess && !partnerAccess && !roles.includes('bdo')
  const emailNotice = !error && /check your email|verification code is on its way/i.test(notice)

  return (
    <main className={`app-shell ${customerScreen ? 'customer-shell' : ''}`}>
      <header className="topbar">
        <a className="brand" href="/" aria-label="Kwik-Parsel by Gohezo Integrated Services"><span className="brand-mark">K</span><span><strong>KWIK-PARSEL</strong><small>BY GOHEZO</small></span></a>
        <div className="topbar-actions"><button type="button" className="theme-toggle" aria-label={theme === 'dark' ? 'Switch to light mode' : 'Switch to dark mode'} aria-pressed={theme === 'dark'} onClick={() => setTheme((current) => current === 'dark' ? 'light' : 'dark')}><span aria-hidden="true">◐</span><span className="theme-toggle-label">{theme === 'dark' ? 'Light mode' : 'Dark mode'}</span></button>{session && <div className="signed-in">{superAdmin && workspace !== 'account' && <button className="text-button" onClick={() => setWorkspace('account')}>Super Admin</button>}{operationsAccess && !operationsScreen && <button className="text-button" onClick={() => setWorkspace('operations')}>Operations</button>}{financeAccess && !financeScreen && <button className="text-button" onClick={() => setWorkspace('finance')}>Finance</button>}{bdoAccess && !bdoScreen && <button className="text-button" onClick={() => setWorkspace('bdo')}>Business Development</button>}{warehouseAccess && !warehouseScreen && <button className="text-button" onClick={() => setWorkspace('warehouse')}>Warehouse</button>}{customerAccess && !superAdmin && workspace !== 'staff' && <button className="text-button" onClick={() => setWorkspace('staff')}>Request staff access</button>}{customerInventoryAccess && !warehouseScreen && <button className="text-button" onClick={() => setWorkspace('warehouse')}>Inventory & fulfillment</button>}{!superAdmin && workspace !== 'account' && <button className="text-button" onClick={() => setWorkspace('account')}>Back to portal</button>}<span>{session.user.email}</span><button className="text-button" onClick={signOut}>Sign out</button></div>}</div>
      </header>

      {session && rolesForUserId === session.user.id && roles.some((role) => ['operations', 'management', 'admin'].includes(role)) && <InternalExceptionInbox supabase={supabase} userId={session.user.id} onError={setError} />}
      {!authReady ? <div className="loading">Preparing your secure workspace...</div> : !session ? <AuthPanel supabase={supabase} onError={setError} onNotice={setNotice} busy={busy} setBusy={setBusy} /> : rolesForUserId !== session.user.id ? <div className="loading">Checking your account access...</div> : recovery ? <section className="form-card narrow"><p className="eyebrow">ACCOUNT SECURITY</p><h1>Choose a new password</h1><form className="form-grid" onSubmit={updatePassword}><Field label="New password" name="password" type="password" minLength={8} required /><Field label="Confirm password" name="confirm_password" type="password" minLength={8} required /><button className="primary-button" disabled={busy}>{busy ? 'Saving...' : 'Update password'}</button></form></section> : adminScreen ? <AdminConsole supabase={supabase} onError={setError} onNotice={setNotice} /> : workspace === 'staff' ? <StaffAccessPanel supabase={supabase} userId={session.user.id} onError={setError} onNotice={setNotice} /> : marketerScreen ? <MarketerPortal supabase={supabase} onError={setError} /> : warehouseScreen ? <WarehouseConsole supabase={supabase} isCustomer={roles.includes('customer')&&!roles.some((role)=>['warehouse','operations','admin','management'].includes(role))} canReceive={warehouseAccess} canPick={roles.some((role)=>['warehouse','management','admin'].includes(role))} canRelease={operationsAccess} canManage={roles.some((role)=>['admin','management'].includes(role))} onError={setError} onNotice={setNotice}/> : bdoScreen ? <BusinessDevelopmentConsole supabase={supabase} userId={session.user.id} canManage={roles.some((role) => ['management','admin'].includes(role))} isBdo={roles.includes('bdo')} onError={setError} onNotice={setNotice} /> : financeScreen ? <FinanceConsole supabase={supabase} userId={session.user.id} canRecord={financeAccess} canApprove={roles.some((role) => ['management','admin'].includes(role))} canPay={financeAccess} onError={setError} onNotice={setNotice} /> : operationsScreen ? <OperationsConsole supabase={supabase} onError={setError} onNotice={setNotice} canUpdateJobs={operationsAccess} /> : partnerScreen ? <PartnerPortal supabase={supabase} userId={session.user.id} canRespond={partnerAccess} onError={setError} onNotice={setNotice} /> : !customerScreen ? <StaffAccessPanel supabase={supabase} userId={session.user.id} onError={setError} onNotice={setNotice} /> : loadingProfile && !customer ? <div className="loading">Loading your customer workspace...</div> : !customer ? <section className="form-card narrow"><p className="eyebrow">CUSTOMER SETUP</p><h1>Finish account setup.</h1><p className="section-intro">Your name and email come from signup. Add the phone number needed for delivery coordination; you can enter pickup and delivery addresses with each request.</p><form className="form-grid" onSubmit={submitProfile}><Field label="Phone number" name="phone" type="tel" defaultValue={session.user.user_metadata?.phone || ""} required /><Field label="Business name (optional)" name="company_name" defaultValue={session.user.user_metadata?.company_name || ""} /><button className="primary-button" disabled={busy}>{busy ? 'Saving profile...' : 'Finish setup'}</button></form></section> : <Dashboard supabase={supabase} userId={session.user.id} onError={setError} onNotice={setNotice} customer={customer} services={services} coverageLocations={coverageLocations} coverageCorridors={coverageCorridors} requests={requests} notifications={notifications} busy={busy} onSubmit={submitRequest} onMarkRead={markNotificationRead} onRefresh={loadCustomer} />}
      {session && !superAdmin && <PartnerInvitationClaim supabase={supabase} onError={setError} onNotice={setNotice} onApplicationRequired={() => setWorkspace('staff')} />}
      {(error || notice) && <div className={`toast ${error ? 'toast-error' : 'toast-success'} ${emailNotice ? 'toast-email' : ''}`} role={error ? 'alert' : 'status'}>{emailNotice && <span className="toast-email-icon" aria-hidden="true"><svg viewBox="0 0 24 24" focusable="false"><rect x="3" y="5" width="18" height="14" rx="2"/><path d="m4 7 8 6 8-6"/></svg></span>}<div className="toast-copy">{emailNotice && <strong>Check your email</strong>}<span>{error || notice}</span></div><button type="button" onClick={() => { setError(''); setNotice('') }} aria-label="Dismiss message"><svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M5 5 19 19M19 5 5 19"/></svg></button></div>}
      <footer className="page-footer"><span>KWIK-PARSEL IS A PRODUCT OF GOHEZO INTEGRATED SERVICES LTD.</span><span>LOGISTICS  |  FULFILLMENT  |  PARTNERSHIP</span></footer>
    </main>
  )
}

type OperationsRequest = {
  id: string
  request_number: string
  status: string
  pickup_address: string
  pickup_city: string
  pickup_state: string | null
  sender_name: string
  sender_phone: string
  delivery_address: string
  delivery_city: string
  delivery_state: string | null
  recipient_name: string
  recipient_phone: string
  recipient_phone_secondary?: string | null
  preferred_pickup_at: string | null
  parcel_summary: string | null
  special_instructions: string | null
  created_at: string
  customer: { company_name: string; customer_number: string; status: string } | null
  service: { name: string; code: string } | null
}

function OperationsConsole({ supabase, onError, onNotice, canUpdateJobs }: {
  supabase: ReturnType<typeof getSupabaseClient>
  onError: (message: string) => void
  onNotice: (message: string) => void
  canUpdateJobs: boolean
}) {
  const [requests, setRequests] = useState<OperationsRequest[]>([])
  const [selectedId, setSelectedId] = useState('')
  const [customerPrice, setCustomerPrice] = useState('')
  const [operationsNote, setOperationsNote] = useState('')
  const [jobs, setJobs] = useState<JobProgress[]>([])
  const [partners, setPartners] = useState<LogisticsPartner[]>([])
  const [routes, setRoutes] = useState<DeliveryRoute[]>([])
  const [routeSelections, setRouteSelections] = useState<Record<string,string>>({})
  const [routeBusy, setRouteBusy] = useState(false)
  const [partnerSelections, setPartnerSelections] = useState<Record<string, string>>({})
  const [partnerFormBusy, setPartnerFormBusy] = useState(false)
  const [jobStatusBusy, setJobStatusBusy] = useState(false)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const selected = requests.find((request) => request.id === selectedId) ?? null
  const [quoteWindows, setQuoteWindows] = useState<QuoteWindow[]>([])
  const [deliveryQuotes, setDeliveryQuotes] = useState<Array<{ request_id: string; status: string; unrounded_price_ngn: number | null; customer_price_ngn: number | null }>>([])
  const [tieBids, setTieBids] = useState<Array<{ id: string; request_id: string; amount_ngn: number; partner_id: string; status: string }>>([])

  const loadQuoteState = useCallback(async () => {
    const [windowResult, quoteResult, bidResult] = await Promise.all([
      supabase.from('delivery_quote_windows').select('request_id, deadline_at, status').order('published_at', { ascending: false }).limit(100),
      supabase.from('customer_delivery_quotes').select('request_id, status, unrounded_price_ngn, customer_price_ngn').limit(100),
      supabase.from('partner_quotes').select('id, request_id, amount_ngn, partner_id, status').order('amount_ngn').limit(100),
    ])
    if (windowResult.error || quoteResult.error || bidResult.error) onError((windowResult.error ?? quoteResult.error ?? bidResult.error)?.message ?? 'Could not load quote status.')
    else { setQuoteWindows((windowResult.data ?? []) as QuoteWindow[]); setDeliveryQuotes((quoteResult.data ?? []) as typeof deliveryQuotes); setTieBids((bidResult.data ?? []) as typeof tieBids) }
  }, [supabase, onError])

  useEffect(() => { const timer = window.setTimeout(() => { void loadQuoteState() }, 0); return () => clearTimeout(timer) }, [loadQuoteState])

  async function publishSelected() {
    if (!selected || busy) return
    setBusy(true)
    const { error } = await supabase.rpc('publish_delivery_request', { p_request_id: selected.id })
    if (error) onError(error.message)
    else { onNotice(`${selected.request_number} is open for private partner quotes.`); await loadQuoteState() }
    setBusy(false)
  }
  async function closeQuoteWindow(requestId: string) {
    setBusy(true)
    const { error } = await supabase.rpc('close_delivery_quote_window', { p_request_id: requestId })
    if (error) onError(error.message)
    else { onNotice('Quote window closed and bids evaluated.'); await loadQuoteState() }
    setBusy(false)
  }
  async function resolveTie(event: FormEvent<HTMLFormElement>, requestId: string) {
    event.preventDefault()
    const form = new FormData(event.currentTarget)
    setBusy(true)
    const { error } = await supabase.rpc('resolve_delivery_quote_tie', { p_request_id: requestId, p_winning_bid_id: String(form.get('winning_bid_id')), p_reason: String(form.get('reason')).trim() })
    if (error) onError(error.message)
    else { onNotice('Tie resolved with an audit reason.'); await loadQuoteState() }
    setBusy(false)
  }
  async function reopenWindow(event: FormEvent<HTMLFormElement>, requestId: string) {
    event.preventDefault()
    const form = new FormData(event.currentTarget)
    setBusy(true)
    const { error } = await supabase.rpc('reopen_delivery_quote_window', { p_request_id: requestId, p_reason: String(form.get('reason')).trim() })
    if (error) onError(error.message)
    else { onNotice('Bidding reopened for two hours.'); await loadQuoteState() }
    setBusy(false)
  }

  const loadRequests = useCallback(async () => {
    setLoading(true)
    const { data, error } = await supabase
      .from('service_requests')
      .select('id, request_number, status, pickup_address, pickup_city, pickup_state, sender_name, sender_phone, delivery_address, delivery_city, delivery_state, recipient_name, recipient_phone, recipient_phone_secondary, preferred_pickup_at, parcel_summary, special_instructions, created_at, customer:customers!service_requests_customer_id_fkey(company_name, customer_number, status), service:services!service_requests_service_id_fkey(name, code)')
      .in('status', ['submitted', 'under_review'])
      .order('created_at', { ascending: true })

    if (error) onError(error.message)
    else {
      const queue = (data ?? []) as unknown as OperationsRequest[]
      setRequests(queue)
      setSelectedId((current) => queue.some((request) => request.id === current) ? current : queue[0]?.id ?? '')
    }
    setLoading(false)
  }, [onError, supabase])

  const loadJobs = useCallback(async () => {
    const { data, error } = await supabase.from('jobs')
      .select('id, job_number, status, customer_id, partner_id, route_id, pickup_city, delivery_city, updated_at')
      .not('status', 'in', '(closed,cancelled)')
      .order('updated_at', { ascending: false })
      .limit(50)
    if (error) onError(error.message)
    else {
      const jobRows = (data ?? []) as unknown as JobProgress[]
      const customerIds = [...new Set(jobRows.map((job) => job.customer_id))]
      const partnerIds = [...new Set(jobRows.map((job) => job.partner_id).filter((id): id is string => Boolean(id)))]
      const [{ data: customers, error: customersError }, { data: assignedPartners, error: partnersError }] = await Promise.all([
        customerIds.length ? supabase.from('customers').select('id, company_name').in('id', customerIds) : Promise.resolve({ data: [], error: null }),
        partnerIds.length ? supabase.from('logistics_partners').select('id, partner_name').in('id', partnerIds) : Promise.resolve({ data: [], error: null }),
      ])
      if (customersError) onError(customersError.message)
      if (partnersError) onError(partnersError.message)
      const names = new Map((customers ?? []).map((customer) => [customer.id, customer.company_name]))
      const partnerNames = new Map((assignedPartners ?? []).map((partner) => [partner.id, partner.partner_name]))
      setJobs(jobRows.map((job) => ({ ...job, customer_name: names.get(job.customer_id), partner_name: job.partner_id ? partnerNames.get(job.partner_id) : undefined })))
    }
  }, [onError, supabase])

  const loadPartners = useCallback(async () => {
    const { data, error } = await supabase.from('logistics_partners').select('id, partner_number, partner_name, status').eq('status', 'active').order('partner_name')
    if (error) onError(error.message)
    else setPartners((data ?? []) as LogisticsPartner[])
  }, [onError, supabase])

  const loadRoutes = useCallback(async () => {
    const {data,error}=await supabase.from('routes').select('id,route_number,route_name,origin_city,destination_city,partner_id,is_active').eq('is_active',true).order('route_name')
    if(error)onError(error.message)
    else setRoutes((data??[]) as DeliveryRoute[])
  },[onError,supabase])

  useEffect(() => {
    const timer = window.setTimeout(() => { void loadRequests() }, 0)
    return () => window.clearTimeout(timer)
  }, [loadRequests])

  useEffect(() => {
    const timer = window.setTimeout(() => { void loadJobs() }, 0)
    return () => window.clearTimeout(timer)
  }, [loadJobs])

  useEffect(() => {
    const timer = window.setTimeout(() => { void loadPartners() }, 0)
    return () => window.clearTimeout(timer)
  }, [loadPartners])
  useEffect(() => {
    const timer = window.setTimeout(() => { void loadRoutes() }, 0)
    return () => window.clearTimeout(timer)
  }, [loadRoutes])

  async function createRoute(event:FormEvent<HTMLFormElement>){
    event.preventDefault()
    if(!canUpdateJobs||routeBusy)return
    const formElement=event.currentTarget;const form=new FormData(formElement)
    setRouteBusy(true)
    const {data,error}=await supabase.rpc('create_delivery_route',{p_route_name:String(form.get('route_name')).trim(),p_origin_city:String(form.get('origin_city')).trim(),p_destination_city:String(form.get('destination_city')).trim(),p_origin_state:String(form.get('origin_state')||'').trim()||null,p_destination_state:String(form.get('destination_state')||'').trim()||null,p_partner_id:String(form.get('partner_id')||'')||null})
    if(error)onError(error.message);else{onNotice(`Route ${data?.route_number??''} created.`);formElement.reset();await loadRoutes()}
    setRouteBusy(false)
  }

  async function assignRoute(job:JobProgress){
    const routeId=routeSelections[job.id]
    if(!canUpdateJobs||routeBusy||!routeId)return
    setRouteBusy(true)
    const {data,error}=await supabase.rpc('assign_job_route',{p_job_id:job.id,p_route_id:routeId})
    if(error)onError(error.message);else{onNotice(`${job.job_number} assigned to route ${data?.route_number??''}.`);setRouteSelections((current)=>({...current,[job.id]:''}));await loadJobs()}
    setRouteBusy(false)
  }

  async function createPartner(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!canUpdateJobs || partnerFormBusy) return
    const formElement = event.currentTarget
    const form = new FormData(formElement)
    setPartnerFormBusy(true)
    const { data, error } = await supabase.rpc('create_logistics_partner', {
      p_partner_name: String(form.get('partner_name')).trim(),
      p_contact_person: String(form.get('contact_person')).trim(),
      p_phone: String(form.get('phone')).trim(),
      p_email: String(form.get('email')).trim() || null,
      p_base_city: String(form.get('base_city')).trim() || null,
      p_base_state: String(form.get('base_state')).trim() || null,
      p_service_areas: String(form.get('service_areas')).split(',').map((area) => area.trim()).filter(Boolean),
      p_portal_user_email: null,
    })
    if (error) onError(error.message)
    else {
      const result = data as { partner_number?: string; partner_name?: string }
      onNotice(`${result.partner_name ?? 'Partner'} added${result.partner_number ? ` (${result.partner_number})` : ''}.`)
      formElement.reset()
      await loadPartners()
    }
    setPartnerFormBusy(false)
  }

  async function assignPartner(job: JobProgress) {
    const partnerId = partnerSelections[job.id]
    if (!canUpdateJobs || !partnerId) return
    const { error } = await supabase.rpc('assign_job_to_partner', { p_job_id: job.id, p_partner_id: partnerId })
    if (error) onError(error.message)
    else {
      const partner = partners.find((item) => item.id === partnerId)
      onNotice(`${job.job_number} assigned to ${partner?.partner_name ?? 'partner'}.`)
      setPartnerSelections((current) => ({ ...current, [job.id]: '' }))
      await loadJobs()
    }
  }

  async function updateJobStatus(job: JobProgress, status: string) {
    if (jobStatusBusy || !canUpdateJobs) return
    setJobStatusBusy(true)
    onError('')
    const { error } = await supabase.rpc('update_job_status', { p_job_id: job.id, p_new_status: status })
    if (error) onError(error.message)
    else {
      onNotice(`${job.job_number} updated to ${formatStatus(status)}.`)
      await Promise.all([loadJobs(), loadRequests()])
    }
    setJobStatusBusy(false)
  }

  async function processRequest(action: 'start_review' | 'reject' | 'approve') {
    if (!selected || busy || !canUpdateJobs) return
    const quotedWorkflow = quoteWindows.some((window) => window.request_id === selected.id)
    const acceptedQuote = deliveryQuotes.find((quote) => quote.request_id === selected.id && quote.status === 'accepted')
    if (action === 'approve' && quotedWorkflow && !acceptedQuote) { onError('Wait for the customer to accept the final quote.'); return }
    const approvedPrice = quotedWorkflow ? acceptedQuote?.customer_price_ngn : customerPrice
    if (action === 'approve' && (approvedPrice == null || String(approvedPrice).trim() === '' || Number(approvedPrice) < 0)) {
      onError('Enter a valid customer price before confirming this request.')
      return
    }
    if (action === 'approve' && !window.confirm(`Confirm ${selected.request_number} and create its order and job?`)) return
    if (action === 'reject' && !window.confirm(`Reject ${selected.request_number}?`)) return

    setBusy(true)
    onError('')
    onNotice('')
    const { data, error } = await supabase.rpc('process_service_request', {
      p_request_id: selected.id,
      p_action: action,
      p_customer_price: action === 'approve' ? Number(approvedPrice) : null,
      p_operations_note: operationsNote.trim() || null,
    })

    if (error) onError(error.message)
    else if (action === 'approve') {
      const result = data as { order_number?: string; job_number?: string }
      onNotice(`Confirmed. Order ${result.order_number} and job ${result.job_number} were created.`)
      setCustomerPrice('')
      setOperationsNote('')
      setSelectedId('')
      await loadRequests()
    } else if (action === 'reject') {
      onNotice(`${selected.request_number} was rejected.`)
      setOperationsNote('')
      setSelectedId('')
      await loadRequests()
    } else {
      onNotice(`${selected.request_number} is now under review.`)
      await loadRequests()
    }
    setBusy(false)
  }

  return <section className="operations-page">
    <div className="dashboard-heading operations-heading">
      <div><p className="eyebrow">KWIK-PARSEL OPERATIONS</p><h1>Request desk</h1><p className="section-intro">Review incoming customer requests. Confirming a request creates its order and job together.</p></div>
      <button className="secondary-button" onClick={() => { onError(''); void loadRequests() }} disabled={loading}>Refresh queue</button>
    </div>
    <div className="operations-summary"><span className="summary-count">{requests.length}</span><div><strong>{requests.length === 1 ? 'Request awaiting review' : 'Requests awaiting review'}</strong><p>Oldest requests appear first.</p></div></div>
    {loading ? <div className="loading queue-loading">Loading requests...</div> : requests.length === 0 ? <div className="form-card queue-empty"><span className="empty-icon">OK</span><h2>Queue is clear</h2><p>No submitted requests are waiting for operations review.</p></div> : <div className="operations-grid">
      <section className="form-card queue-card" aria-label="Requests awaiting review">
        <div className="queue-card-heading"><div><p className="eyebrow">INCOMING</p><h2>Service requests</h2></div><span className="request-count">{requests.length}</span></div>
        <div className="queue-list">{requests.map((request) => <button className={`queue-row ${selectedId === request.id ? 'queue-row-selected' : ''}`} key={request.id} onClick={() => { setSelectedId(request.id); setCustomerPrice(''); setOperationsNote(''); onError(''); onNotice('') }}>
          <span className="queue-row-main"><strong>{request.request_number}</strong><span className={`request-status status-${request.status}`}>{formatRequestStatus(request.status)}</span></span>
          <span className="queue-customer">{request.customer?.company_name ?? 'Customer'}</span>
          <span className="queue-route">{request.pickup_city} <span aria-hidden="true">to</span> {request.delivery_city}</span>
          <span className="queue-service">{request.service?.name ?? 'Delivery service'}</span>
        </button>)}</div>
      </section>
      {selected && <section className="form-card review-card">
        <div className="review-title"><div><p className="eyebrow">{selected.request_number}</p><h2>Review request</h2></div><span className={`request-status status-${selected.status}`}>{formatRequestStatus(selected.status)}</span></div>
        <div className="review-facts"><div><small>CUSTOMER</small><strong>{selected.customer?.company_name ?? 'Customer'}</strong><span>{selected.customer?.customer_number ?? ''}  |  {selected.customer?.status ?? ''}</span></div><div><small>SERVICE</small><strong>{selected.service?.name ?? 'Delivery'}</strong><span>Received {new Intl.DateTimeFormat('en-NG', { dateStyle: 'medium' }).format(new Date(selected.created_at))}</span></div></div>
        <div className="review-route"><div><small>PICKUP</small><strong>{selected.sender_name}  |  {selected.sender_phone}</strong><p>{selected.pickup_address}<br />{selected.pickup_city}{selected.pickup_state ? `, ${selected.pickup_state}` : ''}</p></div><span className="review-arrow" aria-hidden="true">to</span><div><small>DELIVERY</small><strong>{selected.recipient_name}  |  {selected.recipient_phone}</strong>{selected.recipient_phone_secondary && <small>Alternate: {selected.recipient_phone_secondary}</small>}<p>{selected.delivery_address}<br />{selected.delivery_city}{selected.delivery_state ? `, ${selected.delivery_state}` : ''}</p></div></div>
        <div className="review-extras"><div><small>PARCEL</small><p>{selected.parcel_summary || 'No parcel description provided'}</p></div>{selected.preferred_pickup_at && <div><small>PREFERRED PICKUP</small><p>{new Intl.DateTimeFormat('en-NG', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(selected.preferred_pickup_at))}</p></div>}{selected.special_instructions && <div><small>SPECIAL INSTRUCTIONS</small><p>{selected.special_instructions}</p></div>}</div>
        <div className="form-divider">PARTNER QUOTES & OPERATIONS DECISION</div>
        {(() => { const window = quoteWindows.find((row) => row.request_id === selected.id); const quote = deliveryQuotes.find((row) => row.request_id === selected.id); return <><p className="section-intro">{window ? `Bid window ${window.status}. ${window.status === 'open' ? `Closes ${new Intl.DateTimeFormat('en-NG', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(window.deadline_at))}.` : ''}` : 'No partner quote window published yet.'} {quote ? `Customer quote ${quote.status.replaceAll('_', ' ')}.` : ''}</p>{!window && <button className="secondary-button" disabled={!canUpdateJobs || busy} onClick={() => void publishSelected()}>{busy ? 'Publishing...' : 'Publish for partner quotes'}</button>}</> })()}
        {quoteWindows.some((window) => window.request_id === selected.id) ? <label className="field"><span>Customer-accepted price (NGN)</span><input type="number" min="0" step="0.01" value={deliveryQuotes.find((quote) => quote.request_id === selected.id && quote.status === 'accepted')?.customer_price_ngn ?? ''} readOnly placeholder="Awaiting accepted quote" /></label> : <label className="field"><span>Customer price (NGN)</span><input type="number" min="0" step="0.01" value={customerPrice} onChange={(event) => setCustomerPrice(event.target.value)} placeholder="Enter confirmed price" /></label>}
        <label className="field review-note"><span>Operations note <small>Optional</small></span><textarea rows={3} value={operationsNote} onChange={(event) => setOperationsNote(event.target.value)} placeholder="Add a note for this decision" /></label>
        <div className="review-actions"><button className="secondary-button" onClick={() => void processRequest('start_review')} disabled={!canUpdateJobs || busy || selected.status === 'under_review'}>Start review</button><button className="reject-button" onClick={() => void processRequest('reject')} disabled={!canUpdateJobs || busy}>{busy ? 'Working...' : 'Reject'}</button><button className="primary-button" onClick={() => void processRequest('approve')} disabled={!canUpdateJobs || busy || (quoteWindows.some((window) => window.request_id === selected.id) && !deliveryQuotes.some((quote) => quote.request_id === selected.id && quote.status === 'accepted'))}>{busy ? 'Creating order...' : 'Confirm & create job'}</button></div>
        <p className="form-footnote">Confirm only after the customer accepts the final quote. Payment or approved credit is required before partner award.</p>
      </section>}
    </div>}
    <section className="history-panel"><div className="history-heading"><div><p className="eyebrow">BIDDING</p><h2>Quote windows and exceptions</h2></div><button className="secondary-button" onClick={() => void loadQuoteState()}>Refresh</button></div>{quoteWindows.length === 0 ? <p className="notification-empty">No quote windows yet.</p> : <div className="request-list">{quoteWindows.map((window) => <article className="request-item" key={window.request_id}><div className="request-item-top"><strong>{requests.find((request) => request.id === window.request_id)?.request_number ?? window.request_id}</strong><span className="request-status">{window.status.replaceAll('_', ' ')}</span></div><p>Deadline: {new Intl.DateTimeFormat('en-NG', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(window.deadline_at))}</p>{window.status === 'open' && <button className="secondary-button" disabled={busy} onClick={() => void closeQuoteWindow(window.request_id)}>Evaluate bids</button>}{window.status === 'no_bids' && <form className="form-grid" onSubmit={(event) => void reopenWindow(event, window.request_id)}><p className="timeline-alert">No valid bids. No automatic price was created.</p><label className="field"><span>Reason for reopening</span><textarea name="reason" minLength={10} required rows={2} /></label><button className="secondary-button" disabled={busy}>Reopen bidding for two hours</button></form>}{window.status === 'tie_review' && <form className="form-grid" onSubmit={(event) => void resolveTie(event, window.request_id)}><p className="timeline-alert">Lowest bids are tied. Select a valid bid and record why it wins.</p><label className="field"><span>Winning bid</span><select name="winning_bid_id" required defaultValue=""><option value="">Choose bid</option>{tieBids.filter((bid) => bid.request_id === window.request_id && bid.status === 'valid').map((bid) => <option key={bid.id} value={bid.id}>{partners.find((partner) => partner.id === bid.partner_id)?.partner_name ?? bid.partner_id} ? {new Intl.NumberFormat('en-NG', { style: 'currency', currency: 'NGN' }).format(Number(bid.amount_ngn))}</option>)}</select></label><label className="field"><span>Decision reason</span><textarea name="reason" minLength={10} required rows={2} /></label><button className="primary-button" disabled={busy}>Resolve tie</button></form>}{deliveryQuotes.find((quote) => quote.request_id === window.request_id)?.status === 'pending_price' && <p className="form-footnote">Lowest valid bid selected. Management must finalize and send the customer price.</p>}</article>)}</div>}</section>
    <PortHarcourtHubPanel supabase={supabase} onError={onError} onNotice={onNotice} />
    <ProximityPanel supabase={supabase} canConfigure={canUpdateJobs} onError={onError} onNotice={onNotice} />
    <section className="form-card progress-operations">
      <div className="queue-card-heading"><div><p className="eyebrow">ACTIVE DELIVERIES</p><h2>Delivery progress</h2></div><span className="request-count">{jobs.length}</span></div>
      {jobs.length === 0 ? <p className="progress-empty">No active deliveries yet. Confirming a customer request creates one here.</p> : <div className="job-progress-list">{jobs.map((job) => {
        const nextStatuses: Record<string, string[]> = {
          order_confirmed: ['partner_assigned', 'pickup_scheduled', 'picked_up', 'exception', 'cancelled'],
          partner_assigned: ['pickup_scheduled', 'picked_up', 'exception', 'cancelled'],
          pickup_scheduled: ['picked_up', 'exception', 'cancelled'], picked_up: ['in_transit', 'exception'],
          in_transit: ['out_for_delivery', 'exception'], out_for_delivery: ['exception'],
          delivered: ['closed'], exception: ['pickup_scheduled', 'picked_up', 'in_transit', 'out_for_delivery', 'cancelled'],
        }
        const matchingRoutes=routes.filter((route)=>route.origin_city.trim().toLowerCase()===job.pickup_city.trim().toLowerCase()&&route.destination_city.trim().toLowerCase()===job.delivery_city.trim().toLowerCase()&&(!job.partner_id||!route.partner_id||route.partner_id===job.partner_id))
        const assignedRoute=routes.find((route)=>route.id===job.route_id)
        const eligiblePartners=assignedRoute?.partner_id?partners.filter((partner)=>partner.id===assignedRoute.partner_id):partners
        return <article className="job-progress-row" key={job.id}>
          <div className="job-progress-copy"><strong>{job.job_number}</strong><span>{job.customer_name ?? 'Customer'} | {job.pickup_city} to {job.delivery_city}</span><small className={`job-status-label status-${job.status}`}>{formatStatus(job.status)}</small>{job.partner_name && <small>Partner: {job.partner_name}</small>}{assignedRoute&&<small>Route: {assignedRoute.route_name} ({assignedRoute.route_number})</small>}</div>
          <label className="field job-status-control"><span className="sr-only">Update status for {job.job_number}</span><select value="" disabled={!canUpdateJobs || jobStatusBusy || !(nextStatuses[job.status]?.length)} onChange={(event) => { if (event.target.value) void updateJobStatus(job, event.target.value) }}><option value="">{!canUpdateJobs ? 'Preview only' : jobStatusBusy ? 'Saving...' : 'Update progress'}</option>{(nextStatuses[job.status] ?? []).map((status) => <option key={status} value={status}>{formatStatus(status)}</option>)}</select></label>
          {!['delivered','closed','cancelled'].includes(job.status)&&<div className="job-assignment-controls"><label className="field"><span>Assign route for {job.job_number}</span><select disabled={!canUpdateJobs||routeBusy||matchingRoutes.length===0} value={routeSelections[job.id]??job.route_id??''} onChange={(event)=>setRouteSelections((current)=>({...current,[job.id]:event.target.value}))}><option value="">{matchingRoutes.length?'Choose a route':'No matching route'}</option>{matchingRoutes.map((route)=><option key={route.id} value={route.id}>{route.route_name} ({route.route_number})</option>)}</select></label><button type="button" className="secondary-button" disabled={!canUpdateJobs||routeBusy||!routeSelections[job.id]} onClick={()=>void assignRoute(job)}>Assign route</button></div>}
          {!job.partner_id && ['order_confirmed', 'partner_assigned'].includes(job.status) && <div className="job-assignment-controls"><label className="field"><span>Assign partner</span><select disabled={!canUpdateJobs || eligiblePartners.length === 0} value={partnerSelections[job.id] ?? ''} onChange={(event) => setPartnerSelections((current) => ({ ...current, [job.id]: event.target.value }))}><option value="">{eligiblePartners.length ? 'Choose a partner' : 'Add a partner first'}</option>{eligiblePartners.map((partner) => <option key={partner.id} value={partner.id}>{partner.partner_name} ({partner.partner_number})</option>)}</select></label><button type="button" className="secondary-button" disabled={!canUpdateJobs || !partnerSelections[job.id]} onClick={() => void assignPartner(job)}>Assign</button></div>}
        </article>
      })}</div>}
    </section>
    <section className="form-card partner-setup-card">
      <div className="queue-card-heading"><div><p className="eyebrow">ROUTE DIRECTORY</p><h2>Delivery routes</h2></div><span className="request-count">{routes.length}</span></div>
      <form className="partner-create-form" onSubmit={(event)=>void createRoute(event)}>
        <Field label="Route name" name="route_name" required />
        <div className="field-row"><Field label="Origin city" name="origin_city" required/><Field label="Origin state" name="origin_state"/><Field label="Destination city" name="destination_city" required/><Field label="Destination state" name="destination_state"/></div>
        <label className="field"><span>Dedicated partner (optional)</span><select name="partner_id" defaultValue=""><option value="">Any active partner</option>{partners.map((partner)=><option key={partner.id} value={partner.id}>{partner.partner_name}</option>)}</select></label>
        <button className="primary-button" disabled={!canUpdateJobs||routeBusy}>{routeBusy?'Saving route...':'Add route'}</button>
      </form>
      {routes.length>0&&<div className="partner-roster">{routes.map((route)=><div key={route.id}><strong>{route.route_name}</strong><span>{route.route_number} ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· {route.origin_city} to {route.destination_city}</span></div>)}</div>}
    </section>
    <section className="form-card partner-setup-card">
      <div className="queue-card-heading"><div><p className="eyebrow">PARTNER DIRECTORY</p><h2>Logistics partners</h2></div><span className="request-count">{partners.length}</span></div>
      <form className="partner-create-form" onSubmit={createPartner}>
        <div className="field-row"><Field label="Partner or company name" name="partner_name" required /><Field label="Contact person" name="contact_person" required /></div>
        <div className="field-row"><Field label="Phone number" name="phone" type="tel" required /><Field label="Business email" name="email" type="email" /></div>
        <div className="field-row"><Field label="Base city" name="base_city" /><Field label="Base state" name="base_state" /></div>
        <Field label="Service areas" name="service_areas" placeholder="Lagos, Ibadan, Abuja" />
        <p className="form-footnote">A partner account can request portal access during signup. Super Admin approval is required before it can see assigned jobs.</p>
        <button className="primary-button" disabled={!canUpdateJobs || partnerFormBusy}>{partnerFormBusy ? 'Saving partner...' : 'Add logistics partner'}</button>
      </form>
      {partners.length > 0 && <div className="partner-roster">{partners.map((partner) => <div key={partner.id}><strong>{partner.partner_name}</strong><span>{partner.partner_number} | Active</span></div>)}</div>}
    </section>
  </section>
}

type PartnerPortalAssignment = {
  id: string
  status: string
  assigned_at: string
  job: { id: string; job_number: string; status: string; pickup_address: string; pickup_city: string; delivery_address: string; delivery_city: string; recipient_name: string; recipient_phone: string; recipient_phone_secondary?: string | null; job_parcels?: ParcelIdentifier[]; proof_of_delivery?: Array<{ id: string; storage_path: string; recipient_name: string | null; created_at: string }> }
}

function PartnerPortal({ supabase, userId, canRespond, onError, onNotice }: {
  supabase: ReturnType<typeof getSupabaseClient>
  userId: string
  canRespond: boolean
  onError: (message: string) => void
  onNotice: (message: string) => void
}) {
  const [assignments, setAssignments] = useState<PartnerPortalAssignment[]>([])
  const [partnerIds, setPartnerIds] = useState<string[]>([])
  const [partnerName, setPartnerName] = useState('')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [otpSentFor, setOtpSentFor] = useState<string[]>([])
  const [otpCodes, setOtpCodes] = useState<Record<string, string>>({})
  const [podFiles, setPodFiles] = useState<Record<string, File | undefined>>({})
  const [parcelLookup, setParcelLookup] = useState('')

  const loadAssignments = useCallback(async () => {
    setLoading(true)
    const { data: memberships, error: membershipError } = await supabase.from('partner_users').select('partner_id').eq('user_id', userId)
    if (membershipError) {
      onError(membershipError.message)
      setAssignments([])
      setLoading(false)
      return
    }
    const partnerIds = (memberships ?? []).map((membership) => membership.partner_id)
    setPartnerIds(partnerIds)
    if (!partnerIds.length) {
      setPartnerName('')
      setAssignments([])
      setLoading(false)
      return
    }
    const [{ data: partners }, { data: assignmentRows, error: assignmentsError }] = await Promise.all([
      supabase.from('logistics_partners').select('partner_name').in('id', partnerIds),
      supabase.from('partner_assignments').select('id, partner_id, job_id, status, assigned_at').in('partner_id', partnerIds).in('status', ['assigned', 'accepted', 'completed']).order('assigned_at', { ascending: false }).limit(50),
    ])
    if (assignmentsError) onError(assignmentsError.message)
    setPartnerName((partners ?? []).map((partner) => partner.partner_name).join(', '))
    const rows = assignmentRows ?? []
    const jobIds = [...new Set(rows.map((row) => row.job_id))]
    const { data: jobs, error: jobsError } = jobIds.length
      ? await supabase.from('jobs').select('id, job_number, status, pickup_address, pickup_city, delivery_address, delivery_city, recipient_name, recipient_phone, recipient_phone_secondary, job_parcels(tracking_code, parcel_number, description, quantity), proof_of_delivery(id, storage_path, recipient_name, created_at)').in('id', jobIds)
      : { data: [], error: null }
    if (jobsError) onError(jobsError.message)
    const jobsById = new Map((jobs ?? []).map((job) => [job.id, job]))
    setAssignments(rows.flatMap((row) => {
      const job = jobsById.get(row.job_id)
      return job ? [{ id: row.id, status: row.status, assigned_at: row.assigned_at, job: job as PartnerPortalAssignment['job'] }] : []
    }))
    setLoading(false)
  }, [onError, supabase, userId])

  useEffect(() => {
    const timer = window.setTimeout(() => { void loadAssignments() }, 0)
    return () => window.clearTimeout(timer)
  }, [loadAssignments])

  async function respond(assignment: PartnerPortalAssignment, accept: boolean) {
    if (!canRespond || busy) return
    setBusy(true)
    const { error } = await supabase.rpc('respond_to_partner_assignment', { p_assignment_id: assignment.id, p_accept: accept, p_response_note: null })
    if (error) onError(error.message)
    else {
      onNotice(accept ? `You accepted ${assignment.job.job_number}.` : `You declined ${assignment.job.job_number}.`)
      await loadAssignments()
    }
    setBusy(false)
  }

  async function updateProgress(assignment: PartnerPortalAssignment, status: string) {
    if (!canRespond || busy) return
    setBusy(true)
    const { error } = await supabase.rpc('update_job_status', { p_job_id: assignment.job.id, p_new_status: status })
    if (error) onError(error.message)
    else {
      onNotice(`${assignment.job.job_number} updated to ${formatStatus(status)}.`)
      await loadAssignments()
    }
    setBusy(false)
  }

  async function sendDeliveryCode(assignment: PartnerPortalAssignment) {
    if (!canRespond || busy) return
    setBusy(true)
    const { error } = await supabase.functions.invoke('delivery-otp', { body: { jobId: assignment.job.id } })
    if (error) onError(error.message)
    else {
      setOtpSentFor((current) => current.includes(assignment.job.id) ? current : [...current, assignment.job.id])
      onNotice(`A delivery code was sent to the recipient for ${assignment.job.job_number}.`)
    }
    setBusy(false)
  }

  async function verifyDeliveryCode(assignment: PartnerPortalAssignment) {
    if (!canRespond || busy) return
    setBusy(true)
    const { data, error } = await supabase.rpc('verify_delivery_otp', { p_job_id: assignment.job.id, p_code: otpCodes[assignment.job.id] ?? '' })
    if (error) onError(error.message)
    else if (!data?.verified) onError(`That code is incorrect. ${data?.attempts_remaining ?? 0} attempts remain.`)
    else {
      onNotice(`${assignment.job.job_number} delivery confirmed by recipient.`)
      await loadAssignments()
    }
    setBusy(false)
  }

  async function uploadProof(assignment: PartnerPortalAssignment) {
    const file = podFiles[assignment.job.id]
    if (!canRespond || busy || !file) return
    if (!['image/jpeg', 'image/png', 'image/webp'].includes(file.type) || file.size > 5 * 1024 * 1024) {
      onError('Choose a JPEG, PNG, or WebP photo up to 5 MB.')
      return
    }
    setBusy(true)
    const extension = file.type === 'image/jpeg' ? 'jpg' : file.type === 'image/png' ? 'png' : 'webp'
    const path = `${assignment.job.id}/${crypto.randomUUID()}.${extension}`
    const { error: uploadError } = await supabase.storage.from('proof-of-delivery').upload(path, file, { contentType: file.type, upsert: false })
    if (uploadError) onError(uploadError.message)
    else {
      const { error: recordError } = await supabase.from('proof_of_delivery').insert({
        job_id: assignment.job.id, storage_path: path, content_type: file.type,
        file_size_bytes: file.size, recipient_name: assignment.job.recipient_name, recorded_by: userId,
      })
      if (recordError) {
        onError(recordError.message)
        await supabase.storage.from('proof-of-delivery').remove([path])
      } else {
        onNotice(`Proof of delivery saved for ${assignment.job.job_number}.`)
        await loadAssignments()
      }
    }
    setBusy(false)
  }

  const visibleAssignments=assignments.filter(({job})=>!parcelLookup.trim()||job.job_parcels?.some((parcel)=>parcel.tracking_code.toUpperCase()===parcelLookup.trim().toUpperCase()))
  return <main className="partner-page">
    <div className="dashboard-heading"><div><p className="eyebrow">LOGISTICS PARTNER</p><h1>Assigned deliveries</h1><p className="section-intro">{partnerName || 'Jobs assigned to your partner account appear here.'}</p></div><button className="secondary-button" onClick={() => void loadAssignments()} disabled={loading}>Refresh deliveries</button></div>
    {canRespond && <PartnerOrganizationPanel supabase={supabase} userId={userId} onError={onError} onNotice={onNotice} />}
    {canRespond && <PartnerBidQueue supabase={supabase} partnerIds={partnerIds} onError={onError} onNotice={onNotice} />}
    {canRespond && <ProximityPanel supabase={supabase} canConfigure={false} onError={onError} onNotice={onNotice} />}
    {!canRespond && <div className="role-preview-banner">Preview only: partner responses and delivery updates require a linked Partner account.</div>}
    <label className="field parcel-lookup"><span>Find parcel by ID or scan its barcode</span><input value={parcelLookup} onChange={(event)=>setParcelLookup(event.target.value)} placeholder="KWP-P-00000001" autoComplete="off" /></label>
    {loading ? <div className="loading queue-loading">Loading assigned deliveries...</div> : assignments.length === 0 ? <section className="form-card queue-empty"><h2>No assigned deliveries</h2><p>New jobs assigned by Kwik-Parsel Operations will appear here.</p></section> : visibleAssignments.length===0 ? <section className="form-card queue-empty"><h2>No parcel found</h2><p>Check the parcel code and try again.</p></section> : <div className="partner-assignment-list">{visibleAssignments.map((assignment) => {
      const { job } = assignment
      const partnerStatuses: Record<string, string[]> = { partner_assigned: ['picked_up', 'exception'], pickup_scheduled: ['picked_up', 'exception'], picked_up: ['in_transit', 'exception'], in_transit: ['out_for_delivery', 'exception'], out_for_delivery: ['exception'], exception: ['pickup_scheduled', 'picked_up', 'in_transit', 'out_for_delivery'] }
      return <article className="form-card partner-job-card" key={assignment.id}>
        <div className="review-title"><div><p className="eyebrow">{job.job_number}</p><h2>{formatStatus(job.status)}</h2></div><span className={`assignment-status assignment-${assignment.status}`}>{assignment.status === 'assigned' ? 'Awaiting response' : assignment.status === 'completed' ? 'Delivered' : 'Accepted'}</span></div>
        <div className="partner-job-route"><div><small>PICKUP</small><p>{job.pickup_address}<br />{job.pickup_city}</p></div><div><small>DELIVER TO</small><p>{job.delivery_address}<br />{job.delivery_city}</p><strong>{job.recipient_name} | {job.recipient_phone}</strong>{job.recipient_phone_secondary && <small>Alternate: {job.recipient_phone_secondary}</small>}</div></div><ParcelIdentifiers parcels={job.job_parcels??[]} />
        {assignment.status === 'assigned' ? <div className="partner-response-actions"><button className="secondary-button" disabled={!canRespond || busy} onClick={() => void respond(assignment, false)}>Decline job</button><button className="primary-button" disabled={!canRespond || busy} onClick={() => void respond(assignment, true)}>{busy ? 'Saving...' : 'Accept job'}</button></div> : <>
          <label className="field partner-progress-control"><span>Update delivery progress</span><select value="" disabled={!canRespond || busy || !partnerStatuses[job.status]?.length} onChange={(event) => { if (event.target.value) void updateProgress(assignment, event.target.value) }}><option value="">{busy ? 'Saving...' : 'Choose next status'}</option>{(partnerStatuses[job.status] ?? []).map((status) => <option key={status} value={status}>{formatStatus(status)}</option>)}</select></label>
          {job.status === 'out_for_delivery' && <section className="delivery-otp-panel" aria-label={`Recipient confirmation for ${job.job_number}`}>
            {!otpSentFor.includes(job.id) ? <><p className="section-intro">Confirm delivery with a code sent directly to the recipient's phone.</p><button className="secondary-button" disabled={!canRespond || busy} onClick={() => void sendDeliveryCode(assignment)}>{busy ? 'Sending code...' : 'Send recipient delivery code'}</button></> : <>
              <p className="section-intro">Ask the recipient to read their six-digit code to you. Delivery completes after the code is verified.</p>
              <label className="field"><span>Recipient delivery code</span><input value={otpCodes[job.id] ?? ''} onChange={(event) => setOtpCodes((current) => ({ ...current, [job.id]: event.target.value.replace(/\D/g, '').slice(0, 6) }))} inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6}" maxLength={6} placeholder="000000" /></label>
              <button className="primary-button" disabled={!canRespond || busy || (otpCodes[job.id] ?? '').length !== 6} onClick={() => void verifyDeliveryCode(assignment)}>{busy ? 'Verifying...' : 'Verify code and confirm delivery'}</button>
            </>}
          </section>}
          {assignment.status === 'completed' && job.status === 'delivered' && <section className="delivery-otp-panel pod-upload-panel" aria-label={`Proof of delivery for ${job.job_number}`}>
            <h3>Proof of delivery</h3>
            {job.proof_of_delivery?.length ? <p className="pod-saved-message">Photo proof saved for this delivery.</p> : <>
              <p className="section-intro">Add a clear photo of the delivered parcel or signed receipt.</p>
              <label className="field"><span>Delivery photo (up to 5 MB)</span><input type="file" accept="image/jpeg,image/png,image/webp" capture="environment" onChange={(event) => setPodFiles((current) => ({ ...current, [job.id]: event.target.files?.[0] }))} /></label>
              <button className="secondary-button" disabled={!canRespond || busy || !podFiles[job.id]} onClick={() => void uploadProof(assignment)}>{busy ? 'Saving proof...' : 'Upload proof of delivery'}</button>
            </>}
          </section>}
        </>}
      </article>
    })}</div>}
  </main>
}

function AuthPanel({ supabase, onError, onNotice, busy, setBusy }: {
  supabase: ReturnType<typeof getSupabaseClient>; onError: (message: string) => void; onNotice: (message: string) => void; busy: boolean; setBusy: (value: boolean) => void
}) {
  const [mode, setMode] = useState<'signin' | 'signup' | 'forgot' | 'otp'>('signin')
  const marketerInvite = new URLSearchParams(window.location.search).get('marketer_invite')?.trim() ?? ''
  const partnerInvite = new URLSearchParams(window.location.hash.replace(/^#/, '')).get('partner_invite')?.trim()
    ?? new URLSearchParams(window.location.search).get('partner_invite')?.trim() ?? ''
  const partnerProspectInvite = new URLSearchParams(window.location.search).get('partner_prospect_invite')?.trim() ?? ''
  const invitedAsMarketer = marketerInvite.length >= 32
  const invitedAsPartnerProspect = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(partnerProspectInvite)
  const invitedAsPartner = partnerInvite.length >= 32 || invitedAsPartnerProspect
  const [accountKind, setAccountKind] = useState<'customer' | 'staff'>(invitedAsMarketer || invitedAsPartner ? 'staff' : 'customer')
  const [requestedRole, setRequestedRole] = useState(invitedAsMarketer ? 'marketer' : invitedAsPartner ? 'partner' : 'operations')
  const [email, setEmail] = useState('')
  const referralCode = new URLSearchParams(window.location.search).get('ref')?.trim().toUpperCase() ?? ''
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const form = new FormData(event.currentTarget)
    const submittedEmail = String(form.get('email') ?? email).trim()
    const password = String(form.get('password') || '')
    onError(''); onNotice(''); setBusy(true)
    if (mode === 'signin') {
      const { error } = await supabase.auth.signInWithPassword({ email: submittedEmail, password })
      if (error) onError(error.message)
    } else if (mode === 'signup') {
      const { data, error } = await supabase.auth.signUp({
        email: submittedEmail, password,
        options: { emailRedirectTo: siteUrl, data: {
          full_name: String(form.get('full_name')).trim(), account_kind: accountKind,
          phone: accountKind === 'customer' ? String(form.get('phone') || '').trim() : null,
          company_name: accountKind === 'customer' ? String(form.get('company_name') || '').trim() : null,
          referral_code: accountKind === 'customer' && /^[A-Z0-9]{8,16}$/.test(referralCode) ? referralCode : null,
          requested_role: accountKind === 'staff' ? invitedAsMarketer ? 'marketer' : String(form.get('requested_role')) : null,
          marketer_invite: accountKind === 'staff' && invitedAsMarketer ? marketerInvite : null,
          partner_invite: accountKind === 'staff' && invitedAsPartner ? partnerInvite : null,
          partner_prospect_invite: accountKind === 'staff' && invitedAsPartnerProspect ? partnerProspectInvite : null,
          organization_name: accountKind === 'staff' ? String(form.get('organization_name') ?? '').trim() : null,
        } },
      })
      if (error) onError(error.message)
      else if (data.user?.identities?.length === 0) onNotice('This email already has an account, so no confirmation email was sent. Sign in, or use Forgot password if you cannot access the account.')
      else if (!data.session) onNotice(`Check your email to confirm your account. The link opens ${siteUrl}${accountKind === 'staff' && requestedRole === 'partner' ? ' Then sign in to upload your NIN or CAC document.' : ''}`)
      else onNotice(accountKind === 'staff' ? requestedRole === 'partner' ? 'Sign in and upload your NIN or CAC document for Super Admin review.' : 'Your application is awaiting Super Admin approval.' : 'Account created. Your customer profile is ready; submit a delivery request to get started.')
    } else if (mode === 'forgot') {
      const { error } = await supabase.auth.resetPasswordForEmail(submittedEmail)
      if (error) onError(error.message)
      else {
        setEmail(submittedEmail)
        setMode('otp')
        onNotice('If an account exists for that email, a verification code is on its way.')
      }
    } else {
      const token = String(form.get('token') ?? '').replace(/\s/g, '')
      const { error } = await supabase.auth.verifyOtp({ email: submittedEmail, token, type: 'recovery' })
      if (error) onError(error.message)
    }
    setBusy(false)
  }
  const heading = mode === 'signup' ? 'Create your account.' : mode === 'forgot' ? 'Reset your password.' : mode === 'otp' ? 'Enter your code.' : 'Welcome back.'
  const intro = mode === 'signup' ? 'Customers can start right away. Staff and partner access requires Super Admin approval.' : mode === 'forgot' ? 'We will send a one-time code to your email address.' : mode === 'otp' ? `Enter the 8-digit code sent to ${email}. You will set a new password here next.` : 'Sign in to your Kwik-Parsel account.'
  return <section className="auth-layout"><div className="hero-copy"><p className="eyebrow">LOGISTICS, WITH A HUMAN TOUCH</p><h1>Good business<br />keeps <em>moving.</em></h1><p className="hero-description">Request a delivery, keep track of what's moving, and stay in the loop from pickup to arrival.</p><div className="flow-note"><span>01</span><div><strong>One clear place for your deliveries</strong><p>Submit a request and follow its progress with Kwik-Parsel.</p></div></div></div><section className="form-card auth-card"><p className="eyebrow">KWIK-PARSEL ACCOUNT</p><h2>{heading}</h2><p className="section-intro">{intro}</p><form className="form-grid" onSubmit={submit}>
    {mode === 'signup' && <><Field label="Your full name" name="full_name" autoComplete="name" required /><label className="field"><span>Sign up as</span><select name="account_kind" value={accountKind} disabled={invitedAsMarketer || invitedAsPartner} onChange={(event) => setAccountKind(event.target.value as 'customer' | 'staff')}><option value="customer">Customer</option><option value="staff">Staff or logistics partner</option></select></label>{accountKind === 'customer' && <><Field label="Phone number" name="phone" type="tel" autoComplete="tel" required /><Field label="Business name (optional)" name="company_name" autoComplete="organization" />{referralCode && /^[A-Z0-9]{8,16}$/.test(referralCode) && <p className="form-footnote">Referral link applied. Your account will be connected to the person who referred you.</p>}</>}{accountKind === 'staff' && <><label className="field"><span>Requested category</span><select name="requested_role" value={requestedRole} disabled={invitedAsMarketer || invitedAsPartner} onChange={(event) => setRequestedRole(event.target.value)} required><option value="marketer" disabled={!invitedAsMarketer}>Marketer (invitation only)</option><option value="operations">Operations</option><option value="warehouse">Warehouse</option><option value="finance">Finance</option><option value="bdo">Business Development</option><option value="partner">Logistics Partner</option><option value="management">Management</option></select></label>{invitedAsMarketer && <p className="form-footnote">You were invited by a BDO. Register with the invited email address; a Super Admin must approve the account before access is enabled.</p>}{invitedAsPartnerProspect && <p className="form-footnote">Your application is linked to the Gohezo BDO who invited you. Confirm your email, then submit your NIN or CAC document for Super Admin review.</p>}{invitedAsPartner && !invitedAsPartnerProspect && <p className="form-footnote">You were invited to a partner company. Register with the invited email, submit a NIN or CAC document, and wait for Super Admin approval before company access is enabled.</p>}{!invitedAsPartnerProspect && <Field label="Organization or partner name" name="organization_name" />}{requestedRole === 'partner' && !invitedAsPartner && <p className="form-footnote">After confirming your email, sign in here to upload your NIN or CAC registration document for Super Admin review.</p>}</>}</>}
    {mode !== 'otp' && <label className="field"><span>Email address</span><input name="email" type="email" autoComplete="email" required value={email} onChange={(event) => setEmail(event.target.value)} /></label>}
    {(mode === 'signin' || mode === 'signup') && <Field key={mode} label="Password" name="password" type="password" autoComplete={mode === 'signup' ? 'new-password' : 'current-password'} minLength={8} required />}
    {mode === 'otp' && <label className="field"><span>8-digit verification code</span><input name="token" type="text" inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{8}" maxLength={8} minLength={8} placeholder="00000000" required autoFocus /></label>}
    <button className="primary-button" disabled={busy}>{busy ? 'Please wait...' : mode === 'signup' ? 'Create account' : mode === 'forgot' ? 'Send verification code' : mode === 'otp' ? 'Verify code' : 'Sign in'}</button>
  </form><div className="auth-links">{mode === 'signin' ? <><button className="text-button" onClick={() => setMode('forgot')}>Forgot password?</button><span>New to Kwik-Parsel? <button className="text-button" onClick={() => setMode('signup')}>Create account</button></span></> : mode === 'otp' ? <><button className="text-button" onClick={() => { setMode('forgot'); onError(''); onNotice('') }}>Change email</button><button className="text-button" onClick={() => { setMode('forgot'); onError(''); onNotice('') }}>Send a new code</button><button className="text-button" onClick={() => setMode('signin')}>Back to sign in</button></> : <button className="text-button" onClick={() => setMode('signin')}>Back to sign in</button>}</div><p className="form-footnote auth-credit">Kwik-Parsel is a product by Gohezo Integrated Services.</p></section></section>
}

function DeliveryTimeline({ request }: { request: DeliveryRequest }) {
  const milestones = jobProgressSteps.filter((status) => status !== 'closed')
  const history = [...(request.job_history ?? [])].sort((first, second) => Date.parse(first.changed_at) - Date.parse(second.changed_at))
  const completedStatuses = new Set(history.map((event) => event.status))
  const currentIndex = milestones.indexOf(request.job_status ?? '')
  if (request.job_status === 'exception') {
    const previousProgress = [...history].reverse().find((event) => event.status !== 'exception')?.status
    const previousIndex = milestones.indexOf(previousProgress ?? '')
    milestones.forEach((status, index) => { if (index <= previousIndex) completedStatuses.add(status) })
  } else if (currentIndex >= 0) milestones.forEach((status, index) => { if (index <= currentIndex) completedStatuses.add(status) })

  return <div className="delivery-timeline" aria-label="Delivery progress">
    <div className="timeline-current"><span>DELIVERY STATUS</span><strong className={`job-status-label status-${request.job_status}`}>{formatStatus(request.job_status ?? '')}</strong></div>
    {request.job_status === 'exception' && <p className="timeline-alert">Kwik-Parsel is reviewing an issue with this delivery.</p>}
    {request.job_status === 'cancelled' && <p className="timeline-alert">This delivery was cancelled.</p>}
    <ol>{milestones.map((status) => {
      const event = history.find((entry) => entry.status === status)
      const complete = completedStatuses.has(status)
      return <li className={complete ? 'timeline-step timeline-step-complete' : 'timeline-step'} key={status}><span className="timeline-dot" aria-hidden="true">{complete ? 'OK' : ''}</span><div><strong>{formatStatus(status)}</strong>{event && <small>{new Intl.DateTimeFormat('en-NG', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(event.changed_at))}</small>}</div></li>
    })}</ol>
  </div>
}

function Dashboard({ supabase, userId, onError, onNotice, customer, services, coverageLocations, coverageCorridors, requests, notifications, busy, onSubmit, onMarkRead, onRefresh }: { supabase: ReturnType<typeof getSupabaseClient>; userId: string; onError: (message: string) => void; onNotice: (message: string) => void; customer: Customer; services: Service[]; coverageLocations: CoverageLocation[]; coverageCorridors: CoverageCorridor[]; requests: DeliveryRequest[]; notifications: CustomerNotification[]; busy: boolean; onSubmit: (event: FormEvent<HTMLFormElement>) => void; onMarkRead: (notification: CustomerNotification) => void; onRefresh: () => void }) {
  const [serviceId, setServiceId] = useState('')
  const [originId, setOriginId] = useState('')
  const [destinationId, setDestinationId] = useState('')
  const [activeFrame, setActiveFrame] = useState<'home'|'send'|'updates'|'tracking'>('home')
  const [selectedParcel, setSelectedParcel] = useState<SavedParcel | null>(null)
  const [selectedPal, setSelectedPal] = useState<{ contact: ParcelPalContact; destination: ParcelDestination } | null>(null)
  const [capacityWarning, setCapacityWarning] = useState<{ message: string; exceeded: boolean } | null>(null)
  const serviceCode = services.find((service) => service.id === serviceId)?.code
  const enabledCorridors = coverageCorridors.filter((corridor) => corridor.service_code === serviceCode && coverageLocations.some((location) => location.id === corridor.origin_id) && coverageLocations.some((location) => location.id === corridor.destination_id))
  const origins = coverageLocations.filter((location) => enabledCorridors.some((corridor) => corridor.origin_id === location.id))
  const destinations = coverageLocations.filter((location) => enabledCorridors.some((corridor) => corridor.origin_id === originId && corridor.destination_id === location.id))
  const openFrame = (frame: 'send'|'updates'|'tracking') => setActiveFrame(frame)
  const returnHome = () => setActiveFrame('home')
  function openDeliveryInfo() {
    const heading = document.getElementById('parcel-pal-destinations-heading')
    heading?.scrollIntoView?.({ behavior: 'smooth', block: 'start' })
    heading?.focus()
  }
  function checkParcelCapacity(event: ChangeEvent<HTMLFormElement>) {
    const form = new FormData(event.currentTarget)
    const quantity = Number(form.get('parcel_quantity'))
    const capacity = assessParcelCapacity(quantity, {
      length: Number(form.get('parcel_length_cm')),
      width: Number(form.get('parcel_width_cm')),
      height: Number(form.get('parcel_height_cm')),
      weight: Number(form.get('parcel_weight')),
    })
    if (!capacity.ready) {
      setCapacityWarning(quantity > 1 ? { message: 'Choose per-item size and weight to check this item count.', exceeded: false } : null)
      return
    }
    const exceeded = [!capacity.fitsWeight && 'total weight', !capacity.fitsDimensions && 'packed size'].filter(Boolean)
    setCapacityWarning(exceeded.length ? { message: `This item count exceeds the ${exceeded.join(' and ')} capacity. Reduce the count or per-item size/weight.`, exceeded: true } : null)
  }
  return <main className="dashboard customer-dashboard">
    <div className="dashboard-heading">
      <div><p className="eyebrow">CUSTOMER PORTAL</p><h1>{activeFrame === 'home' ? 'Your parcels' : activeFrame === 'send' ? 'Send items' : activeFrame === 'updates' ? 'Updates' : 'Your deliveries'}</h1><p className="section-intro">{customer.company_name}</p></div>
      <span className={`profile-status status-${customer.status}`}>{customer.status}</span>
    </div>
    {activeFrame === 'home' && <>
      <nav className="customer-launch-grid" aria-label="Customer navigation">
        <button className="customer-launch-card" type="button" onClick={() => openFrame('send')}><span className="customer-launch-icon" aria-hidden="true">＋</span><strong>Send items</strong><small>Book a pickup and delivery</small></button>
        <button className="customer-launch-card" type="button" onClick={openDeliveryInfo}><span className="customer-launch-icon" aria-hidden="true">⌖</span><strong>Edit my delivery info</strong><small>Work, home and other addresses</small></button>
        <button className="customer-launch-card" type="button" onClick={() => openFrame('updates')}><span className="customer-launch-icon" aria-hidden="true">◉</span><strong>Updates</strong><small>{notifications.filter((item) => !item.read_at).length ? `${notifications.filter((item) => !item.read_at).length} new` : 'Messages about your parcels'}</small></button>
        <button className="customer-launch-card" type="button" onClick={() => openFrame('tracking')}><span className="customer-launch-icon" aria-hidden="true">↗</span><strong>Tracking</strong><small>{requests.length ? `${requests.length} deliveries` : 'Your deliveries'}</small></button>
      </nav>
      <ParcelPalsPanel supabase={supabase} userId={userId} onError={onError} onNotice={onNotice} onUseDestination={(contact, destination) => { setSelectedPal({ contact, destination }); setDestinationId(''); setCapacityWarning(null); setActiveFrame('send') }} />
      <CustomerSavedParcels supabase={supabase} userId={userId} onError={onError} onNotice={onNotice} onUse={(parcel) => { setSelectedParcel(parcel); setCapacityWarning(null); setActiveFrame('send') }} />
    </>}
    {activeFrame !== 'home' && <button className="text-button customer-back-button" type="button" onClick={returnHome}>← Back to customer home</button>}
    {activeFrame === 'send' && <section className="form-card request-card customer-app-frame" aria-labelledby="delivery-details-heading">
      <p className="eyebrow">NEW DELIVERY</p><h2 id="delivery-details-heading">Delivery details</h2>
      <form key={`${selectedParcel?.id ?? 'new-parcel'}-${selectedPal?.contact.code ?? 'no-pal'}-${selectedPal?.destination.slot ?? 0}`} className="form-grid" onSubmit={onSubmit} onChange={checkParcelCapacity}>
        {selectedParcel && <div className="selected-saved-parcel"><img src={selectedParcel.photo_url} alt="" /><span><strong>{selectedParcel.item_name}</strong><small>Saved item details filled in</small></span><button className="text-button" type="button" onClick={() => setSelectedParcel(null)}>Clear</button></div>}
        <label className="field"><span>Service</span><select name="service_id" required value={serviceId} onChange={(event) => { setServiceId(event.target.value); setOriginId(''); setDestinationId('') }}><option value="" disabled>Select service</option>{services.map((service) => <option key={service.id} value={service.id}>{service.name}</option>)}</select></label>
        <div className="form-divider">PICKUP</div>
        <div className="field-row"><Field label="Pickup contact" name="sender_name" required /><Field label="Pickup phone" name="sender_phone" type="tel" required /></div>
        <Field label="Pickup address" name="pickup_address" required />
        <div className="field-row"><label className="field"><span>Pickup city</span><select name="pickup_city" required value={originId ? coverageLocations.find((location) => location.id === originId)?.name ?? '' : ''} onChange={(event) => { setOriginId(coverageLocations.find((location) => location.name === event.target.value)?.id ?? ''); setDestinationId('') }}><option value="">Select city</option>{origins.map((location) => <option key={location.id} value={location.name}>{location.name}</option>)}</select></label><input type="hidden" name="pickup_state" value={coverageLocations.find((location) => location.id === originId)?.state ?? ''} /><Field label="Pickup time" name="preferred_pickup_at" type="datetime-local" min={new Date().toISOString().slice(0, 16)} /></div>
        <div className="form-divider">DELIVER TO</div>
        {selectedPal && <div className="selected-saved-parcel"><span><strong>Parcel Pal: {selectedPal.contact.full_name || selectedPal.contact.code}</strong><small>{selectedPal.destination.label} location selected. Confirm it with the recipient below.</small></span><button className="text-button" type="button" onClick={() => setSelectedPal(null)}>Clear</button></div>}
        <div className="field-row"><Field label="Recipient name" name="recipient_name" defaultValue={selectedPal?.contact.full_name ?? ''} required /><Field label="Recipient phone" name="recipient_phone" type="tel" defaultValue={selectedPal?.contact.phone ?? ''} required /></div>
        <div className="field-row"><Field label="Second phone (optional)" name="recipient_phone_secondary" type="tel" defaultValue={selectedPal?.destination.secondary_phone ?? ''} /><Field label="Delivery address" name="delivery_address" defaultValue={selectedPal?.destination.address ?? ''} required /></div>
        <div className="field-row"><label className="field"><span>Delivery city</span><select name="delivery_city" required value={destinationId ? coverageLocations.find((location) => location.id === destinationId)?.name ?? selectedPal?.destination.city ?? '' : selectedPal?.destination.city ?? ''} onChange={(event) => setDestinationId(destinations.find((location) => location.name === event.target.value)?.id ?? '')}><option value="">Select city</option>{selectedPal && !destinations.some((location) => location.name === selectedPal.destination.city) && <option value={selectedPal.destination.city}>{selectedPal.destination.city} (Parcel Pal location)</option>}{destinations.map((location) => <option key={location.id} value={location.name}>{location.name}</option>)}</select></label><input type="hidden" name="delivery_state" value={coverageLocations.find((location) => location.id === destinationId)?.state ?? selectedPal?.destination.state ?? ''} /></div>
        <label className="recipient-location-confirm"><input type="checkbox" name="recipient_location_confirmed" value="yes" required /><span>I confirmed this delivery location with the recipient.</span></label>
        <div className="form-divider">PARCEL</div><p className="parcel-capacity-help">Enter size and weight per item. We check the selected count against shipment capacity.</p>
        <div className="field-row"><Field label="Description" name="parcel_description" placeholder="Household items" required defaultValue={selectedParcel?.description} /><label className="field"><span>Items for this destination</span><select name="parcel_quantity" required defaultValue="1">{Array.from({ length: PARCEL_MAX_QUANTITY }, (_, index) => index + 1).map((quantity) => <option key={quantity} value={quantity}>{quantity}</option>)}</select></label><ParcelWeightField name="parcel_weight" defaultValue={selectedParcel?.weight_kg} /></div>
        <ParcelMeasureFields names={{ length: 'parcel_length_cm', width: 'parcel_width_cm', height: 'parcel_height_cm' }} defaults={{ length: selectedParcel?.length_cm, width: selectedParcel?.width_cm, height: selectedParcel?.height_cm }} />
        {capacityWarning && <p className={`parcel-capacity-warning ${capacityWarning.exceeded ? 'parcel-capacity-exceeded' : 'parcel-capacity-prompt'}`} role={capacityWarning.exceeded ? 'alert' : 'status'} aria-live={capacityWarning.exceeded ? 'assertive' : 'polite'}>{capacityWarning.message}</p>}
        <div className="field-row"><Field label="Declared worth (₦)" name="parcel_declared_value" type="number" min="0" step="0.01" defaultValue={selectedParcel?.declared_value} /><Field label="Price paid (₦)" name="parcel_price" type="number" min="0" step="0.01" defaultValue={selectedParcel?.price} /></div>
        <details className="customer-optional"><summary>Special instructions</summary><label className="field"><span>Notes for delivery</span><textarea name="special_instructions" rows={2} /></label></details>
        <button className="primary-button" disabled={busy || services.length === 0 || enabledCorridors.length === 0}>{busy ? 'Submitting...' : services.length ? 'Request delivery' : 'No service available'}</button>
      </form>
    </section>}
    {activeFrame === 'updates' && <section className="notification-panel customer-notifications customer-app-frame"><div className="history-heading"><div><p className="eyebrow">UPDATES</p><h2>Messages about your parcels</h2></div><button type="button" className="text-button notification-refresh" onClick={onRefresh}>Refresh</button></div>{notifications.length === 0 ? <p className="notification-empty">No updates.</p> : <div className="notification-list">{notifications.map((notification) => <article className={`notification-item ${notification.read_at ? 'notification-read' : 'notification-unread'}`} key={notification.id}><div className="notification-copy"><div className="notification-title-row"><strong>{notification.title}</strong>{!notification.read_at && <span className="notification-new">New</span>}</div><p>{notification.body}</p><small>{new Intl.DateTimeFormat('en-NG', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(notification.created_at))}</small></div>{!notification.read_at && <button className="secondary-button notification-read-button" onClick={() => onMarkRead(notification)}>Mark as read</button>}</article>)}</div>}</section>}
    {activeFrame === 'tracking' && <section className="history-panel customer-history customer-app-frame"><div className="history-heading"><div><p className="eyebrow">TRACKING</p><h2>Your deliveries</h2></div><span className="request-count">{requests.length}</span><button className="text-button" type="button" onClick={onRefresh}>Refresh</button></div>{requests.length === 0 ? <div className="empty-state"><span className="empty-icon" aria-hidden="true">＋</span><h3>No deliveries yet</h3></div> : <><CustomerQuotePanel supabase={supabase} requestIds={requests.map((request) => request.id)} onError={onError} onNotice={onNotice} onRefresh={onRefresh} /><div className="request-list">{requests.map((request) => <article className="request-item" key={request.id}><div className="request-item-top"><strong>{request.request_number}</strong><span className={`request-status status-${request.status}`}>{formatRequestStatus(request.status)}</span></div><p>{request.pickup_city} <span aria-hidden="true">to</span> {request.delivery_city}</p><small>{request.recipient_name} - {new Intl.DateTimeFormat('en-NG', { dateStyle: 'medium' }).format(new Date(request.created_at))}</small>{request.order_number && <div className="request-references"><span>Order <strong>{request.order_number}</strong></span>{request.job_number && <span>Job <strong>{request.job_number}</strong></span>}{request.job_status && <span className={`job-status-label status-${request.job_status}`}>{formatStatus(request.job_status)}</span>}</div>}{request.customer_price !== undefined && request.customer_price !== null && <details className="customer-payment-summary"><summary>Payment</summary><span>Total: {new Intl.NumberFormat('en-NG',{style:'currency',currency:request.customer_currency ?? 'NGN'}).format(Number(request.customer_price))}</span><span>Received: {new Intl.NumberFormat('en-NG',{style:'currency',currency:request.customer_currency ?? 'NGN'}).format((request.payments ?? []).filter((payment) => payment.status === 'received').reduce((sum,payment) => sum + Number(payment.amount),0))}</span><span>Balance: {new Intl.NumberFormat('en-NG',{style:'currency',currency:request.customer_currency ?? 'NGN'}).format(Math.max(0,Number(request.customer_price) - (request.payments ?? []).filter((payment) => payment.status === 'received').reduce((sum,payment) => sum + Number(payment.amount),0)))}</span>{request.payments?.map((payment) => <small key={payment.payment_number}>{payment.payment_number} - {payment.method.replaceAll('_',' ')} - {new Intl.NumberFormat('en-NG',{style:'currency',currency:payment.currency}).format(Number(payment.amount))}{payment.status === 'reversed' ? ' - Reversed' : ''}</small>)}</details>}{request.job_status && <DeliveryTimeline request={request} />}<ParcelIdentifiers parcels={request.parcels??[]} />{request.proofs?.map((proof, index) => <a className="pod-customer-link" key={proof.storage_path} href={proof.signed_url} target="_blank" rel="noreferrer">View proof of delivery {index + 1}</a>)}</article>)}</div></>}</section>}
  </main>
}

function FinanceConsole({ supabase, userId, canRecord, canApprove, canPay, onError, onNotice }: {
  supabase: ReturnType<typeof getSupabaseClient>
  userId: string
  canRecord: boolean
  canApprove: boolean
  canPay: boolean
  onError: (message: string) => void
  onNotice: (message: string) => void
}) {
  const [jobs, setJobs] = useState<FinanceJob[]>([])
  const [totals, setTotals] = useState<FinanceTotal[]>([])
  const [loading, setLoading] = useState(true)
  const [busyKey, setBusyKey] = useState('')

  const loadFinance = useCallback(async () => {
    setLoading(true)
    const [jobResult, totalResult] = await Promise.all([
      supabase.from('jobs').select('id, job_number, status, customer_id, partner_id').order('updated_at', { ascending: false }).limit(100),
      supabase.rpc('finance_dashboard_totals'),
    ])
    setTotals((totalResult.data ?? []) as FinanceTotal[])
    const firstError = jobResult.error ?? totalResult.error
    if (firstError) {
      onError(firstError.message)
      setJobs([])
      setLoading(false)
      return
    }
    const rows = (jobResult.data ?? []) as unknown as Array<{ id: string; job_number: string; status: string; customer_id: string; partner_id: string | null }>
    const ids = rows.map((job) => job.id)
    const [financialResult, paymentResult, settlementResult] = ids.length ? await Promise.all([
      supabase.from('job_financials').select('job_id, customer_revenue, partner_cost, other_direct_cost, currency').in('job_id', ids),
      supabase.from('customer_payments').select('id, payment_number, job_id, amount, currency, method, reference, received_at, status, reversal_reason').in('job_id', ids).order('received_at', { ascending: false }),
      supabase.from('partner_settlements').select('id, settlement_number, job_id, amount, currency, status, request_reference, reference, created_by, approved_by').in('job_id', ids).order('created_at', { ascending: false }),
    ]) : [{ data: [], error: null }, { data: [], error: null }, { data: [], error: null }]
    const detailError = financialResult.error ?? paymentResult.error ?? settlementResult.error
    if (detailError) { onError(detailError.message); setJobs([]); setLoading(false); return }
    const customerIds = [...new Set(rows.map((job) => job.customer_id))]
    const partnerIds = [...new Set(rows.map((job) => job.partner_id).filter((id): id is string => Boolean(id)))]
    const [{ data: customers }, { data: partners }] = await Promise.all([
      customerIds.length ? supabase.from('customers').select('id, company_name').in('id', customerIds) : Promise.resolve({ data: [], error: null }),
      partnerIds.length ? supabase.from('logistics_partners').select('id, partner_name').in('id', partnerIds) : Promise.resolve({ data: [], error: null }),
    ])
    const financials = new Map((financialResult.data ?? []).map((item) => [item.job_id, {
      customer_revenue: Number(item.customer_revenue), partner_cost: Number(item.partner_cost),
      other_direct_cost: Number(item.other_direct_cost), currency: String(item.currency),
    }]))
    const customerNames = new Map((customers ?? []).map((item) => [item.id, item.company_name]))
    const partnerNames = new Map((partners ?? []).map((item) => [item.id, item.partner_name]))
    const payments = (paymentResult.data ?? []) as unknown as FinanceJob['payments']
    const settlements = (settlementResult.data ?? []) as unknown as FinanceJob['settlements']
    setJobs(rows.map((job) => ({
      ...job,
      customer_name: customerNames.get(job.customer_id),
      partner_name: job.partner_id ? partnerNames.get(job.partner_id) : undefined,
      financials: financials.get(job.id),
      payments: payments.filter((payment) => payment.job_id === job.id),
      settlements: settlements.filter((settlement) => settlement.job_id === job.id),
    })))
    setLoading(false)
  }, [onError, supabase])

  useEffect(() => {
    const timer = window.setTimeout(() => { void loadFinance() }, 0)
    return () => window.clearTimeout(timer)
  }, [loadFinance])

  async function submitFinanceAction(event: FormEvent<HTMLFormElement>, job: FinanceJob, action: 'financials' | 'payment' | 'settlement') {
    event.preventDefault()
    if (!canRecord || busyKey) return
    const form = new FormData(event.currentTarget)
    setBusyKey(job.id)
    onError('')
    const result = action === 'financials'
      ? await supabase.rpc('save_job_financials', {
        p_job_id: job.id,
        p_partner_cost: Number(form.get('partner_cost')),
        p_other_direct_cost: Number(form.get('other_direct_cost')),
      })
      : action === 'payment'
        ? await supabase.rpc('record_customer_payment', {
          p_job_id: job.id,
          p_amount: Number(form.get('amount')),
          p_method: String(form.get('method')),
          p_reference: String(form.get('reference')),
          p_notes: String(form.get('notes') || '') || null,
        })
        : await supabase.rpc('create_partner_settlement', {
          p_job_id: job.id,
          p_amount: Number(form.get('amount')),
          p_request_reference: String(form.get('reference')),
          p_notes: String(form.get('notes') || '') || null,
        })
    if (result.error) onError(result.error.message)
    else {
      onNotice(action === 'financials' ? `Financials saved for ${job.job_number}.` : action === 'payment' ? `Customer receipt recorded for ${job.job_number}.` : `Partner settlement created for ${job.job_number}.`)
      await loadFinance()
    }
    setBusyKey('')
  }

  async function updateSettlement(job: FinanceJob, settlement: FinanceJob['settlements'][number], status: 'approved' | 'paid' | 'cancelled') {
    if (busyKey || (status === 'approved' && !canApprove) || (status === 'paid' && !canPay)) return
    let reference: string | null = null
    if (status === 'paid') {
      reference = window.prompt('Enter the bank transfer reference before marking this settlement paid:')
      if (!reference?.trim()) return
    }
    setBusyKey(settlement.id)
    const { error } = await supabase.rpc('update_partner_settlement_status', {
      p_settlement_id: settlement.id, p_status: status, p_reference: reference,
    })
    if (error) onError(error.message)
    else { onNotice(`${settlement.settlement_number} marked ${status}.`); await loadFinance() }
    setBusyKey('')
    void job
  }

  async function reversePayment(payment: FinanceJob['payments'][number]) {
    const reason = window.prompt('Enter the reason for reversing this customer receipt (10 to 500 characters):')
    if (!reason?.trim()) return
    setBusyKey(payment.id)
    const { error } = await supabase.rpc('reverse_customer_payment', { p_payment_id: payment.id, p_reason: reason.trim() })
    if (error) onError(error.message)
    else { onNotice(`${payment.payment_number} reversed.`); await loadFinance() }
    setBusyKey('')
  }

  const formatMoney = (amount: number, currency: string) => new Intl.NumberFormat('en-NG', { style: 'currency', currency, maximumFractionDigits: 2 }).format(amount)

  return <main className="finance-page">
    <div className="dashboard-heading"><div><p className="eyebrow">KWIK-PARSEL FINANCE</p><h1>Finance desk</h1><p className="section-intro">Track job margins, customer receipts, and partner payouts. Record actual transfers manually; no payment gateway is connected.</p></div><button className="secondary-button" onClick={() => { onError(''); void loadFinance() }} disabled={loading}>Refresh financials</button></div>
    {!canRecord && <div className="role-preview-banner">Preview only: finance records and actions require Finance, Management, or Admin access.</div>}
    {(canApprove || canPay) && <CommissionPayoutPanel supabase={supabase} userId={userId} canReview={canApprove} canPay={canPay} onError={onError} onNotice={onNotice} />}
    {canApprove && <><CommissionPlansPanel supabase={supabase} canManage={canApprove} onError={onError} onNotice={onNotice} /><MarketerCommissionPlansPanel supabase={supabase} canManage={canApprove} onError={onError} onNotice={onNotice} /><BdoMarketerSharePlansPanel supabase={supabase} canManage={canApprove} onError={onError} onNotice={onNotice} /></>}
    <section className="finance-summary" aria-label="Financial summary">{totals.length === 0 ? <p className="finance-empty">Financial totals will appear when job financials are recorded.</p> : totals.map((total) => <div className="finance-currency-group" key={total.currency}><h2>{total.currency} totals</h2><p className="finance-form-note">All recorded financial jobs</p><div className="finance-kpis"><article><span>Customer revenue</span><strong>{formatMoney(Number(total.customer_revenue),total.currency)}</strong></article><article><span>Received</span><strong>{formatMoney(Number(total.received),total.currency)}</strong></article><article><span>Outstanding</span><strong>{formatMoney(Number(total.outstanding),total.currency)}</strong></article><article><span>Partner cost</span><strong>{formatMoney(Number(total.partner_cost),total.currency)}</strong></article><article><span>Gross profit</span><strong>{formatMoney(Number(total.gross_profit),total.currency)}</strong></article><article><span>Unpaid settlements</span><strong>{formatMoney(Number(total.settlements_due),total.currency)}</strong></article></div></div>)}</section>
    {loading ? <div className="loading finance-loading">Loading finance records...</div> : jobs.length === 0 ? <section className="form-card finance-empty"><h2>No jobs yet</h2><p>Confirmed delivery jobs will appear here for finance tracking.</p></section> : <section className="finance-job-list" aria-label="Job financial records">{jobs.map((job) => {
      const financials = job.financials ?? { customer_revenue: 0, partner_cost: 0, other_direct_cost: 0, currency: 'NGN' }
      const paid = job.payments.filter((payment) => payment.status === 'received').reduce((sum, payment) => sum + Number(payment.amount), 0)
      const grossProfit = financials.customer_revenue - financials.partner_cost - financials.other_direct_cost
      return <article className="form-card finance-job-card" key={job.id}>
        <div className="finance-job-heading"><div><p className="eyebrow">{job.job_number}</p><h2>{job.customer_name ?? 'Customer'}</h2><p>{job.partner_name ? `Partner: ${job.partner_name}` : 'Partner not assigned'} ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· {formatStatus(job.status)}</p></div><div className="finance-job-margin"><small>Gross profit</small><strong>{formatMoney(grossProfit, financials.currency)}</strong></div></div>
        <div className="finance-job-totals"><span>Revenue <strong>{formatMoney(financials.customer_revenue,financials.currency)}</strong></span><span>Received <strong>{formatMoney(paid,financials.currency)}</strong></span><span>Outstanding <strong>{formatMoney(Math.max(0,financials.customer_revenue-paid),financials.currency)}</strong></span><span>Partner cost <strong>{formatMoney(financials.partner_cost,financials.currency)}</strong></span></div>
        <details className="finance-edit-details"><summary>Manage job financials and records</summary>
          <form className="finance-form" onSubmit={(event) => void submitFinanceAction(event,job,'financials')}>
            <h3>Job costs</h3><p className="finance-form-note">Revenue and currency come from the confirmed order ({financials.currency}) and are read-only here.</p><div className="finance-field-grid"><Field label="Partner cost" name="partner_cost" type="number" min="0" defaultValue={financials.partner_cost} required /><Field label="Other direct costs" name="other_direct_cost" type="number" min="0" defaultValue={financials.other_direct_cost} required /></div><button className="secondary-button" disabled={!canRecord || busyKey===job.id}>Save job costs</button>
          </form>
          <form className="finance-form" onSubmit={(event) => void submitFinanceAction(event,job,'payment')}><h3>Record customer receipt</h3><div className="finance-field-grid"><Field label={`Amount (${financials.currency})`} name="amount" type="number" min="0.01" required /><label className="field"><span>Payment method</span><select name="method" defaultValue="bank_transfer"><option value="bank_transfer">Bank transfer</option><option value="cash">Cash</option><option value="pos">POS</option><option value="online">Online transfer</option><option value="other">Other</option></select></label><Field label="Receipt or transaction reference" name="reference" required /><Field label="Notes" name="notes" /></div><button className="secondary-button" disabled={!canRecord || busyKey===job.id}>Record receipt</button></form>
          {job.partner_id && ['delivered','closed'].includes(job.status) && <form className="finance-form" onSubmit={(event) => void submitFinanceAction(event,job,'settlement')}><h3>Create partner settlement</h3><div className="finance-field-grid"><Field label={`Amount (${financials.currency})`} name="amount" type="number" min="0.01" required /><Field label="Unique settlement request reference" name="reference" required /><Field label="Notes" name="notes" /></div><button className="secondary-button" disabled={!canRecord || busyKey===job.id}>Create settlement</button></form>}
          {job.payments.length > 0 && <div className="finance-record-list"><h3>Customer receipts</h3>{job.payments.map((payment) => <p key={payment.id}><strong>{payment.payment_number}</strong> ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· {formatMoney(Number(payment.amount),payment.currency)} ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· {payment.method.replaceAll('_',' ')}{payment.reference ? ` ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· ${payment.reference}` : ''} ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· {payment.status==='reversed' ? `Reversed: ${payment.reversal_reason}` : <button className="text-button finance-cancel" disabled={!canRecord || busyKey===payment.id} onClick={() => void reversePayment(payment)}>Reverse</button>}</p>)}</div>}
          {job.settlements.length > 0 && <div className="finance-record-list"><h3>Partner settlements</h3>{job.settlements.map((settlement) => <div className="finance-settlement-row" key={settlement.id}><p><strong>{settlement.settlement_number}</strong> ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· {formatMoney(Number(settlement.amount),settlement.currency)} ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· <span className={`finance-status finance-status-${settlement.status}`}>{settlement.status}</span> ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· Request {settlement.request_reference}{settlement.reference ? ` ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· Transfer ${settlement.reference}` : ''}</p><div>{settlement.status==='pending' && <><button className="text-button" disabled={!canApprove || settlement.created_by===userId || busyKey===settlement.id} onClick={() => void updateSettlement(job,settlement,'approved')}>Approve</button><button className="text-button finance-cancel" disabled={!canRecord || busyKey===settlement.id} onClick={() => void updateSettlement(job,settlement,'cancelled')}>Cancel</button></>}{settlement.status==='approved' && <><button className="text-button" disabled={!canPay || settlement.approved_by===userId || busyKey===settlement.id} onClick={() => void updateSettlement(job,settlement,'paid')}>Mark paid</button><button className="text-button finance-cancel" disabled={!canRecord || busyKey===settlement.id} onClick={() => void updateSettlement(job,settlement,'cancelled')}>Cancel</button></>}</div></div>)}</div>}
        </details>
      </article>
    })}</section>}
  </main>
}

type BdoLead = { id:string; lead_number:string; business_name:string; contact_person:string; phone:string; email:string|null; city:string|null; state:string|null; business_type:string|null; lead_source:string|null; assigned_bdo_id:string; service_interest:string|null; opportunity_value:number|null; stage:string; next_action:string|null; follow_up_at:string|null; notes:string|null; outcome:string|null; converted_customer_id:string|null; updated_at:string }
type BdoPartnerProspect = { id:string; prospect_number:string; partner_name:string; contact_person:string; phone:string; email:string|null; city:string|null; state:string|null; service_type:string|null; coverage_areas:string[]; capacity_notes:string|null; assigned_bdo_id:string; status:string; next_action:string|null; follow_up_at:string|null; notes:string|null; converted_partner_id:string|null; latitude:number|null; longitude:number|null; location_accuracy_metres:number|null; location_captured_at:string|null }
type BdoActivity = { id:string; activity_number:string; lead_id:string|null; customer_id:string|null; partner_prospect_id:string|null; activity_type:string; subject:string; details:string|null; happened_at:string; created_by:string }
type BdoReport = { id:string; report_number:string; period_start:string; period_end:string; leads_created:number; meetings:number; proposals:number; won_opportunities:number; partner_prospects:number; summary:string; submitted_at:string }
type BdoMetrics = { assigned_leads:number; followups_due:number; meetings_this_week:number; proposals:number; won_opportunities:number; assigned_customers:number; partner_prospects:number; activities_this_week:number; won_opportunity_value:number }
type BdoPartnerProgress = { partner_prospect_id:string; application_status:string|null; email_confirmed:boolean; verification_document_submitted:boolean }
type BdoNotification = { id:string; title:string; body:string; created_at:string }
const nigeriaStates = ['Abia','Adamawa','Akwa Ibom','Anambra','Bauchi','Bayelsa','Benue','Borno','Cross River','Delta','Ebonyi','Edo','Ekiti','Enugu','FCT','Gombe','Imo','Jigawa','Kaduna','Kano','Katsina','Kebbi','Kogi','Kwara','Lagos','Nasarawa','Niger','Ogun','Ondo','Osun','Oyo','Plateau','Rivers','Sokoto','Taraba','Yobe','Zamfara']

function BusinessDevelopmentConsole({ supabase, userId, canManage, isBdo, onError, onNotice }: {
  supabase: ReturnType<typeof getSupabaseClient>
  userId: string
  canManage: boolean
  isBdo: boolean
  onError: (message:string)=>void
  onNotice: (message:string)=>void
}) {
  const [leads,setLeads]=useState<BdoLead[]>([])
  const [prospects,setProspects]=useState<BdoPartnerProspect[]>([])
  const [customers,setCustomers]=useState<Array<{id:string;customer_number:string;company_name:string;assigned_bdo_id:string|null;status:string;referred_by_marketer_id:string|null;created_at:string}>>([])
  const [activities,setActivities]=useState<BdoActivity[]>([])
  const [reports,setReports]=useState<BdoReport[]>([])
  const [bdoStaff,setBdoStaff]=useState<Array<{id:string;name:string}>>([])
  const [metrics,setMetrics]=useState<BdoMetrics|null>(null)
  const [partnerProgress,setPartnerProgress]=useState<Record<string,BdoPartnerProgress>>({})
  const [partnerProgressReady,setPartnerProgressReady]=useState(false)
  const [partnerNotifications,setPartnerNotifications]=useState<BdoNotification[]>([])
  const [referralCode,setReferralCode]=useState('')
  const [busy,setBusy]=useState(false)
  const [loading,setLoading]=useState(true)
  const [partnerLocation,setPartnerLocation]=useState<PositionFix|null>(null)
  const [partnerSignupLinks,setPartnerSignupLinks]=useState<Record<string,string>>({})
  const [locationBusy,setLocationBusy]=useState(false)
  const load=useCallback(async()=>{
    setLoading(true)
    const [leadResult,prospectResult,customerResult,activityResult,reportResult,metricResult]=await Promise.all([
      supabase.from('leads_opportunities').select('*').order('updated_at',{ascending:false}).limit(100),
      supabase.from('partner_prospects').select('*').order('updated_at',{ascending:false}).limit(100),
      supabase.from('customers').select('id, customer_number, company_name, assigned_bdo_id, status, referred_by_marketer_id, created_at').not('assigned_bdo_id','is',null).order('created_at',{ascending:false}).limit(100),
      supabase.from('business_development_activities').select('*').order('happened_at',{ascending:false}).limit(50),
      supabase.from('business_development_reports').select('*').order('period_start',{ascending:false}).limit(12),
      supabase.rpc('business_development_dashboard'),
    ])
    const error=leadResult.error??prospectResult.error??customerResult.error??activityResult.error??reportResult.error??metricResult.error
    if(error) onError(error.message)
    setLeads((leadResult.data??[]) as BdoLead[])
    setProspects((prospectResult.data??[]) as BdoPartnerProspect[])
    setCustomers((customerResult.data??[]) as Array<{id:string;customer_number:string;company_name:string;assigned_bdo_id:string|null;status:string;referred_by_marketer_id:string|null;created_at:string}>)
    setActivities((activityResult.data??[]) as BdoActivity[])
    setReports((reportResult.data??[]) as BdoReport[])
    const progressResult=await supabase.rpc('list_my_partner_prospect_progress')
    if(progressResult.error)onError(progressResult.error.message)
    setPartnerProgressReady(!progressResult.error)
    setPartnerProgress(Object.fromEntries(((progressResult.data??[]) as BdoPartnerProgress[]).map((item)=>[item.partner_prospect_id,item])))
    if(isBdo){
      const {data:notificationData,error:notificationError}=await supabase.from('notifications').select('id,title,body,created_at').eq('user_id',userId).eq('event_type','bdo_partner_application_review').order('created_at',{ascending:false}).limit(10)
      if(notificationError)onError(notificationError.message)
      setPartnerNotifications((notificationData??[]) as BdoNotification[])
    }
    const metricRows=(metricResult.data??[]) as BdoMetrics[]
    setMetrics(metricRows[0]??null)
    if(isBdo){
      const {data:code,error:codeError}=await supabase.rpc('get_my_bdo_referral_code')
      if(codeError)onError(codeError.message)
      setReferralCode(typeof code==='string'?code:'')
    }
    if(canManage){
      const {data,error:staffError}=await supabase.from('user_roles').select('user_id').eq('role','bdo')
      if(staffError) onError(staffError.message)
      const staffRows=data??[]
      const {data:profileRows,error:profileError}=staffRows.length?await supabase.from('profiles').select('user_id,full_name,email').in('user_id',staffRows.map((row:any)=>row.user_id)):{data:[],error:null}
      if(profileError)onError(profileError.message)
      setBdoStaff(staffRows.map((row:any)=>{const profile=(profileRows??[]).find((entry:any)=>entry.user_id===row.user_id);return{id:row.user_id,name:profile?.full_name||profile?.email||row.user_id}}))
    }else setBdoStaff([{id:userId,name:'Myself'}])
    setLoading(false)
  },[canManage,isBdo,onError,supabase,userId])

  useEffect(()=>{const timer=window.setTimeout(()=>{void load()},0);return()=>window.clearTimeout(timer)},[load])

  async function createLead(event:FormEvent<HTMLFormElement>){
    event.preventDefault();const formElement=event.currentTarget;const form=new FormData(formElement);setBusy(true);onError('')
    const assigned=isBdo?userId:String(form.get('assigned_bdo_id')||'')
    const firstFollowUp = new Date(); firstFollowUp.setDate(firstFollowUp.getDate()+7)
    const {error}=await supabase.from('leads_opportunities').insert({business_name:String(form.get('business_name')),contact_person:String(form.get('contact_person')),phone:String(form.get('phone')),email:String(form.get('email')||'')||null,city:String(form.get('city')||'')||null,state:String(form.get('state')||'')||null,business_type:String(form.get('business_type')||'')||null,lead_source:String(form.get('lead_source')||'referral'),assigned_bdo_id:assigned,service_interest:String(form.get('service_interest')||'')||null,opportunity_value:null,next_action:'Initial contact',follow_up_at:firstFollowUp.toISOString().slice(0,10),notes:null,created_by:userId})
    if(error) onError(error.message);else{onNotice('Lead added to the assigned pipeline.');formElement.reset();await load()}setBusy(false)
  }
  async function createProspect(event:FormEvent<HTMLFormElement>){
    event.preventDefault();const formElement=event.currentTarget;const form=new FormData(formElement);setBusy(true);onError('')
    const firstFollowUp = new Date(); firstFollowUp.setDate(firstFollowUp.getDate()+7)
    const {data,error}=await supabase.from('partner_prospects').insert({partner_name:String(form.get('partner_name')),contact_person:String(form.get('contact_person')),phone:String(form.get('phone')),email:String(form.get('email')||'')||null,city:String(form.get('city')||'')||null,state:String(form.get('state')||'')||null,service_type:String(form.get('service_type')||'')||null,coverage_areas:[],capacity_notes:null,assigned_bdo_id:isBdo?userId:String(form.get('assigned_bdo_id')||''),next_action:'Initial outreach',follow_up_at:firstFollowUp.toISOString().slice(0,10),notes:null,latitude:partnerLocation?.latitude??null,longitude:partnerLocation?.longitude??null,location_accuracy_metres:partnerLocation?.accuracyMetres??null,location_captured_at:partnerLocation?new Date(partnerLocation.capturedAt).toISOString():null,created_by:userId}).select('id').single()
    if(error) onError(error.message);else{formElement.reset();setPartnerLocation(null);if(data?.id){const invite=await supabase.rpc('create_partner_prospect_invite',{p_prospect_id:data.id});if(invite.error)onError(`Partner prospect saved, but no signup link was created: ${invite.error.message}`);else{setPartnerSignupLinks((current)=>({...current,[String(data.id)]:`${publicAppOrigin}/?partner_prospect_invite=${encodeURIComponent(String(invite.data))}`}));onNotice('Partner prospect recorded and a secure signup link created.')}}else onNotice('Potential partner added for development.');await load()}setBusy(false)
  }
  async function createPartnerSignupLink(prospectId:string){setBusy(true);const {data,error}=await supabase.rpc('create_partner_prospect_invite',{p_prospect_id:prospectId});if(error)onError(error.message);else setPartnerSignupLinks((current)=>({...current,[prospectId]:`${publicAppOrigin}/?partner_prospect_invite=${encodeURIComponent(String(data))}`}));setBusy(false)}
  async function copyPartnerSignupLink(prospectId:string){const link=partnerSignupLinks[prospectId];if(!link)return;try{await navigator.clipboard.writeText(link);onNotice('Partner signup link copied. Their application will be connected to this BDO prospect.')}catch{onError('Copy failed. Select and copy the partner signup link.') }}
  async function capturePartnerLocation(){
    setLocationBusy(true);onError('')
    try{const position=await requestPosition();setPartnerLocation(position);onNotice('Partner premises location captured. Confirm the contact agreed to share it.')}catch(error){onError(error instanceof Error?error.message:'Could not capture the partner location.')}finally{setLocationBusy(false)}
  }
  async function copyReferralLink(){
    if(!referralCode)return
    const link=`${publicAppOrigin}/?ref=${encodeURIComponent(referralCode)}`
    try{await navigator.clipboard.writeText(link);onNotice('Your customer referral link was copied. Signups through it will be attributed to your BDO account.')}
    catch{onError('Could not copy the referral link. Copy it from the link field instead.')}
  }
  async function changeLeadStage(lead:BdoLead,stage:string){
    if(stage==='won'){onError('Convert the opportunity to a customer to mark it won.');return}
    setBusy(true);const {error}=await supabase.rpc('update_business_lead',{p_lead_id:lead.id,p_stage:stage,p_next_action:lead.next_action,p_follow_up_at:lead.follow_up_at,p_notes:lead.notes,p_outcome:lead.outcome,p_opportunity_value:lead.opportunity_value})
    if(error) onError(error.message);else{onNotice(`${lead.lead_number} moved to ${stage}.`);await load()}setBusy(false)
  }
  async function updateLeadDetails(event:FormEvent<HTMLFormElement>,lead:BdoLead){
    event.preventDefault();const form=new FormData(event.currentTarget);const followUpDate=new Date();followUpDate.setDate(followUpDate.getDate()+Number(form.get('follow_up_days')||7));setBusy(true);const {error}=await supabase.rpc('update_business_lead',{p_lead_id:lead.id,p_stage:lead.stage,p_next_action:String(form.get('next_action')||'follow up'),p_follow_up_at:followUpDate.toISOString().slice(0,10),p_notes:lead.notes,p_outcome:lead.outcome,p_opportunity_value:lead.opportunity_value,p_replace_details:true})
    if(error)onError(error.message);else{onNotice(`${lead.lead_number} details saved.`);await load()}setBusy(false)
  }
  async function reassignLead(lead:BdoLead,assignedBdoId:string){
    setBusy(true);const {error}=await supabase.rpc('update_business_lead',{p_lead_id:lead.id,p_stage:lead.stage,p_next_action:lead.next_action,p_follow_up_at:lead.follow_up_at,p_notes:lead.notes,p_outcome:lead.outcome,p_opportunity_value:lead.opportunity_value,p_assigned_bdo_id:assignedBdoId})
    if(error)onError(error.message);else{onNotice(`${lead.lead_number} reassigned.`);await load()}setBusy(false)
  }
  async function convertLead(lead:BdoLead){
    if(!window.confirm(`Convert ${lead.business_name} into a Kwik-Parsel customer?`))return
    setBusy(true);const {data,error}=await supabase.rpc('convert_business_lead_to_customer',{p_lead_id:lead.id,p_customer_type:lead.business_type||'business'})
    if(error)onError(error.message);else{onNotice(`${data?.customer_number??lead.business_name} is now a customer.`);await load()}setBusy(false)
  }
  async function changeProspectStatus(prospect:BdoPartnerProspect,status:string){
    setBusy(true);const {error}=await supabase.rpc('update_partner_prospect',{p_prospect_id:prospect.id,p_status:status,p_next_action:prospect.next_action,p_follow_up_at:prospect.follow_up_at,p_notes:prospect.notes})
    if(error)onError(error.message);else{onNotice(`${prospect.prospect_number} updated.`);await load()}setBusy(false)
  }
  async function approveProspect(prospect:BdoPartnerProspect){
    if(!window.confirm(`Approve ${prospect.partner_name} for the operational partner network?`))return
    setBusy(true);const {error}=await supabase.rpc('approve_partner_prospect',{p_prospect_id:prospect.id})
    if(error)onError(error.message);else{onNotice(`${prospect.partner_name} approved as a pending partner.`);await load()}setBusy(false)
  }
  async function recordActivity(event:FormEvent<HTMLFormElement>){
    event.preventDefault();const formElement=event.currentTarget;const form=new FormData(formElement);const [kind,id]=String(form.get('entity')||'').split(':');if(!id){onError('Select a lead, customer, or partner prospect.');return}
    const activityType=String(form.get('activity_type'));const selectedRecord=kind==='lead'?leads.find((row)=>row.id===id)?.lead_number+' - '+leads.find((row)=>row.id===id)?.business_name:kind==='customer'?customers.find((row)=>row.id===id)?.customer_number+' - '+customers.find((row)=>row.id===id)?.company_name:prospects.find((row)=>row.id===id)?.prospect_number+' - '+prospects.find((row)=>row.id===id)?.partner_name
    setBusy(true);const {error}=await supabase.rpc('record_business_development_activity',{p_activity_type:activityType,p_subject:`${activityType.replaceAll('_',' ')}: ${selectedRecord||'selected record'}`,p_details:String(form.get('details')||'')||null,p_happened_at:new Date().toISOString(),p_next_action:null,p_follow_up_at:null,p_lead_id:kind==='lead'?id:null,p_customer_id:kind==='customer'?id:null,p_partner_prospect_id:kind==='partner'?id:null})
    if(error)onError(error.message);else{onNotice('Business development activity recorded.');formElement.reset();await load()}setBusy(false)
  }
  async function submitReport(event:FormEvent<HTMLFormElement>){
    event.preventDefault();const formElement=event.currentTarget;const form=new FormData(formElement);const today=new Date();const weekStart=new Date(today);weekStart.setDate(today.getDate()-((today.getDay()+6)%7));const dateValue=(value:Date)=>`${value.getFullYear()}-${String(value.getMonth()+1).padStart(2,'0')}-${String(value.getDate()).padStart(2,'0')}`;const status=String(form.get('report_status'));const blockers=form.getAll('report_blocker').map(String);const summary=`Weekly report status: ${status.replaceAll('_',' ')}. Blockers: ${blockers.length?blockers.join(', '):'none reported'}.`;setBusy(true);const {data,error}=await supabase.rpc('submit_business_development_report',{p_period_start:dateValue(weekStart),p_period_end:dateValue(today),p_summary:summary})
    if(error)onError(error.message);else{onNotice(`Report ${data?.report_number??''} submitted.`);formElement.reset();await load()}setBusy(false)
  }

  const metricItems=metrics?[['Assigned leads',metrics.assigned_leads],['Follow-ups due',metrics.followups_due],['Meetings this week',metrics.meetings_this_week],['Proposals',metrics.proposals],['Won opportunities',metrics.won_opportunities],['Assigned customers',metrics.assigned_customers],['Partner prospects',metrics.partner_prospects],['Activities this week',metrics.activities_this_week]] as Array<[string,number]>:[]
  return <main className="dashboard bdo-page">
    <div className="dashboard-heading"><div><p className="eyebrow">PHASE 6 ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· BUSINESS DEVELOPMENT</p><h1>BDO workspace</h1><p className="section-intro">Manage assigned prospects and customer relationships, log activities, and develop potential logistics partners. Delivery execution, pricing, finance, and partner approval stay with authorised teams.</p></div><button className="secondary-button" onClick={()=>void load()} disabled={loading}>Refresh pipeline</button></div>
    {canManage&&!isBdo&&<div className="role-preview-banner">Management view: you are reviewing team pipelines. A personal referral link appears only when signed in to an approved BDO account.</div>}
    {isBdo && <BdoTransparencyPanel supabase={supabase} onError={onError} />}
    {isBdo && <><section className="form-card referral-link-panel"><p className="eyebrow">CUSTOMER REFERRALS</p><h2>Your customer referral link</h2><p className="section-intro">Share this link with a new customer. Their account will be attributed to you after signup and email confirmation.</p><div className="field-row"><label className="field"><span>Shareable link</span><input aria-label="Personal referral link" readOnly value={referralCode?`${publicAppOrigin}/?ref=${referralCode}`:'Generating your link...'} /></label><button className="primary-button" disabled={!referralCode} onClick={()=>void copyReferralLink()}>Copy referral link</button></div><small>Link destination is the public Kwik-Parsel site, even when you are testing locally.</small></section>{partnerNotifications.length>0&&<section className="notification-panel" aria-label="Partner application updates"><div className="history-heading"><div><p className="eyebrow">REFERRAL UPDATES</p><h2>Partner application updates</h2></div><span className="request-count">{partnerNotifications.length}</span></div><div className="notification-list">{partnerNotifications.map((notification)=><article className="notification-item" key={notification.id}><div className="notification-copy"><strong>{notification.title}</strong><p>{notification.body}</p><small>{new Intl.DateTimeFormat('en-NG',{dateStyle:'medium',timeStyle:'short'}).format(new Date(notification.created_at))}</small></div></article>)}</div></section>}<BDOMarketersPanel supabase={supabase} onError={onError} onNotice={onNotice} /> </>}
    <section className="finance-kpis bdo-kpis" aria-label="Business Development dashboard">{metricItems.map(([label,value])=><article key={label}><span>{label}</span><strong>{Number(value).toLocaleString('en-NG')}</strong></article>)}{metrics&&<article><span>Estimated value of won opportunities</span><strong>{new Intl.NumberFormat('en-NG',{style:'currency',currency:'NGN',maximumFractionDigits:0}).format(Number(metrics.won_opportunity_value))}</strong></article>}</section>
    <p className="finance-form-note">Opportunity values are estimates for pipeline tracking only. They do not determine revenue, profit, commissions, or payouts.</p>
    {isBdo && <section className="history-panel bdo-pipeline"><div className="history-heading"><div><p className="eyebrow">CUSTOMERS YOU INTRODUCED</p><h2>Customer attribution</h2></div><span className="request-count">{customers.length}</span></div>{customers.length===0?<p className="notification-empty">No customer signups are attributed to you yet. New customers who register through your referral link will appear here automatically.</p>:<div className="request-list">{customers.map((customer)=><article className="request-item" key={customer.id}><div className="request-item-top"><strong>{customer.customer_number} ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· {customer.company_name}</strong><span className={`finance-status finance-status-${customer.status}`}>{customer.status.replaceAll('_',' ')}</span></div><small>{customer.referred_by_marketer_id?'Referred by a marketer in your network':'Direct BDO referral or converted lead'} ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· Joined {new Intl.DateTimeFormat('en-NG',{dateStyle:'medium'}).format(new Date(customer.created_at))}</small></article>)}</div>}</section>}
    <div className="dashboard-grid bdo-grid">
      <details className="form-card bdo-collapsible"><summary><strong>Add a lead</strong><small>Business, contact and service</small></summary><div className="bdo-collapsible-body"><form className="form-grid" onSubmit={(event)=>void createLead(event)}><Field label="Business name" name="business_name" required /><div className="field-row"><Field label="Contact person" name="contact_person" required /><Field label="Phone" name="phone" type="tel" required /></div><div className="field-row"><Field label="Email (optional)" name="email" type="email" /><label className="field"><span>Business type</span><select name="business_type"><option value="business">Business</option><option value="retailer">Retailer</option><option value="ecommerce">Online seller</option><option value="manufacturer">Manufacturer</option><option value="wholesaler">Wholesaler</option><option value="individual">Individual</option><option value="other">Other</option></select></label></div><div className="field-row"><Field label="City" name="city" /><label className="field"><span>State</span><select name="state"><option value="">Choose a state</option>{nigeriaStates.map((state)=><option key={state} value={state}>{state}</option>)}</select></label></div><div className="field-row"><label className="field"><span>How did you meet them?</span><select name="lead_source"><option value="referral">Referral</option><option value="field visit">Field visit</option><option value="phone">Phone call</option><option value="social media">Social media</option><option value="event">Event</option><option value="other">Other</option></select></label><label className="field"><span>Service interest</span><select name="service_interest"><option value="">Choose if known</option><option value="local delivery">Local delivery</option><option value="interstate delivery">Interstate delivery</option><option value="warehouse fulfillment">Warehouse fulfillment</option><option value="document transport">Document transport</option><option value="other">Other</option></select></label></div><p className="form-footnote">We will schedule the first follow-up for seven days from today. Estimated opportunity values are omitted because they do not affect earnings or payouts.</p>{canManage&&!isBdo&&<label className="field"><span>Assign to BDO</span><select name="assigned_bdo_id" required defaultValue=""><option value="" disabled>Select a BDO</option>{bdoStaff.map((staff)=><option key={staff.id} value={staff.id}>{staff.name}</option>)}</select></label>}<button className="primary-button" disabled={busy||canManage&&!isBdo&&bdoStaff.length===0}>{busy?'Saving...':'Add lead'}</button></form></div></details>
      <details className="form-card bdo-collapsible"><summary><strong>Potential logistics partner</strong><small>Company, contact, service and optional GPS</small></summary><div className="bdo-collapsible-body"><p className="finance-form-note">This record is automatically tied to your BDO account. The partner gets a secure signup link and stays unavailable to Operations until Super Admin approval.</p><form className="form-grid" onSubmit={(event)=>void createProspect(event)}><Field label="Partner or company name" name="partner_name" required /><div className="field-row"><Field label="Contact person" name="contact_person" required /><Field label="Phone" name="phone" type="tel" required /></div><div className="field-row"><Field label="Email" name="email" type="email" /><label className="field"><span>Partner type</span><select name="service_type"><option value="courier">Courier company</option><option value="dispatch">Dispatch riders</option><option value="interstate_transport">Interstate transport</option><option value="bus_operator">Bus operator</option><option value="warehouse">Warehouse</option><option value="other">Other</option></select></label></div><div className="field-row"><Field label="City" name="city" /><label className="field"><span>State</span><select name="state"><option value="">Choose a state</option>{nigeriaStates.map((state)=><option key={state} value={state}>{state}</option>)}</select></label></div><div className="partner-location-capture"><button type="button" className="secondary-button" disabled={locationBusy || busy} onClick={() => void capturePartnerLocation()}>{locationBusy ? 'Getting location...' : partnerLocation ? 'Refresh partner GPS location' : 'Capture partner GPS location'}</button><p className="form-footnote">Capture this device at the partner premises, with the contact's permission. Browser or app GPS will be used.</p>{partnerLocation && <p role="status">Captured {partnerLocation.latitude.toFixed(6)}, {partnerLocation.longitude.toFixed(6)} Accuracy: {Math.round(partnerLocation.accuracyMetres)} m</p>}</div><p className="form-footnote">We will schedule the first follow-up for seven days from today. You can add capacity details later if needed.</p>{canManage&&!isBdo&&<label className="field"><span>Assign to BDO</span><select name="assigned_bdo_id" required defaultValue=""><option value="" disabled>Select a BDO</option>{bdoStaff.map((staff)=><option key={staff.id} value={staff.id}>{staff.name}</option>)}</select></label>}<button className="primary-button" disabled={busy||canManage&&!isBdo&&bdoStaff.length===0}>{busy?'Saving...':'Add potential partner'}</button></form></div></details>
    </div>
    <section className="history-panel bdo-pipeline"><div className="history-heading"><div><p className="eyebrow">LEADS & OPPORTUNITIES</p><h2>Assigned pipeline</h2></div><span className="request-count">{leads.length}</span></div>{loading?<div className="loading">Loading assigned pipeline...</div>:leads.length===0?<p className="notification-empty">No leads in this pipeline yet.</p>:<div className="request-list">{leads.map((lead)=><article className="request-item bdo-record" key={lead.id}><div className="request-item-top"><strong>{lead.lead_number} ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· {lead.business_name}</strong><span className={`finance-status finance-status-${lead.stage}`}>{lead.stage}</span></div><p>{lead.contact_person} ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· {lead.phone}{lead.email?` ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· ${lead.email}`:''}{lead.city?` ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· ${lead.city}`:''}</p><small>{lead.service_interest||'Service interest not set'}{lead.follow_up_at?` ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· Follow-up ${lead.follow_up_at}`:''}</small>{lead.stage!=='won'&&lead.stage!=='lost'&&<div className="bdo-record-actions"><label className="field"><span>Stage</span><select aria-label={`Stage for ${lead.lead_number}`} value={lead.stage} disabled={busy} onChange={(event)=>void changeLeadStage(lead,event.target.value)}><option value="lead">Lead</option><option value="qualified">Qualified</option><option value="opportunity">Opportunity</option><option value="proposal">Proposal</option><option value="lost">Lost</option></select></label>{['opportunity','proposal'].includes(lead.stage)&&<button className="secondary-button" disabled={busy} onClick={()=>void convertLead(lead)}>Convert to customer</button>}{canManage&&!isBdo&&<label className="field"><span>Assign to BDO</span><select aria-label={`Assign ${lead.lead_number} to BDO`} disabled={busy} value={lead.assigned_bdo_id} onChange={(event)=>void reassignLead(lead,event.target.value)}>{bdoStaff.map((staff)=><option key={staff.id} value={staff.id}>{staff.name}</option>)}</select></label>}<details className="bdo-edit"><summary>Adjust follow-up</summary><form className="form-grid" onSubmit={(event)=>void updateLeadDetails(event,lead)}><label className="field"><span>Next action</span><select name="next_action" defaultValue={lead.next_action||'follow up'}><option value="initial contact">Initial contact</option><option value="call">Call</option><option value="email">Email</option><option value="meeting">Meeting</option><option value="send proposal">Send proposal</option><option value="follow up">Follow up</option></select></label><label className="field"><span>Remind me in</span><select name="follow_up_days" defaultValue="7"><option value="3">3 days</option><option value="7">1 week</option><option value="14">2 weeks</option><option value="30">1 month</option></select></label><button className="secondary-button" disabled={busy}>Save follow-up</button></form></details></div>}{lead.converted_customer_id&&<small>Converted customer {customers.find((customer)=>customer.id===lead.converted_customer_id)?.customer_number||''}</small>}</article>)}</div>}</section>
    <section className="history-panel bdo-pipeline"><div className="history-heading"><div><p className="eyebrow">PARTNER DEVELOPMENT</p><h2>Potential logistics partners</h2></div><span className="request-count">{prospects.length}</span></div>{prospects.length===0?<p className="notification-empty">No partner prospects recorded yet.</p>:<div className="request-list">{prospects.map((prospect)=><article className="request-item bdo-record" key={prospect.id}><div className="request-item-top"><strong>{prospect.prospect_number} ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· {prospect.partner_name}</strong><span className="finance-status">{prospect.status}</span></div><p>{prospect.contact_person} ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· {prospect.phone}{prospect.city?` ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· ${prospect.city}`:''}{prospect.coverage_areas.length?` ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· Coverage: ${prospect.coverage_areas.join(', ')}`:''}</p>{(()=>{const progress=partnerProgress[prospect.id];const status=!partnerProgressReady?'Status unavailable':prospect.converted_partner_id?'Approved partner':!progress?.application_status?'Waiting for partner signup':progress.application_status==='rejected'?'Application not approved':!progress.email_confirmed?'Email confirmation pending':!progress.verification_document_submitted?'NIN/CAC document needed':progress.application_status==='approved'?'Approved partner':'Awaiting Super Admin review';return <p className="form-footnote" aria-label={`Application progress: ${status}`}>Application progress: <strong>{status}</strong></p>})()}{canManage && prospect.latitude !== null && prospect.longitude !== null && <div className="partner-prospect-location"><strong>Captured partner location</strong><p>{prospect.latitude.toFixed(6)}, {prospect.longitude.toFixed(6)} Accuracy: {Math.round(prospect.location_accuracy_metres || 0)} m</p><a href={`https://www.google.com/maps/search/?api=1&query=${prospect.latitude},${prospect.longitude}`} target="_blank" rel="noreferrer">Search location in Google Maps</a></div>}{partnerSignupLinks[prospect.id]?<div className="field-row partner-prospect-invite"><label className="field"><span>Partner signup link</span><input aria-label={`Partner signup link for ${prospect.partner_name}`} readOnly value={partnerSignupLinks[prospect.id]}/></label><button className="secondary-button" onClick={()=>void copyPartnerSignupLink(prospect.id)}>Copy link</button></div>:<button className="secondary-button" disabled={busy||prospect.converted_partner_id!==null} onClick={()=>void createPartnerSignupLink(prospect.id)}>Create partner signup link</button>}{prospect.converted_partner_id?<small>Approved as an operational partner</small>:<div className="bdo-record-actions"><label className="field"><span>Development status</span><select aria-label={`Status for ${prospect.prospect_number}`} value={prospect.status} disabled={busy} onChange={(event)=>void changeProspectStatus(prospect,event.target.value)}><option value="identified">Identified</option><option value="contacted">Contacted</option><option value="assessing">Assessing</option><option value="ready">Ready for approval</option><option value="declined">Declined</option></select></label>{canManage&&prospect.status==='ready'&&<button className="secondary-button" disabled={busy} onClick={()=>void approveProspect(prospect)}>Approve as partner</button>}</div>}</article>)}</div>}</section>
    <div className="dashboard-grid bdo-grid"><details className="form-card bdo-collapsible"><summary><strong>Record an interaction</strong><small>Pick a record and activity type</small></summary><div className="bdo-collapsible-body"><form className="form-grid" onSubmit={(event)=>void recordActivity(event)}><label className="field"><span>Related lead, customer, or partner</span><select name="entity" required defaultValue=""><option value="" disabled>Select a record</option>{leads.map((lead)=><option key={lead.id} value={`lead:${lead.id}`}>Lead ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· {lead.lead_number} ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· {lead.business_name}</option>)}{customers.map((customer)=><option key={customer.id} value={`customer:${customer.id}`}>Customer ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· {customer.customer_number} ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· {customer.company_name}</option>)}{prospects.map((prospect)=><option key={prospect.id} value={`partner:${prospect.id}`}>Partner prospect ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· {prospect.prospect_number} ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· {prospect.partner_name}</option>)}</select></label><label className="field"><span>Activity type</span><select name="activity_type"><option value="call">Call</option><option value="email">Email</option><option value="meeting">Meeting</option><option value="site_visit">Site visit</option><option value="proposal">Proposal</option><option value="follow_up">Follow-up</option><option value="other">Other</option></select></label><details className="bdo-optional-details"><summary>Add a note (optional)</summary><label className="field"><span>Short note</span><textarea name="details" rows={2}/></label></details><p className="form-footnote">The activity time and subject are recorded automatically from this selection.</p><button className="primary-button" disabled={busy}>Record activity</button></form></div></details>
      <details className="form-card bdo-collapsible"><summary><strong>Submit activity report</strong><small>Auto-generated activity totals</small></summary><div className="bdo-collapsible-body"><form className="form-grid" onSubmit={(event)=>void submitReport(event)}><p className="form-footnote">The current week and your saved activity totals are added automatically.</p><label className="field"><span>How is your week going?</span><select name="report_status"><option value="on_track">On track</option><option value="needs_support">I need support</option><option value="blocked">Blocked</option></select></label><fieldset className="bdo-choice-list"><legend>What needs attention? (optional)</legend><label><input type="checkbox" name="report_blocker" value="partner approval"/> Partner approval</label><label><input type="checkbox" name="report_blocker" value="customer response"/> Customer response</label><label><input type="checkbox" name="report_blocker" value="transport capacity"/> Transport capacity</label><label><input type="checkbox" name="report_blocker" value="pricing or quote"/> Pricing or quote</label></fieldset><button className="primary-button" disabled={busy}>Submit report</button></form>{reports.length>0&&<div className="finance-record-list"><h3>Recent reports</h3>{reports.map((report)=><p key={report.id}><strong>{report.report_number}</strong> ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· {report.period_start} to {report.period_end} ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· {report.meetings} meetings ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· {report.won_opportunities} wins</p>)}</div>}</div></details></div>
    <section className="history-panel bdo-pipeline"><div className="history-heading"><div><p className="eyebrow">RECENT BUSINESS DEVELOPMENT ACTIVITY</p><h2>Activity history</h2></div><span className="request-count">{activities.length}</span></div>{activities.length===0?<p className="notification-empty">Interactions and proposals will appear here when recorded.</p>:<div className="request-list">{activities.map((activity)=><article className="request-item" key={activity.id}><div className="request-item-top"><strong>{activity.activity_number} ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· {activity.subject}</strong><span className="finance-status">{activity.activity_type.replaceAll('_',' ')}</span></div><small>{new Intl.DateTimeFormat('en-NG',{dateStyle:'medium',timeStyle:'short'}).format(new Date(activity.happened_at))}{activity.details?` ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· ${activity.details}`:''}</small></article>)}</div>}</section>
  </main>
}

function Field({ label, name, type = 'text', required = false, minLength, autoComplete, placeholder, min, step, defaultValue }: { label: string; name: string; type?: string; required?: boolean; minLength?: number; autoComplete?: string; placeholder?: string; min?: string; step?: string; defaultValue?: string | number }) {
  const id = useId()
  const [visible, setVisible] = useState(false)
  if (type === 'password') return <div className="field"><label htmlFor={id}>{label}</label><div className="password-control"><input id={id} name={name} type={visible ? 'text' : 'password'} required={required} minLength={minLength} autoComplete={autoComplete} defaultValue={defaultValue} /><button type="button" className="password-visibility" aria-label={`${visible ? 'Hide' : 'Show'} ${label.toLowerCase()}`} aria-pressed={visible} onClick={() => setVisible((current) => !current)}><svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M2.25 12s3.5-6 9.75-6 9.75 6 9.75 6-3.5 6-9.75 6-9.75-6Z"/><circle cx="12" cy="12" r="3"/>{visible && <path d="M4 20 20 4"/>}</svg><span>{visible ? 'Hide' : 'Show'}</span></button></div></div>
  return <label className="field"><span>{label}</span><input name={name} type={type} required={required} minLength={minLength} min={min} step={step} autoComplete={autoComplete} placeholder={placeholder} defaultValue={defaultValue} /></label>
}

export default App
