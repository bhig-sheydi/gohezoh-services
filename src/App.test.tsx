import { beforeEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import App from './App'

const mockState = vi.hoisted(() => {
  const state: {
    roles: string[]
    session: { user: { id: string; email: string; user_metadata?: Record<string, unknown> } } | null
    partners: Array<{ id: string; partner_number: string; partner_name: string; status: string }>
    customerRequests: Array<Record<string, unknown>>
    customerOrders: Array<Record<string, unknown>>
    services: Array<Record<string, unknown>>
    coverageLocations: Array<Record<string, unknown>>
    coverageCorridors: Array<Record<string, unknown>>
    notifications: Array<Record<string, unknown>>
    financeFinancials: Array<Record<string, unknown>>
    financePayments: Array<Record<string, unknown>>
    financeSettlements: Array<Record<string, unknown>>
    bdoLeads: Array<Record<string, unknown>>
    bdoProspects: Array<Record<string, unknown>>
    routes: Array<Record<string, unknown>>
    warehouseOrders: Array<Record<string, unknown>>
    warehouseLines: Array<Record<string, unknown>>
    warehouseItems: Array<Record<string, unknown>>
    inserts: Array<{table:string;data:Record<string,unknown>}>
    assignmentStatus: string
    job: Record<string, unknown>
    query: ReturnType<typeof vi.fn>
    rpc: ReturnType<typeof vi.fn>
    invoke: ReturnType<typeof vi.fn>
    upload: ReturnType<typeof vi.fn>
    remove: ReturnType<typeof vi.fn>
    createSignedUrls: ReturnType<typeof vi.fn>
    createSignedUrl: ReturnType<typeof vi.fn>
    podInsertError: boolean
    noCustomerMembership: boolean
    client: Record<string, unknown>
  } = {
    roles: [],
    session: { user: { id: 'user-1', email: 'tester@example.test' } },
    partners: [],
    customerRequests: [],
    customerOrders: [],
    services: [],
    coverageLocations: [],
    coverageCorridors: [],
    notifications: [],
    financeFinancials: [],
    financePayments: [],
    financeSettlements: [],
    bdoLeads: [],
    bdoProspects: [],
    routes: [],
    warehouseOrders: [],
    warehouseLines: [],
    warehouseItems: [],
    inserts: [],
    assignmentStatus: 'assigned',
    job: {},
    query: vi.fn(),
    rpc: vi.fn(),
    invoke: vi.fn(),
    upload: vi.fn(),
    remove: vi.fn(),
    createSignedUrls: vi.fn(async (paths: string[]) => ({ data: paths.map((path) => ({ path, signedUrl: 'https://signed.example.test/proof' })), error: null })),
    createSignedUrl: vi.fn(async () => ({ data: { signedUrl: 'https://signed.example.test/document' }, error: null })),
    podInsertError: false,
    noCustomerMembership: false,
    client: {},
  }

  function builder(table: string) {
    const filters: Record<string, unknown> = {}
    let insertData: unknown
    let single = false
    const queryBuilder: Record<string, unknown> = {}
    for (const method of ['select', 'eq', 'neq', 'in', 'not', 'order', 'limit', 'is', 'ilike', 'gt']) {
      queryBuilder[method] = (...args: unknown[]) => {
        if (method === 'eq' || method === 'neq' || method === 'in' || method === 'not') filters[String(args[0])] = args[1]
        return queryBuilder
      }
    }
    queryBuilder.single = () => { single = true; return queryBuilder }
    queryBuilder.maybeSingle = () => { single = true; return queryBuilder }
    queryBuilder.insert = (data: unknown) => { insertData = data; return queryBuilder }
    queryBuilder.then = (resolve: (value: unknown) => unknown, reject: (reason: unknown) => unknown) =>
      Promise.resolve((state.query as (name: string, conditions: Record<string, unknown>, one: boolean, insert?: unknown) => unknown)(table, filters, single, insertData)).then(resolve, reject)
    return queryBuilder
  }

  state.client = {
    channel: () => {
      const channel = { on: () => channel, subscribe: () => channel }
      return channel
    },
    removeChannel: vi.fn(async () => 'ok'),
    auth: {
      getSession: vi.fn(async () => ({ data: { session: state.session } })),
      onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
      signOut: vi.fn(async () => ({ error: null })),
      signUp: vi.fn(async () => ({ data: { session: null }, error: null })),
      signInWithPassword: vi.fn(async () => ({ error: null })),
    },
    from: (table: string) => builder(table),
    storage: { from: () => ({
      upload: (...args: unknown[]) => (state.upload as (...values: unknown[]) => unknown)(...args),
      remove: (...args: unknown[]) => (state.remove as (...values: unknown[]) => unknown)(...args),
      createSignedUrls: (...args: unknown[]) => (state.createSignedUrls as (...values: unknown[]) => unknown)(...args),
      createSignedUrl: (...args: unknown[]) => (state.createSignedUrl as (...values: unknown[]) => unknown)(...args),
    }) },
    rpc: (...args: unknown[]) => (state.rpc as (...values: unknown[]) => unknown)(...args),
    functions: { invoke: (...args: unknown[]) => (state.invoke as (...values: unknown[]) => unknown)(...args) },
  }
  return state
})

describe('account access', () => {
  it('reveals and hides the sign-in password without submitting the form', async () => {
    mockState.session = null
    const user = userEvent.setup()
    render(<App />)
    const password = await screen.findByLabelText('Password') as HTMLInputElement
    await user.type(password, 'private-password')
    expect(password.type).toBe('password')
    await user.click(screen.getByRole('button', { name: 'Show password' }))
    expect(password.type).toBe('text')
    expect(password.value).toBe('private-password')
    expect(screen.getByRole('button', { name: 'Hide password' })).toHaveAttribute('aria-pressed', 'true')
    await user.click(screen.getByRole('button', { name: 'Hide password' }))
    expect(password.type).toBe('password')
    expect((mockState.client.auth as { signInWithPassword: ReturnType<typeof vi.fn> }).signInWithPassword).not.toHaveBeenCalled()
  })

  it('submits a staff application and sends confirmation back to the live site', async () => {
    mockState.session = null
    render(<App />)
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Create account' }))
    await user.type(screen.getByLabelText('Your full name'), 'Ada Staff')
    await user.selectOptions(screen.getByLabelText('Sign up as'), 'staff')
    await user.selectOptions(screen.getByLabelText('Requested category'), 'warehouse')
    await user.type(screen.getByLabelText('Email address'), 'ada@example.test')
    await user.type(screen.getByLabelText('Password'), 'strong-password-123')
    await user.click(screen.getByRole('button', { name: 'Show password' }))
    expect((screen.getByLabelText('Password') as HTMLInputElement).type).toBe('text')
    fireEvent.submit(screen.getByRole('button', { name: 'Create account' }).closest('form')!)
    await waitFor(() => expect((mockState.client.auth as { signUp: ReturnType<typeof vi.fn> }).signUp).toHaveBeenCalledWith(expect.objectContaining({
      email: 'ada@example.test',
      options: expect.objectContaining({
        emailRedirectTo: 'https://gohezoh-services.vercel.app/',
        data: expect.objectContaining({ account_kind: 'staff', requested_role: 'warehouse' }),
      }),
    })))
    const notice = await screen.findByRole('status')
    expect(notice).toHaveClass('toast-email')
    expect(notice).toHaveTextContent('Check your email to confirm your account')
    await user.click(screen.getByRole('button', { name: 'Dismiss message' }))
    expect(screen.queryByRole('status')).not.toBeInTheDocument()
  })

  it('locks marketer signup to an invitation and passes its token to server validation', async () => {
    mockState.session = null
    const token = 'a'.repeat(64)
    window.history.replaceState({}, '', `/?marketer_invite=${token}`)
    render(<App />)
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Create account' }))
    expect(screen.getByLabelText('Sign up as')).toBeDisabled()
    expect(screen.getByLabelText('Requested category')).toHaveValue('marketer')
    await user.type(screen.getByLabelText('Your full name'), 'Ada Marketer')
    await user.type(screen.getByLabelText('Email address'), 'invited@example.test')
    await user.type(screen.getByLabelText('Password'), 'strong-password-123')
    fireEvent.submit(screen.getByRole('button', { name: 'Create account' }).closest('form')!)
    await waitFor(() => expect((mockState.client.auth as { signUp: ReturnType<typeof vi.fn> }).signUp).toHaveBeenCalledWith(expect.objectContaining({
      email: 'invited@example.test',
      options: expect.objectContaining({ data: expect.objectContaining({
        account_kind: 'staff', requested_role: 'marketer', marketer_invite: token,
      }) }),
    })))
    expect(await screen.findByText(/A Super Admin must approve/i)).toBeInTheDocument()
  })

  it('carries a referral code into customer signup so the database can attribute the account', async () => {
    mockState.session = null
    window.history.replaceState({}, '', '/?ref=ABC123DEF456')
    render(<App />)
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Create account' }))
    await user.type(screen.getByLabelText('Your full name'), 'Ada Customer')
    await user.type(screen.getByLabelText('Phone number'), '08012345678')
    await user.type(screen.getByLabelText('Email address'), 'ada@example.test')
    await user.type(screen.getByLabelText('Password'), 'strong-password-123')
    await user.click(screen.getByRole('button', { name: 'Create account' }))
    await waitFor(() => expect((mockState.client.auth as { signUp: ReturnType<typeof vi.fn> }).signUp).toHaveBeenCalledWith(expect.objectContaining({
      options: expect.objectContaining({ data: expect.objectContaining({
        referral_code: 'ABC123DEF456', phone: '08012345678', full_name: 'Ada Customer',
      }) }),
    })))
    expect(await screen.findByText(/Referral link applied/i)).toBeInTheDocument()
  })

  it('creates a customer profile automatically from signup details', async () => {
    mockState.roles = ['customer']
    mockState.noCustomerMembership = true
    mockState.session = { user: { id: 'customer-user', email: 'ada@example.test', user_metadata: { full_name: 'Ada Customer', phone: '08012345678' } } }
    render(<App />)
    expect(await screen.findByRole('heading', { name: 'Your parcels' })).toBeInTheDocument()
    expect(await screen.findByText('123456')).toBeInTheDocument()
    expect(mockState.rpc).toHaveBeenCalledWith('ensure_customer_profile')
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: /Edit my delivery info/ }))
    const heading = screen.getByRole('heading', { name: 'Delivery addresses' })
    expect(document.activeElement).toBe(heading)
  })

  it('explains when signup matched an existing account and no email was sent', async () => {
    mockState.session = null
    const signUp = (mockState.client.auth as { signUp: ReturnType<typeof vi.fn> }).signUp
    signUp.mockResolvedValueOnce({ data: { session: null, user: { identities: [] } }, error: null })
    render(<App />)
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Create account' }))
    await user.type(screen.getByLabelText('Your full name'), 'Existing User')
    await user.type(screen.getByLabelText('Email address'), 'existing@example.test')
    await user.type(screen.getByLabelText('Password'), 'strong-password-123')
    fireEvent.submit(screen.getByRole('button', { name: 'Create account' }).closest('form')!)
    expect(await screen.findByText(/already has an account, so no confirmation email was sent/i)).toBeInTheDocument()
    expect(screen.queryByText(/check your email to confirm your account/i)).not.toBeInTheDocument()
  })

  it('tells partner applicants when to submit verification documents', async () => {
    mockState.session = null
    render(<App />)
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Create account' }))
    await user.type(screen.getByLabelText('Your full name'), 'Partner Applicant')
    await user.selectOptions(screen.getByLabelText('Sign up as'), 'staff')
    await user.selectOptions(screen.getByLabelText('Requested category'), 'partner')
    expect(screen.getByText(/sign in here to upload your NIN or CAC registration document/i)).toBeInTheDocument()
    await user.type(screen.getByLabelText('Email address'), 'partner@example.test')
    await user.type(screen.getByLabelText('Password'), 'strong-password-123')
    fireEvent.submit(screen.getByRole('button', { name: 'Create account' }).closest('form')!)
    expect(await screen.findByRole('status')).toHaveTextContent('Then sign in to upload your NIN or CAC document.')
  })

  it('provides independent eye controls for new and confirmed passwords', async () => {
    window.history.replaceState({}, '', '/?setup=1')
    mockState.roles = ['customer']
    const user = userEvent.setup()
    render(<App />)
    await screen.findByRole('heading', { name: 'Choose a new password' })
    const password = screen.getByLabelText('New password') as HTMLInputElement
    const confirmation = screen.getByLabelText('Confirm password') as HTMLInputElement
    await user.type(password, 'new-private-password')
    await user.click(screen.getByRole('button', { name: 'Show new password' }))
    expect(password.type).toBe('text')
    expect(confirmation.type).toBe('password')
    await user.click(screen.getByRole('button', { name: 'Show confirm password' }))
    expect(confirmation.type).toBe('text')
    expect(password.value).toBe('new-private-password')
    window.history.replaceState({}, '', '/')
  })

  it('routes a named Super Admin to approval controls without a test switcher', async () => {
    mockState.roles = ['admin', 'customer']
    mockState.session = { user: { id: 'admin-1', email: 'admin@gohezohservices.org' } }
    mockState.rpc.mockImplementation(async (name: string) => {
      if (name === 'list_staff_applications') return { data: [{ id: 'application-1', user_id: 'staff-1', email: 'staff@example.test', full_name: 'Ada Staff', requested_role: 'warehouse', organization_name: null, status: 'pending', email_confirmed: true, created_at: '2026-10-05T10:00:00Z' }], error: null }
      if (name === 'list_staff_access') return { data: [], error: null }
      return { data: {}, error: null }
    })
    render(<App />)
    expect(await screen.findByRole('heading', { name: 'Access control' })).toBeInTheDocument()
    expect(screen.queryByText('TEST VIEW')).not.toBeInTheDocument()
    fireEvent.click(await screen.findByRole('button', { name: 'Approve' }))
    await waitFor(() => expect(mockState.rpc).toHaveBeenCalledWith('review_staff_application', {
      p_application_id: 'application-1', p_approve: true, p_partner_id: null,
    }))
  })

  it('routes any account granted the admin role to approval controls', async () => {
    window.localStorage.removeItem('gohezoh-workspace')
    mockState.roles = ['admin', 'management']
    mockState.session = { user: { id: 'admin-2', email: 'vevakporgodsanointed@gmail.com' } }
    mockState.rpc.mockImplementation(async (name: string) => {
      if (name === 'list_staff_applications') return { data: [{ id: 'bdo-application', user_id: 'bdo-1', email: 'bdo@example.test', full_name: 'BDO Applicant', requested_role: 'bdo', organization_name: null, status: 'pending', email_confirmed: true, created_at: '2026-10-13T10:00:00Z' }], error: null }
      if (name === 'list_staff_access') return { data: [], error: null }
      return { data: {}, error: null }
    })
    render(<App />)
    expect(await screen.findByRole('heading', { name: 'Access control' })).toBeInTheDocument()
    expect(await screen.findByText(/bdo@example\.test/)).toBeInTheDocument()
  })

  it('requires and sends the rejection reason from the company review card', async () => {
    mockState.roles = ['admin']
    mockState.session = { user: { id: 'admin-1', email: 'admin@gohezohservices.org' } }
    mockState.rpc.mockImplementation(async (name: string) => {
      if (name === 'list_staff_applications') return { data: [{ id: 'application-1', user_id: 'partner-1', email: 'partner@example.test', full_name: 'Partner Applicant', requested_role: 'partner', organization_name: 'Partner Company', status: 'pending', email_confirmed: true }], error: null }
      if (name === 'list_staff_access') return { data: [], error: null }
      return { data: {}, error: null }
    })
    render(<App />)
    fireEvent.click(await screen.findByRole('button', { name: 'Reject' }))
    expect(screen.getByLabelText('Reason for rejection')).toBeRequired()
    expect(mockState.rpc).not.toHaveBeenCalledWith('review_staff_application', expect.anything())
    fireEvent.change(screen.getByLabelText('Reason for rejection'), { target: { value: 'Please upload clearer company papers.' } })
    fireEvent.submit(screen.getByRole('button', { name: 'Confirm rejection' }).closest('form')!)
    await waitFor(() => expect(mockState.rpc).toHaveBeenCalledWith('review_staff_application', { p_application_id: 'application-1', p_approve: false, p_partner_id: null, p_rejection_reason: 'Please upload clearer company papers.' }))
  })

  it('shows submitted partner documents to the Super Admin', async () => {
    mockState.roles = ['admin']
    mockState.session = { user: { id: 'admin-1', email: 'admin@gohezohservices.org' } }
    mockState.rpc.mockImplementation(async (name: string) => {
      if (name === 'list_staff_applications') return { data: [{ id: 'application-1', user_id: 'partner-1', email: 'partner@example.test', full_name: 'Partner Applicant', requested_role: 'partner', organization_name: 'Partner Company', status: 'pending', email_confirmed: true, created_at: '2026-10-10T10:00:00Z' }], error: null }
      if (name === 'list_staff_access') return { data: [], error: null }
      return { data: {}, error: null }
    })
    const originalQuery = mockState.query.getMockImplementation()! as (...args: unknown[]) => unknown
    mockState.query.mockImplementation((...args: unknown[]) => args[0] === 'staff_applications'
      ? { data: [{ id: 'application-1', partner_document_type: 'cac', partner_document_path: 'partner-1/application-1/registration.pdf' }], error: null }
      : originalQuery(...args))
    const tab = { opener: null, location: { replace: vi.fn() }, close: vi.fn() }
    const open = vi.spyOn(window, 'open').mockReturnValue(tab as unknown as Window)
    render(<App />)
    expect(await screen.findByRole('heading', { name: 'Business verification' })).toBeInTheDocument()
    expect(screen.queryByRole('combobox', { name: /Partner company/ })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Approve' })).not.toBeDisabled()
    fireEvent.click(screen.getByRole('button', { name: 'View document' }))
    await waitFor(() => expect(mockState.createSignedUrl).toHaveBeenCalledWith('partner-1/application-1/registration.pdf', 300))
    expect(await screen.findByTitle('Partner Company - CAC document')).toHaveAttribute('src', 'https://signed.example.test/document')
    expect(open).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    open.mockRestore()
  })
})

vi.mock('./lib/supabase', () => ({ getSupabaseClient: () => mockState.client }))

it('switches the whole app to dark mode and keeps the choice after remount', async () => {
  mockState.session = null
  window.localStorage.removeItem('gohezoh-theme')
  const user = userEvent.setup()
  const first = render(<App />)
  const darkButton = await screen.findByRole('button', { name: 'Switch to dark mode' })
  await user.click(darkButton)
  await waitFor(() => expect(document.documentElement).toHaveAttribute('data-theme', 'dark'))
  expect(window.localStorage.getItem('gohezoh-theme')).toBe('dark')
  first.unmount()
  render(<App />)
  const lightButton = await screen.findByRole('button', { name: 'Switch to light mode' })
  expect(lightButton).toHaveAttribute('aria-pressed', 'true')
  await user.click(lightButton)
  await waitFor(() => expect(document.documentElement).toHaveAttribute('data-theme', 'light'))
  expect(window.localStorage.getItem('gohezoh-theme')).toBe('light')
})

const partner = { id: 'partner-1', partner_number: 'PRT-0001', partner_name: 'Test Logistics', status: 'active' }
const jobFixture = () => ({
  id: 'job-1', job_number: 'JOB-0001', status: 'order_confirmed', customer_id: 'customer-1', partner_id: null,
  pickup_city: 'Lagos', delivery_city: 'Ibadan', updated_at: '2026-09-30T10:00:00Z',
  pickup_address: '1 Pickup Road', delivery_address: '2 Delivery Road', recipient_name: 'Ada Customer', recipient_phone: '08000000000',
})

beforeEach(() => {
  window.history.replaceState({}, '', '/')
  window.localStorage.removeItem('gohezoh-workspace')
  mockState.roles = ['management']
  mockState.session = { user: { id: 'user-1', email: 'tester@example.test' } }
  mockState.partners = []
  mockState.customerRequests = []
  mockState.customerOrders = []
  mockState.services = []
  mockState.coverageLocations = []
  mockState.coverageCorridors = []
  mockState.notifications = []
  mockState.financeFinancials = []
  mockState.financePayments = []
  mockState.financeSettlements = []
  mockState.bdoLeads = []
  mockState.bdoProspects = []
  mockState.routes = []
  mockState.warehouseOrders = []
  mockState.warehouseLines = []
  mockState.warehouseItems = []
  mockState.inserts = []
  mockState.assignmentStatus = 'assigned'
  mockState.podInsertError = false
  mockState.noCustomerMembership = false
  mockState.job = jobFixture()
  mockState.query.mockImplementation((table: string, filters: Record<string, unknown>, single: boolean, insert?: Record<string, unknown>) => {
    if (insert && table !== 'proof_of_delivery') {
      mockState.inserts.push({table,data:insert})
      if (table === 'leads_opportunities') mockState.bdoLeads = [...mockState.bdoLeads,{...insert,id:'lead-new',lead_number:'LED-0001',stage:'lead',updated_at:'2026-10-02T10:00:00Z'}]
      if (table === 'partner_prospects') mockState.bdoProspects = [...mockState.bdoProspects,{...insert,id:'prospect-new',prospect_number:'PPR-0001',status:'identified',coverage_areas:[],updated_at:'2026-10-02T10:00:00Z'}]
      if (table === 'partner_prospects' && single) return {data:{id:'prospect-new'},error:null}
      return {data:null,error:null}
    }
    if (table === 'user_roles') {
      if (filters.role === 'bdo') return { data: [{ user_id: 'bdo-user' }], error: null }
      return { data: mockState.roles.map((role) => ({ role })), error: null }
    }
    if (table === 'routes') return {data:mockState.routes,error:null}
    if (table === 'fulfillment_orders') return {data:mockState.warehouseOrders,error:null}
    if (table === 'fulfillment_order_items') return {data:mockState.warehouseLines,error:null}
    if (table === 'inventory_items') return {data:mockState.warehouseItems,error:null}
    if (table === 'service_requests') return { data: mockState.customerRequests, error: null }
    if (table === 'services') return { data: mockState.services, error: null }
    if (table === 'coverage_locations') return { data: mockState.coverageLocations, error: null }
    if (table === 'coverage_corridors') return { data: mockState.coverageCorridors, error: null }
    if (table === 'orders') return { data: mockState.customerOrders, error: null }
    if (table === 'notifications') return { data: mockState.notifications, error: null }
    if (table === 'job_financials') return { data: mockState.financeFinancials, error: null }
    if (table === 'customer_payments') return { data: mockState.financePayments, error: null }
    if (table === 'partner_settlements') return { data: mockState.financeSettlements, error: null }
    if (table === 'leads_opportunities') return {data:mockState.bdoLeads,error:null}
    if (table === 'partner_prospects') return {data:mockState.bdoProspects,error:null}
    if (table === 'business_development_activities') return {data:[],error:null}
    if (table === 'business_development_reports') return {data:[],error:null}
    if (table === 'customer_users') return { data: mockState.noCustomerMembership ? null : single ? { customer_id: 'customer-1' } : [{ customer_id: 'customer-1' }], error: null }
    if (table === 'customers') {
      if (single) return { data: { id: 'customer-1', company_name: 'Test Customer', status: 'active' }, error: null }
      return { data: [{ id: 'customer-1', customer_number: 'CUS-0001', company_name: 'Test Customer', assigned_bdo_id: 'user-1', status: 'active', referred_by_marketer_id: null, created_at: '2026-10-01T12:00:00Z' }], error: null }
    }
    if (table === 'jobs') {
      if (mockState.roles.includes('partner') && filters.id) {
      return { data: [{ ...mockState.job, status: mockState.job.status, proof_of_delivery: mockState.job.proof_of_delivery ?? [] }], error: null }
      }
      return { data: [mockState.job], error: null }
    }
    if (table === 'logistics_partners') return { data: mockState.partners, error: null }
    if (table === 'partner_users') return { data: [{ partner_id: partner.id }], error: null }
    if (table === 'partner_assignments') return { data: mockState.assignmentStatus === 'rejected' ? [] : [{ id: 'assignment-1', partner_id: partner.id, job_id: 'job-1', status: mockState.assignmentStatus, assigned_at: '2026-09-30T10:00:00Z' }], error: null }
    if (table === 'proof_of_delivery' && insert) {
      if (mockState.podInsertError) return { data: null, error: { message: 'proof metadata insert denied' } }
      mockState.job = { ...mockState.job, proof_of_delivery: [{ id: 'proof-1', storage_path: insert.storage_path, recipient_name: insert.recipient_name, created_at: '2026-10-01T12:00:00Z' }] }
      return { data: null, error: null }
    }
    return { data: [], error: null }
  })
  mockState.rpc.mockImplementation(async (name: string, args: Record<string, unknown>) => {
    if (name === 'create_logistics_partner') {
      mockState.partners = [{ ...partner, partner_name: String(args.p_partner_name) }]
      return { data: { partner_id: partner.id, partner_number: partner.partner_number, partner_name: String(args.p_partner_name) }, error: null }
    }
    if (name === 'assign_job_to_partner') {
      mockState.job = { ...mockState.job, partner_id: partner.id, status: 'partner_assigned' }
      return { data: { assignment_id: 'assignment-1', status: 'assigned' }, error: null }
    }
    if (name === 'respond_to_partner_assignment') {
      mockState.assignmentStatus = args.p_accept ? 'accepted' : 'rejected'
      return { data: { status: mockState.assignmentStatus }, error: null }
    }
    if (name === 'update_job_status') {
      mockState.job = { ...mockState.job, status: args.p_new_status }
      return { data: { status: args.p_new_status }, error: null }
    }
    if (name === 'verify_delivery_otp') {
      mockState.job = { ...mockState.job, status: 'delivered' }
      mockState.assignmentStatus = 'completed'
      return { data: { verified: true, job_number: 'JOB-0001', status: 'delivered' }, error: null }
    }
    if (name === 'mark_customer_notification_read') return { data: '2026-10-01T12:30:00.000Z', error: null }
    if (name === 'finance_dashboard_totals') return { data: [{ currency: 'NGN', customer_revenue: 10000, received: 0, outstanding: 10000, partner_cost: 4000, direct_cost: 500, gross_profit: 5500, settlements_due: 0 }], error: null }
    if (name === 'list_my_customer_payments') return { data: [{ job_id: 'job-1', payment_number: 'PAY-00001', method: 'bank_transfer', amount: 4000, currency: 'NGN', received_at: '2026-10-01T12:00:00Z', status: 'received' }], error: null }
    if (name === 'business_development_dashboard') return {data:[{assigned_leads:1,followups_due:0,meetings_this_week:0,proposals:0,won_opportunities:0,assigned_customers:0,partner_prospects:0,activities_this_week:0,won_opportunity_value:0}],error:null}
    if (name === 'get_my_bdo_referral_code') return {data:'ABC123DEF456',error:null}
    if (name === 'create_partner_prospect_invite') return {data:'12345678-1234-4234-8234-123456789abc',error:null}
    if (name === 'ensure_customer_profile') return {data:'customer-1',error:null}
    if (name === 'get_my_parcel_pal_code') return {data:'123456',error:null}
    if (name === 'list_parcel_pal_requests' || name === 'list_my_parcel_pals') return {data:[],error:null}
    if (name === 'record_business_development_activity') return {data:{activity_number:'BDA-00001'},error:null}
    if (name === 'create_delivery_route') return {data:{route_id:'route-created',route_number:'RTE-0002'},error:null}
    if (name === 'assign_job_route') {mockState.job={...mockState.job,route_id:args.p_route_id};return {data:{route_id:args.p_route_id,route_number:'RTE-0001'},error:null}}
    if (name === 'confirm_fulfillment_pick') return {data:{picked_quantity:args.p_picked_quantity},error:null}
    return { data: null, error: null }
  })
  mockState.invoke.mockResolvedValue({ data: { sent: true }, error: null })
  mockState.upload.mockResolvedValue({ data: { path: 'job-1/proof.jpg' }, error: null })
  mockState.remove.mockResolvedValue({ data: [], error: null })
})

describe('partner assignment and delivery screens', () => {
  it('shows Kwik-Parsel with its Gohezo product credit', async () => {
    mockState.session = null
    render(<App />)
    expect(await screen.findByRole('link', { name: 'Kwik-Parsel by Gohezo Integrated Services' })).toBeInTheDocument()
    expect(screen.getByText('Kwik-Parsel is a product by Gohezo Integrated Services.')).toBeInTheDocument()
  })

  it('routes warehouse staff into the scoped warehouse and fulfillment desk', async () => {
    mockState.roles = ['warehouse']
    render(<App />)

    expect(await screen.findByRole('heading', { name: 'Warehouse desk' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Receive customer inventory' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Inventory by warehouse' })).toBeInTheDocument()
  })

  it('converts a received product weight from milligrams before saving', async () => {
    mockState.roles = ['warehouse']
    const baseQuery = mockState.query.getMockImplementation() as (table: string, filters: Record<string, unknown>, one: boolean, insert?: unknown) => unknown
    mockState.query.mockImplementation((table: string, filters: Record<string, unknown>, one: boolean, insert?: unknown) =>
      table === 'warehouses'
        ? { data: [{ id: 'warehouse-1', warehouse_number: 'WH-0001', name: 'Lagos Warehouse', code: 'LAG', address: '1 Road', city: 'Lagos', state: 'Lagos' }], error: null }
        : baseQuery(table, filters, one, insert))
    const user = userEvent.setup()
    render(<App />)
    await screen.findByRole('heading', { name: 'Receive customer inventory' })
    await screen.findByRole('option', { name: 'Test Customer' })
    await user.selectOptions(screen.getByLabelText('Customer'), 'customer-1')
    await user.selectOptions(screen.getByLabelText('Warehouse'), 'warehouse-1')
    await user.type(screen.getByLabelText('SKU'), 'SKU-001')
    await user.type(screen.getByLabelText('Product name'), 'Sample')
    await user.type(screen.getByLabelText('Quantity received'), '1')
    await user.type(screen.getByLabelText('Weight'), '1')
    await user.selectOptions(screen.getByLabelText('Weight unit'), 'mg')
    await user.click(screen.getByRole('button', { name: 'Record goods received' }))
    await waitFor(() => expect(mockState.rpc).toHaveBeenCalledWith('receive_inventory', expect.objectContaining({ p_weight_kg: 0.000001 })))
  })

  it('lets warehouse staff confirm the picked quantity for an order line', async () => {
    mockState.roles=['warehouse']
    mockState.warehouseOrders=[{id:'fulfillment-1',fulfillment_number:'FUL-00001',customer_id:'customer-1',warehouse_id:'warehouse-1',status:'picking',delivery_address:'2 Delivery Road',delivery_city:'Ibadan',delivery_state:'Oyo',recipient_name:'Ada Recipient',recipient_phone:'08000000001',customer_note:null,created_at:'2026-10-02T10:00:00Z',service_request_id:null}]
    mockState.warehouseLines=[{fulfillment_order_id:'fulfillment-1',inventory_item_id:'item-1',quantity:2,picked_quantity:0}]
    mockState.warehouseItems=[{id:'item-1',customer_id:'customer-1',sku:'SKU-1',name:'Test Product',unit:'unit'}]
    const user=userEvent.setup()
    render(<App />)

    expect(await screen.findByText('Test Product (SKU-1)')).toBeInTheDocument()
    await user.click(screen.getByRole('button',{name:'Save picked count'}))
    await waitFor(()=>expect(mockState.rpc).toHaveBeenCalledWith('confirm_fulfillment_pick',{p_fulfillment_id:'fulfillment-1',p_inventory_item_id:'item-1',p_picked_quantity:2}))
  },15000)

  it('prints a pick manifest with the warehouse bin and fulfillment details', async () => {
    mockState.roles=['warehouse']
    mockState.warehouseOrders=[{id:'fulfillment-1',fulfillment_number:'FUL-00001',customer_id:'customer-1',warehouse_id:'warehouse-1',status:'picking',delivery_address:'2 Delivery Road',delivery_city:'Ibadan',delivery_state:'Oyo',recipient_name:'Ada Recipient',recipient_phone:'08000000001',customer_note:'Keep upright',created_at:'2026-10-02T10:00:00Z',service_request_id:null}]
    mockState.warehouseLines=[{fulfillment_order_id:'fulfillment-1',inventory_item_id:'item-1',quantity:2,picked_quantity:0}]
    mockState.warehouseItems=[{id:'item-1',customer_id:'customer-1',sku:'SKU-1',name:'Test Product',unit:'carton'}]
    const baseQuery=mockState.query.getMockImplementation() as (table:string,filters:Record<string,unknown>,one:boolean,insert?:unknown)=>unknown
    mockState.query.mockImplementation((table:string,filters:Record<string,unknown>,one:boolean,insert?:unknown)=>{
      if(table==='warehouses')return {data:[{id:'warehouse-1',warehouse_number:'WH-0001',name:'Lagos Warehouse',code:'LAG',address:'1 Road',city:'Lagos',state:'Lagos'}],error:null}
      if(table==='warehouse_inventory')return {data:[{warehouse_id:'warehouse-1',inventory_item_id:'item-1',location_code:'A-04',quantity_on_hand:4,quantity_reserved:2}],error:null}
      return baseQuery(table,filters,one,insert)
    })
    const print=vi.spyOn(window,'print').mockImplementation(()=>undefined)
    const user=userEvent.setup()
    const {container}=render(<App />)

    await user.click(await screen.findByRole('button',{name:'Print pick manifest'}))
    await waitFor(()=>expect(print).toHaveBeenCalled())
    const manifest=container.querySelector('.print-manifest.is-print-target')
    expect(manifest).toHaveTextContent('FUL-00001')
    expect(manifest).toHaveTextContent('A-04')
    expect(manifest).toHaveTextContent('Keep upright')
    print.mockRestore()
  },15000)

  it('lets Operations create a route and assign a matching route to a job', async () => {
    mockState.routes=[{id:'route-1',route_number:'RTE-0001',route_name:'Lagos to Ibadan',origin_city:'Lagos',destination_city:'Ibadan',partner_id:null,is_active:true}]
    const user=userEvent.setup()
    render(<App />)

    await screen.findByRole('heading',{name:'Delivery routes'})
    await user.type(screen.getByLabelText('Route name'),'Backup route')
    await user.type(screen.getByLabelText('Origin city'),'Lagos')
    await user.type(screen.getByLabelText('Destination city'),'Ibadan')
    await user.click(screen.getByRole('button',{name:'Add route'}))
    await waitFor(()=>expect(mockState.rpc).toHaveBeenCalledWith('create_delivery_route',expect.objectContaining({p_route_name:'Backup route',p_origin_city:'Lagos',p_destination_city:'Ibadan'})))
    await user.selectOptions(await screen.findByLabelText('Assign route for JOB-0001'),'route-1')
    await user.click(screen.getByRole('button',{name:'Assign route'}))
    await waitFor(()=>expect(mockState.rpc).toHaveBeenCalledWith('assign_job_route',{p_job_id:'job-1',p_route_id:'route-1'}))
  },15000)

  it('lets a BDO create a lead, progress its stage, and record a meeting', async () => {
    mockState.roles = ['bdo']
    const user = userEvent.setup()
    render(<App />)

    expect(await screen.findByRole('heading', { name: 'BDO workspace' })).toBeInTheDocument()
    expect(screen.queryByText('PARCEL PALS')).not.toBeInTheDocument()
    expect(await screen.findByText('Assigned leads')).toBeInTheDocument()
    expect(await screen.findByLabelText('Personal referral link')).toHaveValue('https://gohezoh-services.vercel.app/?ref=ABC123DEF456')
    await user.click(screen.getByText('Add a lead'))
    await user.type(await screen.findByLabelText('Business name'), 'Harbor Foods')
    const leadForm = screen.getByText('Add a lead').closest('details')!
    await user.type(within(leadForm).getByLabelText('Contact person'), 'Ada Contact')
    await user.type(within(leadForm).getByLabelText('Phone'), '08012345678')
    await user.click(screen.getByRole('button', { name: 'Add lead' }))
    await waitFor(() => expect(mockState.inserts).toContainEqual(expect.objectContaining({
      table: 'leads_opportunities', data: expect.objectContaining({business_name:'Harbor Foods',assigned_bdo_id:'user-1',created_by:'user-1'}),
    })))

    const followUp = screen.getByText('Adjust follow-up').closest('details')!
    await user.click(screen.getByText('Adjust follow-up'))
    expect(within(followUp).queryByRole('textbox')).not.toBeInTheDocument()
    await user.selectOptions(within(followUp).getByLabelText('Next action'), 'email')
    await user.selectOptions(within(followUp).getByLabelText('Remind me in'), '14')
    await user.click(within(followUp).getByRole('button', { name: 'Save follow-up' }))
    await waitFor(() => expect(mockState.rpc).toHaveBeenCalledWith('update_business_lead', expect.objectContaining({p_lead_id:'lead-new',p_next_action:'email',p_follow_up_at:expect.any(String)})))

    await user.selectOptions(await screen.findByLabelText('Stage for LED-0001'), 'qualified')
    await waitFor(() => expect(mockState.rpc).toHaveBeenCalledWith('update_business_lead', expect.objectContaining({p_lead_id:'lead-new',p_stage:'qualified'})))
    await user.click(screen.getByText('Record an interaction'))
    await user.selectOptions(screen.getByLabelText('Related lead, customer, or partner'), 'lead:lead-new')
    await user.selectOptions(screen.getByLabelText('Activity type'), 'meeting')
    await user.click(screen.getByRole('button', { name: 'Record activity' }))
    await waitFor(() => expect(mockState.rpc).toHaveBeenCalledWith('record_business_development_activity', expect.objectContaining({p_activity_type:'meeting',p_subject:'meeting: LED-0001 - Harbor Foods',p_lead_id:'lead-new'})))
  }, 15000)

  it('captures partner GPS and stores coordinates with a new prospect', async () => {
    mockState.roles = ['bdo']
    Object.defineProperty(window, 'GohezohLocation', { configurable: true, value: {
      requestPosition: (requestId: string) => window.dispatchEvent(new CustomEvent('gohezoh:position', { detail: {
        type: 'gohezoh:position:result', requestId, latitude: 5.56, longitude: 7.06,
        accuracyMetres: 12, capturedAt: Date.now(),
      } })),
    } })
    const user = userEvent.setup()
    render(<App />)
    await screen.findByRole('heading', { name: 'BDO workspace' })
    await user.click(screen.getByText('Potential logistics partner'))
    const form = screen.getByText('Potential logistics partner').closest('details')!
    await user.click(within(form).getByRole('button', { name: 'Capture partner GPS location' }))
    expect(await within(form).findByText(/Captured 5\.560000, 7\.060000/)).toBeInTheDocument()
    await user.type(within(form).getByLabelText('Partner or company name'), 'Port Harcourt Carrier')
    await user.type(within(form).getByLabelText('Contact person'), 'Ada Partner')
    await user.type(within(form).getByLabelText('Phone'), '08012345678')
    await user.click(within(form).getByRole('button', { name: 'Add potential partner' }))
    await waitFor(() => expect(mockState.inserts).toContainEqual(expect.objectContaining({
      table: 'partner_prospects', data: expect.objectContaining({ latitude: 5.56, longitude: 7.06, location_accuracy_metres: 12 }),
    })))
    expect(await screen.findByLabelText('Partner signup link for Port Harcourt Carrier')).toHaveValue('https://gohezoh-services.vercel.app/?partner_prospect_invite=12345678-1234-4234-8234-123456789abc')
    Reflect.deleteProperty(window, 'GohezohLocation')
  }, 20000)

  it('shows a referred partner application progress and Super Admin decision to the BDO', async () => {
    mockState.roles = ['bdo']
    mockState.bdoProspects = [{
      id: 'referred-prospect', prospect_number: 'PPR-0042', partner_name: 'Abia Express',
      contact_person: 'Ada Partner', phone: '08012345678', email: 'partner@example.test', city: 'Umuahia',
      state: 'Abia', service_type: 'interstate_transport', coverage_areas: [], capacity_notes: null,
      assigned_bdo_id: 'user-1', status: 'ready', next_action: null, follow_up_at: null,
      notes: null, converted_partner_id: null, latitude: null, longitude: null,
      location_accuracy_metres: null, location_captured_at: null,
    }]
    mockState.notifications = [{ id: 'partner-approved', event_type: 'bdo_partner_application_review', title: 'Partner application approved', body: 'Abia Express has been approved and linked to the partner network.', created_at: '2026-10-13T10:00:00Z' }]
    const defaultRpc = mockState.rpc.getMockImplementation() as (name: string, args: Record<string, unknown>) => Promise<unknown>
    mockState.rpc.mockImplementation(async (name: string, args: Record<string, unknown>) => {
      if (name === 'list_my_partner_prospect_progress') return { data: [{ partner_prospect_id: 'referred-prospect', application_status: 'pending', email_confirmed: true, verification_document_submitted: true }], error: null }
      return defaultRpc(name, args)
    })
    render(<App />)
    await screen.findByRole('heading', { name: 'BDO workspace' })
    expect(await screen.findByText(/Application progress:/)).toBeInTheDocument()
    expect(screen.getByText('Awaiting Super Admin review')).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Partner application updates' })).toBeInTheDocument()
    expect(screen.getByText('Abia Express has been approved and linked to the partner network.')).toBeInTheDocument()
  })

  it('shows captured partner GPS to Management with a Google Maps search link', async () => {
    mockState.bdoProspects = [{
      id: 'gps-prospect', prospect_number: 'PPR-0002', partner_name: 'Port Harcourt Carrier',
      contact_person: 'Ada Partner', phone: '08012345678', email: null, city: 'Port Harcourt',
      state: 'Rivers', service_type: 'Courier', coverage_areas: [], capacity_notes: null,
      assigned_bdo_id: 'user-2', status: 'ready', next_action: null, follow_up_at: null,
      notes: null, converted_partner_id: null, latitude: 5.56, longitude: 7.06,
      location_accuracy_metres: 12, location_captured_at: new Date().toISOString(),
    }]
    const user = userEvent.setup()
    render(<App />)
    await user.click(await screen.findByRole('button', { name: 'Business Development' }))
    expect(await screen.findByText('Captured partner location')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Search location in Google Maps' })).toHaveAttribute('href', 'https://www.google.com/maps/search/?api=1&query=5.56,7.06')
  })

  it('lets Operations add a partner and assign an eligible job', async () => {
    const user = userEvent.setup()
    render(<App />)

    await screen.findByRole('heading', { name: 'Request desk' })
    await user.type(screen.getByLabelText('Partner or company name'), 'Test Logistics')
    await user.type(screen.getByLabelText('Contact person'), 'Alex Partner')
    await user.type(screen.getByLabelText('Phone number'), '08012345678')
    await user.click(screen.getByRole('button', { name: 'Add logistics partner' }))

    await waitFor(() => expect(mockState.rpc).toHaveBeenCalledWith('create_logistics_partner', expect.objectContaining({
      p_partner_name: 'Test Logistics', p_contact_person: 'Alex Partner', p_phone: '08012345678',
    })))
    await user.selectOptions(await screen.findByLabelText('Assign partner'), partner.id)
    await user.click(screen.getByRole('button', { name: 'Assign' }))

    await waitFor(() => expect(mockState.rpc).toHaveBeenCalledWith('assign_job_to_partner', { p_job_id: 'job-1', p_partner_id: partner.id }))
    expect(await screen.findByText('Partner: Test Logistics')).toBeInTheDocument()
    expect(screen.queryByRole('option', { name: 'Delivered' })).not.toBeInTheDocument()
  })

  it('lets the assigned partner handle exceptions without manually marking pickup or transit', async () => {
    mockState.roles = ['partner']
    mockState.job = { ...jobFixture(), partner_id: partner.id, status: 'partner_assigned' }
    const user = userEvent.setup()
    render(<App />)

    await user.click(await screen.findByRole('button', { name: 'Accept job' }))
    await waitFor(() => expect(mockState.rpc).toHaveBeenCalledWith('respond_to_partner_assignment', {
      p_assignment_id: 'assignment-1', p_accept: true, p_response_note: null,
    }))
    const progress = await screen.findByLabelText('Update delivery progress')
    expect(screen.queryByRole('option', { name: 'Picked up' })).not.toBeInTheDocument()
    expect(screen.queryByRole('option', { name: 'Out for delivery' })).not.toBeInTheDocument()
    await user.selectOptions(progress, 'exception')
    await waitFor(() => expect(mockState.rpc).toHaveBeenCalledWith('update_job_status', { p_job_id: 'job-1', p_new_status: 'exception' }))
    const recovery = await screen.findByLabelText('Update delivery progress')
    expect(screen.getByRole('option', { name: 'Pickup scheduled' })).toBeInTheDocument()
    await user.selectOptions(recovery, 'pickup_scheduled')
    await waitFor(() => expect(mockState.rpc).toHaveBeenCalledWith('update_job_status', { p_job_id: 'job-1', p_new_status: 'pickup_scheduled' }))
  })

  it('lets a partner find an assigned shipment by scanning or entering its parcel code', async () => {
    mockState.roles=['partner']
    mockState.assignmentStatus='accepted'
    mockState.job={...jobFixture(),partner_id:partner.id,status:'in_transit',job_parcels:[{tracking_code:'KWP-P-00000042',parcel_number:1,description:'Books',quantity:2}]}
    const user=userEvent.setup()
    render(<App />)
    expect(await screen.findByRole('img',{name:'Barcode KWP-P-00000042'})).toBeInTheDocument()
    const lookup=screen.getByLabelText('Find parcel by ID or scan its barcode')
    await user.type(lookup,'KWP-P-00000042')
    expect(screen.getByText(/Books.*2 items in this parcel/)).toBeInTheDocument()
    await user.clear(lookup)
    await user.type(lookup,'KWP-P-99999999')
    expect(await screen.findByRole('heading',{name:'No parcel found'})).toBeInTheDocument()
  })

  it('requires the sent recipient code before partner delivery can be confirmed', async () => {
    mockState.roles = ['partner']
    mockState.assignmentStatus = 'accepted'
    mockState.job = { ...jobFixture(), partner_id: partner.id, status: 'in_transit' }
    const user = userEvent.setup()
    render(<App />)

    await user.click(await screen.findByRole('button', { name: 'Send recipient delivery code' }))
    await waitFor(() => expect(mockState.invoke).toHaveBeenCalledWith('delivery-otp', { body: { jobId: 'job-1' } }))
    const input = await screen.findByLabelText('Recipient delivery code')
    await user.type(input, '123456')
    await user.click(screen.getByRole('button', { name: 'Verify code and confirm delivery' }))
    await waitFor(() => expect(mockState.rpc).toHaveBeenCalledWith('verify_delivery_otp', { p_job_id: 'job-1', p_code: '123456' }))
    expect(await screen.findByText('JOB-0001 delivery confirmed by recipient.')).toBeInTheDocument()
  })

  it('lets the completed partner upload a delivery photo', async () => {
    mockState.roles = ['partner']
    mockState.assignmentStatus = 'completed'
    mockState.job = { ...jobFixture(), partner_id: partner.id, status: 'delivered', proof_of_delivery: [] }
    const user = userEvent.setup()
    render(<App />)

    const file = new File(['delivery photo'], 'proof.jpg', { type: 'image/jpeg' })
    await user.upload(await screen.findByLabelText('Delivery photo (up to 5 MB)'), file)
    await user.click(screen.getByRole('button', { name: 'Upload proof of delivery' }))
    await waitFor(() => expect(mockState.upload).toHaveBeenCalledWith(expect.stringMatching(/^job-1\/.+\.jpg$/), file, { contentType: 'image/jpeg', upsert: false }))
    expect(await screen.findByText('Photo proof saved for this delivery.')).toBeInTheDocument()
    expect(await screen.findByText('Proof of delivery saved for JOB-0001.')).toBeInTheDocument()
  })

  it('removes an uploaded file if saving proof metadata fails', async () => {
    mockState.roles = ['partner']
    mockState.assignmentStatus = 'completed'
    mockState.job = { ...jobFixture(), partner_id: partner.id, status: 'delivered', proof_of_delivery: [] }
    mockState.podInsertError = true
    const user = userEvent.setup()
    render(<App />)

    const file = new File(['delivery photo'], 'proof.jpg', { type: 'image/jpeg' })
    await user.upload(await screen.findByLabelText('Delivery photo (up to 5 MB)'), file)
    await user.click(screen.getByRole('button', { name: 'Upload proof of delivery' }))
    await waitFor(() => expect(mockState.remove).toHaveBeenCalledWith([expect.stringMatching(/^job-1\/.+\.jpg$/)]))
    expect(await screen.findByText('proof metadata insert denied')).toBeInTheDocument()
  })

  it('shows a private proof link to the customer for their delivery', async () => {
    mockState.roles = ['customer']
    mockState.customerRequests = [{ id: 'request-1', request_number: 'REQ-0001', status: 'converted', pickup_city: 'Lagos', delivery_city: 'Ibadan', recipient_name: 'Ada', created_at: '2026-10-01T10:00:00Z' }]
    mockState.customerOrders = [{ service_request_id: 'request-1', order_number: 'ORD-0001', jobs: { id: 'job-1', job_number: 'JOB-0001', status: 'delivered', job_status_history: [], proof_of_delivery: [{ storage_path: 'job-1/proof.jpg', created_at: '2026-10-01T12:00:00Z', recipient_name: 'Ada' }] } }]
    const user = userEvent.setup()
    render(<App />)

    await user.click(await screen.findByRole('button', { name: /Tracking/ }))
    const proofLink = await screen.findByRole('link', { name: 'View proof of delivery 1' })
    expect(proofLink).toHaveAttribute('href', 'https://signed.example.test/proof')
    expect(mockState.createSignedUrls).toHaveBeenCalledWith(['job-1/proof.jpg'], 300)
  })

  it('shows a completed company bid on the customer home screen', async () => {
    mockState.roles = ['customer']
    mockState.customerRequests = [{ id: 'request-1', request_number: 'REQ-0001', status: 'under_review', pickup_city: 'Lagos', delivery_city: 'Ibadan', recipient_name: 'Ada', created_at: '2026-10-01T10:00:00Z' }]
    const query = mockState.query.getMockImplementation() as (table: string, filters: Record<string, unknown>, single: boolean, insert?: Record<string, unknown>) => unknown
    mockState.query.mockImplementation((table: string, filters: Record<string, unknown>, single: boolean, insert?: Record<string, unknown>) =>
      table === 'delivery_quote_windows'
        ? { data: [{ request_id: 'request-1', deadline_at: '2020-01-01T00:00:00Z', status: 'awaiting_customer_selection' }], error: null }
        : query(table, filters, single, insert))
    const rpc = mockState.rpc.getMockImplementation() as (name: string, args: Record<string, unknown>) => unknown
    mockState.rpc.mockImplementation((name: string, args: Record<string, unknown>) =>
      name === 'list_customer_bid_offers'
        ? { data: [{ bid_id: 'bid-1', partner_name: 'sam logistics', partner_phone: null, rider_name: 'Sam', rider_phone: null, rider_photo_path: null, bid_amount_ngn: 1000, eta_hours: 1 }], error: null }
        : rpc(name, args))
    render(<App />)

    expect(await screen.findByRole('heading', { name: 'You have 1 interested company' })).toBeInTheDocument()
    expect(screen.getByRole('region', { name: 'Latest delivery update' })).toHaveTextContent('sam logistics')
    expect(screen.getByRole('button', { name: 'Choose this company' })).toBeInTheDocument()
  })

  it('submits structured parcel details with a customer delivery request', async () => {
    mockState.roles = ['customer']
    mockState.customerRequests = [{ id: 'request-1', request_number: 'REQ-0001', status: 'submitted', pickup_city: 'Lagos', delivery_city: 'Ibadan', recipient_name: 'Ada', created_at: '2026-10-01T10:00:00Z' }]
    mockState.services = [{id:'service-1',code:'SRV-0001',name:'Local Delivery',description:''}]
    mockState.coverageLocations = [{ id: 'lagos', name: 'Lagos', state: 'Lagos', is_enabled: true }]
    mockState.coverageCorridors = [{ id: 'lagos-local', origin_id: 'lagos', destination_id: 'lagos', service_code: 'SRV-0001', is_enabled: true }]
    mockState.invoke.mockImplementation(async (name: string) => name === 'location-address' ? { data: {
      address: '1 Lagos Road', city: 'Lagos', state: 'Lagos', latitude: 6.45, longitude: 3.4,
      specificity: 'building', resultType: 'building', distanceMetres: null, confidence: 0.95,
    }, error: null } : { data: { sent: true }, error: null })
    const user = userEvent.setup()
    render(<App />)
    await user.click(await screen.findByRole('button', { name: /Send items/ }))
    await screen.findByRole('heading', {name: 'Delivery details'})
    await user.selectOptions(screen.getByLabelText('Service'), 'service-1')
    expect(screen.getByRole('region', { name: 'Pickup step' })).toBeVisible()
    expect(document.querySelector('[data-delivery-step="1"]')).toHaveAttribute('hidden')
    await user.click(screen.getByRole('button', { name: 'Next: drop-off' }))
    expect(screen.getByLabelText('Pickup contact')).toHaveFocus()
    await user.selectOptions(screen.getByLabelText('Pickup city'), 'Lagos')
    for (const [label,value] of Object.entries({ 'Pickup contact':'Ada','Pickup phone':'08000000001' })) fireEvent.change(screen.getByLabelText(label),{target:{value}})
    await user.type(screen.getByLabelText('Pickup community'), 'Ikeja')
    await user.click(await screen.findByRole('button', { name: 'Use typed community' }))
    const streetInput = document.querySelector('.pickup-location [name=pickup_address]') as HTMLInputElement
    await user.click(streetInput)
    expect(streetInput).toHaveFocus()
    await user.type(streetInput, '1 Lagos Road')
    await user.click(screen.getByRole('button', { name: 'Find pickup address' }))
    await screen.findByText(/approximate address match/)
    await user.click(screen.getByLabelText('This is the pickup location.'))
    await user.click(screen.getByRole('button', { name: 'Next: drop-off' }))
    expect(screen.getByRole('region', { name: 'Drop-off step' })).toBeVisible()
    await user.selectOptions(screen.getByLabelText('Delivery city'), 'Lagos')
    for (const [label,value] of Object.entries({ 'Recipient name':'Bola','Recipient phone':'08000000002' })) fireEvent.change(screen.getByLabelText(label),{target:{value}})
    await user.type(screen.getByLabelText('Delivery community'), 'Ikeja')
    await user.click(await screen.findByRole('button', { name: 'Use typed community' }))
    const deliveryStreet = document.querySelector('.delivery-location [name=delivery_address]') as HTMLInputElement
    await user.type(deliveryStreet, '2 Lagos Road')
    await user.click(screen.getByRole('button', { name: 'Find delivery address' }))
    await screen.findByLabelText('This is the delivery location.')
    await user.click(screen.getByLabelText('This is the delivery location.'))
    await user.click(screen.getByLabelText('I confirmed this delivery location with the recipient.'))
    await user.click(screen.getByRole('button', { name: 'Next: parcel' }))
    expect(screen.getByRole('region', { name: 'Parcel step' })).toBeVisible()
    fireEvent.change(screen.getByLabelText('Description'), { target: { value: 'Books' } })
    const quantity = screen.getByLabelText('Items for this destination') as HTMLSelectElement
    expect(quantity.options).toHaveLength(50)
    expect(quantity.options[quantity.options.length - 1].value).toBe('50')
    await user.selectOptions(quantity, '2')
    await user.selectOptions(screen.getByLabelText(/Weight/), '1.3')
    await user.selectOptions(screen.getByLabelText(/Length/), '30')
    await user.selectOptions(screen.getByLabelText(/Width/), '20')
    await user.selectOptions(screen.getByLabelText(/Height/), '10')
    expect(streetInput).toHaveValue('1 Lagos Road')
    expect(document.querySelector('.pickup-location .pin-correction')).toBeInTheDocument()
    expect(deliveryStreet).toHaveValue('2 Lagos Road')
    fireEvent.change(screen.getByLabelText(/Declared worth/), { target: { value: '25000' } })
    fireEvent.change(screen.getByLabelText(/Price paid/), { target: { value: '18000' } })
    const parcelPhoto = new File(['parcel photo'], 'parcel.png', { type: 'image/png' })
    await user.upload(screen.getByLabelText('Photo of goods'), parcelPhoto)
    expect((screen.getByLabelText('Photo of goods') as HTMLInputElement).files?.[0]).toEqual(parcelPhoto)
    const requestForm = screen.getByRole('button',{name:'Request delivery'}).closest('form')!
    fireEvent.submit(requestForm)
    await waitFor(() => expect(mockState.upload).toHaveBeenCalledWith(expect.stringMatching(/\.png$/), parcelPhoto, { contentType: 'image/png', upsert: false }))
    await waitFor(() => expect(mockState.inserts).toContainEqual(expect.objectContaining({
      table:'service_requests',
      data:expect.objectContaining({parcel_summary:'Books',pickup_address:'1 Lagos Road, Ikeja',pickup_latitude:6.45,pickup_longitude:3.4,pickup_location_source:'search',delivery_latitude:6.45,delivery_longitude:3.4,parcel_photo_path:expect.stringMatching(/\.png$/),parcel_items:[{description:'Books',quantity:2,weight_kg:1.3,length_cm:30,width_cm:20,height_cm:10,declared_value:25000,price:18000}]})
    })))
  })

  it('requires a goods photo for a new delivery item', async () => {
    mockState.roles = ['customer']
    const user = userEvent.setup()
    render(<App />)
    await user.click(await screen.findByRole('button', { name: /Send items/ }))
    expect(screen.getByLabelText('Photo of goods')).toBeRequired()
  })

  it('preserves an in-progress delivery form when account roles refresh on focus', async () => {
    mockState.roles = ['customer']
    render(<App />)
    await screen.findByRole('heading', { name: 'Your parcels' })
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: /Send items/ }))
    const description = screen.getByLabelText('Pickup contact') as HTMLInputElement
    await user.type(description, 'Unfinished pickup details')
    const roleChecks = mockState.query.mock.calls.filter(([table]) => table === 'user_roles').length
    fireEvent.focus(window)
    await waitFor(() => expect(mockState.query.mock.calls.filter(([table]) => table === 'user_roles').length).toBeGreaterThan(roleChecks))
    expect(screen.getByLabelText('Pickup contact')).toBe(description)
    expect(description).toHaveValue('Unfinished pickup details')
    expect(screen.getByRole('heading', { name: 'Delivery details' })).toBeInTheDocument()
  })

  it('warns immediately when selected item count exceeds packed shipment capacity', async () => {
    mockState.roles = ['customer']
    render(<App />)
    await screen.findByRole('heading', { name: 'Your parcels' })
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: /Send items/ }))
    await user.selectOptions(screen.getByLabelText(/Weight per item/), '5')
    await user.selectOptions(screen.getByLabelText(/Length/), '99')
    await user.selectOptions(screen.getByLabelText(/Width/), '60')
    await user.selectOptions(screen.getByLabelText(/Height/), '70.5')
    await user.selectOptions(screen.getByLabelText('Items for this destination'), '2')
    expect(await screen.findByText(/exceeds the total weight and packed size capacity/i)).toBeInTheDocument()
  })

  it('shows customer delivery notifications and marks only the selected notification as read', async () => {
    mockState.roles = ['customer']
    mockState.notifications = [{ id: 'notification-1', job_id: 'job-1', event_type: 'job_status_delivered', title: 'Parcel delivered', body: 'Job JOB-0001: parcel delivered.', created_at: '2026-10-01T12:00:00Z', read_at: null, payload: { job_number: 'JOB-0001' } }]
    const user = userEvent.setup()
    render(<App />)

    await user.click(await screen.findByRole('button', { name: /Updates/ }))
    expect(await screen.findByText('Parcel delivered')).toBeInTheDocument()
    expect(screen.getByText('Job JOB-0001: parcel delivered.')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Mark as read' }))
    await waitFor(() => expect(mockState.rpc).toHaveBeenCalledWith('mark_customer_notification_read', { p_notification_id: 'notification-1' }))
    expect(screen.queryByRole('button', { name: 'Mark as read' })).not.toBeInTheDocument()
  })

  it('shows the paid job pickup code beside its order only to the customer', async () => {
    mockState.roles = ['customer']
    mockState.customerRequests = [{ id: 'request-1', request_number: 'REQ-0001', status: 'converted', pickup_city: 'Lagos', delivery_city: 'Lagos', recipient_name: 'Ada', created_at: '2026-10-20T10:00:00Z' }]
    mockState.customerOrders = [{ service_request_id: 'request-1', order_number: 'ORD-0001', customer_price: 2000, currency: 'NGN', jobs: { id: 'job-1', job_number: 'JOB-0001', status: 'pickup_scheduled', job_status_history: [], proof_of_delivery: [], job_parcels: [] } }]
    const rpc = mockState.rpc.getMockImplementation() as (name: string, args: Record<string, unknown>) => unknown
    mockState.rpc.mockImplementation((name: string, args: Record<string, unknown>) =>
      name === 'get_my_pickup_handoff_codes' ? { data: [{ job_id: 'job-1', code: '12345678' }], error: null } : rpc(name, args))
    render(<App />)
    await userEvent.click(await screen.findByRole('button', { name: /Tracking/ }))
    expect(await screen.findByText('12345678')).toBeInTheDocument()
    expect(screen.getByText(/Give this code to the assigned rider only/)).toBeInTheDocument()
    expect(mockState.rpc).toHaveBeenCalledWith('get_my_pickup_handoff_codes', { p_job_ids: ['job-1'] })
  })

  it('organizes customer features into home cards and separate app frames', async () => {
    mockState.roles = ['customer']
    const user = userEvent.setup()
    render(<App />)
    expect(await screen.findByRole('heading', { name: 'Your parcels' })).toBeInTheDocument()
    expect(screen.getByRole('region', { name: 'Your number' })).toBeInTheDocument()
    expect(screen.getByRole('region', { name: 'Items to send' })).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: /Updates/ }))
    expect(await screen.findByRole('heading', { name: 'Messages about your parcels' })).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: /customer home/ }))
    await user.click(screen.getByRole('button', { name: /Tracking/ }))
    expect(await screen.findByRole('heading', { name: 'Your deliveries', level: 2 })).toBeInTheDocument()
  })

  it('shows delivery exception alerts to internal staff and lets them mark an alert reviewed', async () => {
    mockState.roles = ['operations']
    mockState.notifications = [{ id: 'exception-alert-1', job_id: 'job-1', event_type: 'job_exception_escalated', title: 'Delivery exception needs review', body: 'Job JOB-0001 has been marked as an exception.', created_at: '2026-10-13T10:00:00Z', read_at: null, payload: { job_number: 'JOB-0001' } }]
    const user = userEvent.setup()
    render(<App />)

    expect(await screen.findByRole('heading', { name: 'Delivery exceptions' })).toBeInTheDocument()
    expect(await screen.findByText('Job JOB-0001 has been marked as an exception.')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Mark reviewed' }))
    await waitFor(() => expect(mockState.rpc).toHaveBeenCalledWith('mark_customer_notification_read', { p_notification_id: 'exception-alert-1' }))
    expect(screen.queryByRole('button', { name: 'Mark reviewed' })).not.toBeInTheDocument()
  })

  it('lets Finance save job costs and record customer receipts and partner settlements', async () => {
    mockState.roles = ['finance']
    mockState.job = { ...jobFixture(), partner_id: partner.id, status: 'delivered' }
    mockState.partners = [partner]
    mockState.financeFinancials = [{ job_id: 'job-1', customer_revenue: 10000, partner_cost: 4000, other_direct_cost: 500, currency: 'NGN' }]
    const user = userEvent.setup()
    render(<App />)

    expect(await screen.findByRole('heading', { name: 'Finance desk' })).toBeInTheDocument()
    expect(await screen.findByText('JOB-0001')).toBeInTheDocument()
    expect(screen.getAllByText('Gross profit').length).toBeGreaterThan(0)
    await user.click(screen.getByText('Manage job financials and records'))
    await user.clear(screen.getByLabelText('Partner cost'))
    await user.type(screen.getByLabelText('Partner cost'), '4500')
    await user.click(screen.getByRole('button', { name: 'Save job costs' }))
    await waitFor(() => expect(mockState.rpc).toHaveBeenCalledWith('save_job_financials', {
      p_job_id: 'job-1', p_partner_cost: 4500, p_other_direct_cost: 500,
    }))
    expect(await screen.findByText('Financials saved for JOB-0001.')).toBeInTheDocument()
    await waitFor(() => expect(screen.getByRole('button', { name: 'Record receipt' })).toBeEnabled())

    const amounts = screen.getAllByLabelText('Amount (NGN)')
    await user.type(amounts[0], '2500')
    await user.type(screen.getByLabelText('Receipt or transaction reference'), 'RCPT-UI-001')
    expect(amounts[0]).toHaveValue(2500)
    fireEvent.submit(screen.getByRole('button', { name: 'Record receipt' }).closest('form')!)
    await waitFor(() => expect(mockState.rpc).toHaveBeenCalledWith('record_customer_payment', {
      p_job_id: 'job-1', p_amount: 2500, p_method: 'bank_transfer', p_reference: 'RCPT-UI-001', p_notes: null,
    }))
    expect(await screen.findByText('Customer receipt recorded for JOB-0001.')).toBeInTheDocument()
    await waitFor(() => expect(screen.getByRole('button', { name: 'Create settlement' })).toBeEnabled())

    const settlementAmount = screen.getAllByLabelText('Amount (NGN)')[1]
    await user.type(settlementAmount, '3000')
    await user.type(screen.getByLabelText('Unique settlement request reference'), 'SETTLE-UI-001')
    fireEvent.submit(screen.getByRole('button', { name: 'Create settlement' }).closest('form')!)
    await waitFor(() => expect(mockState.rpc).toHaveBeenCalledWith('create_partner_settlement', {
      p_job_id: 'job-1', p_amount: 3000, p_request_reference: 'SETTLE-UI-001', p_notes: null,
    }))
  })

  it('shows the customer only their billed amount, receipts, and remaining balance', async () => {
    mockState.roles = ['customer']
    mockState.customerRequests = [{ id: 'request-1', request_number: 'REQ-0001', status: 'converted', pickup_city: 'Lagos', delivery_city: 'Ibadan', recipient_name: 'Ada', created_at: '2026-10-01T10:00:00Z' }]
    mockState.customerOrders = [{ service_request_id: 'request-1', order_number: 'ORD-0001', customer_price: 10000, currency: 'NGN', jobs: { id: 'job-1', job_number: 'JOB-0001', status: 'delivered', job_status_history: [], proof_of_delivery: [] } }]
    const user = userEvent.setup()
    render(<App />)

    await user.click(await screen.findByRole('button', { name: /Tracking/ }))
    await user.click(await screen.findByText('Payment'))
    expect(screen.getByText(/Total:/)).toBeInTheDocument()
    expect(screen.getByText(/Received:/)).toBeInTheDocument()
    expect(screen.getByText(/PAY-00001/)).toHaveTextContent('bank transfer')
    expect(screen.getByText(/Balance:/)).toBeInTheDocument()
  })
})
