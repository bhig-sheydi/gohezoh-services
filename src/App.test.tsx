import { beforeEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import App from './App'

const mockState = vi.hoisted(() => {
  const state: {
    roles: string[]
    session: { user: { id: string; email: string } } | null
    partners: Array<{ id: string; partner_number: string; partner_name: string; status: string }>
    customerRequests: Array<Record<string, unknown>>
    customerOrders: Array<Record<string, unknown>>
    services: Array<Record<string, unknown>>
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
    podInsertError: boolean
    client: Record<string, unknown>
  } = {
    roles: [],
    session: { user: { id: 'user-1', email: 'tester@example.test' } },
    partners: [],
    customerRequests: [],
    customerOrders: [],
    services: [],
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
    podInsertError: false,
    client: {},
  }

  function builder(table: string) {
    const filters: Record<string, unknown> = {}
    let insertData: unknown
    let single = false
    const queryBuilder: Record<string, unknown> = {}
    for (const method of ['select', 'eq', 'neq', 'in', 'not', 'order', 'limit']) {
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
    }) },
    rpc: (...args: unknown[]) => (state.rpc as (...values: unknown[]) => unknown)(...args),
    functions: { invoke: (...args: unknown[]) => (state.invoke as (...values: unknown[]) => unknown)(...args) },
  }
  return state
})

describe('account access', () => {
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
    fireEvent.submit(screen.getByRole('button', { name: 'Create account' }).closest('form')!)
    await waitFor(() => expect((mockState.client.auth as { signUp: ReturnType<typeof vi.fn> }).signUp).toHaveBeenCalledWith(expect.objectContaining({
      email: 'ada@example.test',
      options: expect.objectContaining({
        emailRedirectTo: 'https://gohezoh-services.vercel.app/',
        data: expect.objectContaining({ account_kind: 'staff', requested_role: 'warehouse' }),
      }),
    })))
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
})

vi.mock('./lib/supabase', () => ({ getSupabaseClient: () => mockState.client }))

const partner = { id: 'partner-1', partner_number: 'PRT-0001', partner_name: 'Test Logistics', status: 'active' }
const jobFixture = () => ({
  id: 'job-1', job_number: 'JOB-0001', status: 'order_confirmed', customer_id: 'customer-1', partner_id: null,
  pickup_city: 'Lagos', delivery_city: 'Ibadan', updated_at: '2026-09-30T10:00:00Z',
  pickup_address: '1 Pickup Road', delivery_address: '2 Delivery Road', recipient_name: 'Ada Customer', recipient_phone: '08000000000',
})

beforeEach(() => {
  mockState.roles = ['management']
  mockState.session = { user: { id: 'user-1', email: 'tester@example.test' } }
  mockState.partners = []
  mockState.customerRequests = []
  mockState.customerOrders = []
  mockState.services = []
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
  mockState.job = jobFixture()
  mockState.query.mockImplementation((table: string, filters: Record<string, unknown>, single: boolean, insert?: Record<string, unknown>) => {
    if (insert && table !== 'proof_of_delivery') {
      mockState.inserts.push({table,data:insert})
      if (table === 'leads_opportunities') mockState.bdoLeads = [...mockState.bdoLeads,{...insert,id:'lead-new',lead_number:'LED-0001',stage:'lead',updated_at:'2026-10-02T10:00:00Z'}]
      if (table === 'partner_prospects') mockState.bdoProspects = [...mockState.bdoProspects,{...insert,id:'prospect-new',prospect_number:'PPR-0001',status:'identified',coverage_areas:[],updated_at:'2026-10-02T10:00:00Z'}]
      return {data:null,error:null}
    }
    if (table === 'user_roles') return { data: mockState.roles.map((role) => ({ role })), error: null }
    if (table === 'routes') return {data:mockState.routes,error:null}
    if (table === 'fulfillment_orders') return {data:mockState.warehouseOrders,error:null}
    if (table === 'fulfillment_order_items') return {data:mockState.warehouseLines,error:null}
    if (table === 'inventory_items') return {data:mockState.warehouseItems,error:null}
    if (table === 'service_requests') return { data: mockState.customerRequests, error: null }
    if (table === 'services') return { data: mockState.services, error: null }
    if (table === 'orders') return { data: mockState.customerOrders, error: null }
    if (table === 'notifications') return { data: mockState.notifications, error: null }
    if (table === 'job_financials') return { data: mockState.financeFinancials, error: null }
    if (table === 'customer_payments') return { data: mockState.financePayments, error: null }
    if (table === 'partner_settlements') return { data: mockState.financeSettlements, error: null }
    if (table === 'leads_opportunities') return {data:mockState.bdoLeads,error:null}
    if (table === 'partner_prospects') return {data:mockState.bdoProspects,error:null}
    if (table === 'business_development_activities') return {data:[],error:null}
    if (table === 'business_development_reports') return {data:[],error:null}
    if (table === 'customer_users') return { data: single ? { customer_id: 'customer-1' } : [{ customer_id: 'customer-1' }], error: null }
    if (table === 'customers') {
      if (single) return { data: { id: 'customer-1', company_name: 'Test Customer', status: 'active' }, error: null }
      return { data: [{ id: 'customer-1', company_name: 'Test Customer' }], error: null }
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
    if (name === 'list_my_customer_payments') return { data: [{ job_id: 'job-1', payment_number: 'PAY-00001', amount: 4000, currency: 'NGN', method: 'bank_transfer', received_at: '2026-10-01T12:00:00Z', status: 'received' }], error: null }
    if (name === 'business_development_dashboard') return {data:[{assigned_leads:1,followups_due:0,meetings_this_week:0,proposals:0,won_opportunities:0,assigned_customers:0,partner_prospects:0,activities_this_week:0,won_opportunity_value:0}],error:null}
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
    expect(await screen.findByText('Assigned leads')).toBeInTheDocument()
    await user.type(screen.getByLabelText('Business name'), 'Harbor Foods')
    const leadForm = screen.getByRole('heading', { name: 'Add a lead' }).closest('section')!
    await user.type(within(leadForm).getByLabelText('Contact person'), 'Ada Contact')
    await user.type(within(leadForm).getByLabelText('Phone'), '08012345678')
    await user.click(screen.getByRole('button', { name: 'Add lead' }))
    await waitFor(() => expect(mockState.inserts).toContainEqual(expect.objectContaining({
      table: 'leads_opportunities', data: expect.objectContaining({business_name:'Harbor Foods',assigned_bdo_id:'user-1',created_by:'user-1'}),
    })))

    await user.selectOptions(await screen.findByLabelText('Stage for LED-0001'), 'qualified')
    await waitFor(() => expect(mockState.rpc).toHaveBeenCalledWith('update_business_lead', expect.objectContaining({p_lead_id:'lead-new',p_stage:'qualified'})))
    await user.selectOptions(screen.getByLabelText('Related lead, customer, or partner'), 'lead:lead-new')
    await user.selectOptions(screen.getByLabelText('Activity type'), 'meeting')
    await user.type(screen.getByLabelText('Subject'), 'Discovery meeting')
    await user.click(screen.getByRole('button', { name: 'Record activity' }))
    await waitFor(() => expect(mockState.rpc).toHaveBeenCalledWith('record_business_development_activity', expect.objectContaining({p_activity_type:'meeting',p_subject:'Discovery meeting',p_lead_id:'lead-new'})))
  }, 15000)

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

  it('lets the assigned partner accept a job and post a delivery update', async () => {
    mockState.roles = ['partner']
    mockState.job = { ...jobFixture(), partner_id: partner.id, status: 'partner_assigned' }
    const user = userEvent.setup()
    render(<App />)

    await user.click(await screen.findByRole('button', { name: 'Accept job' }))
    await waitFor(() => expect(mockState.rpc).toHaveBeenCalledWith('respond_to_partner_assignment', {
      p_assignment_id: 'assignment-1', p_accept: true, p_response_note: null,
    }))
    const progress = await screen.findByLabelText('Update delivery progress')
    await user.selectOptions(progress, 'picked_up')
    await waitFor(() => expect(mockState.rpc).toHaveBeenCalledWith('update_job_status', { p_job_id: 'job-1', p_new_status: 'picked_up' }))
    expect(await screen.findByRole('heading', { name: 'Picked up' })).toBeInTheDocument()

    await user.selectOptions(await screen.findByLabelText('Update delivery progress'), 'exception')
    await waitFor(() => expect(mockState.rpc).toHaveBeenCalledWith('update_job_status', { p_job_id: 'job-1', p_new_status: 'exception' }))
    const recovery = await screen.findByLabelText('Update delivery progress')
    expect(screen.getByRole('option', { name: 'Pickup scheduled' })).toBeInTheDocument()
    await user.selectOptions(recovery, 'pickup_scheduled')
    await waitFor(() => expect(mockState.rpc).toHaveBeenCalledWith('update_job_status', { p_job_id: 'job-1', p_new_status: 'pickup_scheduled' }))
  })

  it('requires the sent recipient code before partner delivery can be confirmed', async () => {
    mockState.roles = ['partner']
    mockState.assignmentStatus = 'accepted'
    mockState.job = { ...jobFixture(), partner_id: partner.id, status: 'out_for_delivery' }
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
    render(<App />)

    const proofLink = await screen.findByRole('link', { name: 'View proof of delivery 1' })
    expect(proofLink).toHaveAttribute('href', 'https://signed.example.test/proof')
    expect(mockState.createSignedUrls).toHaveBeenCalledWith(['job-1/proof.jpg'], 300)
  })

  it('submits structured parcel details with a customer delivery request', async () => {
    mockState.roles = ['customer']
    mockState.customerRequests = [{ id: 'request-1', request_number: 'REQ-0001', status: 'submitted', pickup_city: 'Lagos', delivery_city: 'Ibadan', recipient_name: 'Ada', created_at: '2026-10-01T10:00:00Z' }]
    mockState.services = [{id:'service-1',code:'SRV-0001',name:'Local Delivery',description:''}]
    const user = userEvent.setup()
    render(<App />)
    await screen.findByRole('heading', {name: 'Where should it go?'})
    await user.selectOptions(screen.getByLabelText('Delivery service'), 'service-1')
    for (const [label,value] of Object.entries({
      'Pickup contact':'Ada','Pickup phone':'08000000001','Pickup address':'1 Lagos Road','Pickup city':'Lagos',
      'Recipient name':'Bola','Recipient phone':'08000000002','Delivery address':'2 Lagos Road','Delivery city':'Lagos',
      'Parcel description':'Books','Quantity':'2','Weight':'1250',
    })) fireEvent.change(screen.getByLabelText(label),{target:{value}})
    await user.selectOptions(screen.getByLabelText('Weight unit'), 'g')
    await user.click(screen.getByRole('button',{name:'Submit delivery request'}))
    await waitFor(() => expect(mockState.inserts).toContainEqual(expect.objectContaining({
      table:'service_requests',
      data:expect.objectContaining({parcel_summary:'Books',parcel_items:[{description:'Books',quantity:2,weight_kg:1.25}]})
    })))
  })

  it('shows customer delivery notifications and marks only the selected notification as read', async () => {
    mockState.roles = ['customer']
    mockState.notifications = [{ id: 'notification-1', job_id: 'job-1', event_type: 'job_status_delivered', title: 'Parcel delivered', body: 'Job JOB-0001: parcel delivered.', created_at: '2026-10-01T12:00:00Z', read_at: null, payload: { job_number: 'JOB-0001' } }]
    const user = userEvent.setup()
    render(<App />)

    expect(await screen.findByText('Parcel delivered')).toBeInTheDocument()
    expect(screen.getByText('Job JOB-0001: parcel delivered.')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Mark as read' }))
    await waitFor(() => expect(mockState.rpc).toHaveBeenCalledWith('mark_customer_notification_read', { p_notification_id: 'notification-1' }))
    expect(screen.queryByRole('button', { name: 'Mark as read' })).not.toBeInTheDocument()
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
    render(<App />)

    expect(await screen.findByText('Payment information')).toBeInTheDocument()
    expect(screen.getByText(/Amount billed:/)).toBeInTheDocument()
    expect(screen.getByText('PAY-00001 · bank transfer · ₦4,000.00')).toBeInTheDocument()
    expect(screen.getByText(/Balance:/)).toBeInTheDocument()
  })
})
