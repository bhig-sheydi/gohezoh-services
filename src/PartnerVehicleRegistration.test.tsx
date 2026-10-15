import { expect, it, vi } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import type { SupabaseClient } from '@supabase/supabase-js'
import PartnerVehicleRegistration from './PartnerVehicleRegistration'

function setup(error: { message: string } | null = null) {
  const rows: object[] = []
  const query = { select: vi.fn(), eq: vi.fn(), order: vi.fn(async () => ({ data: [...rows], error: null })) }
  query.select.mockReturnValue(query); query.eq.mockReturnValue(query)
  const upload = vi.fn(async (_path: string, _file: File, _options: object) => ({ error: null }))
  const remove = vi.fn(async () => ({ error: null }))
  const rpc = vi.fn(async (_name: string, args: Record<string, string>) => {
    if (!error) rows.push({ id: String(rows.length), vehicle_type: args.p_vehicle_type, registration_number: args.p_registration_number, registered_company_name: args.p_registered_company_name, driver_full_name: args.p_driver_full_name, driver_nin: args.p_driver_nin, vehicle_document_path: args.p_vehicle_document_path, licence_document_path: args.p_licence_document_path, opening_time: args.p_opening_time, closing_time: args.p_closing_time })
    return { error }
  })
  const supabase = { from: () => query, rpc, storage: { from: () => ({ upload, remove }) } } as unknown as SupabaseClient
  const props = { supabase, applicationId: 'app', userId: 'owner', companyName: 'Acme Logistics', onError: vi.fn(), onNotice: vi.fn() }
  render(<PartnerVehicleRegistration {...props} />)
  return { props, upload, remove, rpc }
}
async function fill() {
  await waitFor(() => expect(screen.getByLabelText('Vehicle type')).not.toBeDisabled())
  for (const [label, value] of [['Vehicle type', 'motorcycle'], ['Registration / plate number', 'ABC-123'], ['Driver full name', 'Example Driver'], ['Driver NIN', '12345678901']]) fireEvent.change(screen.getByLabelText(label), { target: { value } })
  for (const label of ['Vehicle papers', 'Driver licence']) fireEvent.change(screen.getByLabelText(label, { exact: false, selector: 'input[type="file"]' }), { target: { files: [new File(['test'], 'file.pdf', { type: 'application/pdf' })] } })
}
it('requires a licence for all offered vehicles and preserves company ownership', async () => {
  setup(); await fill()
  expect(screen.getByLabelText('Registered company name')).toHaveAttribute('readonly')
  for (const value of ['motorcycle', 'tricycle', 'car', 'van', 'bus', 'truck']) {
    fireEvent.change(screen.getByLabelText('Vehicle type'), { target: { value } })
    expect(screen.getByLabelText('Driver licence', { exact: false })).toBeRequired()
  }
})
it('submits private documents and driver details once despite repeated clicks', async () => {
  const { rpc, upload } = setup(); await fill()
  const form = screen.getByRole('button', { name: 'Submit vehicle' }).closest('form')!
  fireEvent.submit(form); fireEvent.submit(form)
  await waitFor(() => expect(rpc).toHaveBeenCalledTimes(1))
  expect(upload).toHaveBeenCalledTimes(2)
  expect(rpc).toHaveBeenCalledWith('register_partner_vehicle', expect.objectContaining({ p_application_id: 'app', p_registered_company_name: 'Acme Logistics', p_driver_nin: '12345678901', p_vehicle_type: 'motorcycle', p_opening_time: '08:00', p_closing_time: '18:00' }))
  expect(upload.mock.calls[0][0]).toMatch(/^owner\/app\//)
})
it('cleans uploaded files after rejected registration', async () => {
  const { props, remove } = setup({ message: 'Plate already registered' }); await fill()
  fireEvent.submit(screen.getByRole('button', { name: 'Submit vehicle' }).closest('form')!)
  await waitFor(() => expect(props.onError).toHaveBeenCalledWith('Plate already registered'))
  expect(remove).toHaveBeenCalledWith([expect.stringMatching(/^owner\/app\//), expect.stringMatching(/^owner\/app\//)])
})
it('rejects malformed NIN before uploading', async () => {
  const { props, upload } = setup(); await fill()
  fireEvent.change(screen.getByLabelText('Driver NIN'), { target: { value: '123' } })
  fireEvent.submit(screen.getByRole('button', { name: 'Submit vehicle' }).closest('form')!)
  expect(upload).not.toHaveBeenCalled()
  expect(props.onError).toHaveBeenCalledWith("Enter the driver's 11-digit NIN.")
})

it('adds a second vehicle without replacing the first', async () => {
  const { rpc } = setup(); await fill()
  fireEvent.submit(screen.getByRole('button', { name: 'Submit vehicle' }).closest('form')!)
  const add = await screen.findByRole('button', { name: 'Add another vehicle' })
  await waitFor(() => expect(add).not.toBeDisabled())
  fireEvent.click(add)
  expect(screen.getByLabelText('Driver NIN')).toHaveValue('')
  await fill()
  fireEvent.change(screen.getByLabelText('Registration / plate number'), { target: { value: 'XYZ-987' } })
  fireEvent.submit(screen.getByRole('button', { name: 'Submit vehicle' }).closest('form')!)
  expect(await screen.findByText('2 registered')).toBeInTheDocument()
  expect(screen.getByText('ABC-123 - motorcycle')).toBeInTheDocument()
  expect(screen.getByText('XYZ-987 - motorcycle')).toBeInTheDocument()
  expect(rpc).toHaveBeenCalledTimes(2)
})

it('lets Super Admin view private papers using a short-lived link', async () => {
  const vehicle = { id: 'v1', registration_number: 'ABC-123', vehicle_type: 'bus', registered_company_name: 'Acme', driver_full_name: 'Test Driver', driver_nin: '12345678901', opening_time: '20:00', closing_time: '06:00', vehicle_document_path: 'papers.pdf', licence_document_path: 'licence.pdf' }
  const query = { select: vi.fn(), eq: vi.fn(), order: vi.fn(async () => ({ data: [vehicle], error: null })) }
  query.select.mockReturnValue(query); query.eq.mockReturnValue(query)
  const createSignedUrl = vi.fn(async () => ({ data: { signedUrl: 'https://example.test/private-paper' }, error: null }))
  const replace = vi.fn()
  const open = vi.spyOn(window, 'open').mockReturnValue({ opener: null, location: { replace }, close: vi.fn() } as unknown as Window)
  try {
    const supabase = { from: () => query, storage: { from: () => ({ createSignedUrl }) } } as unknown as SupabaseClient
    render(<PartnerVehicleRegistration supabase={supabase} applicationId="app" readOnly onError={vi.fn()} />)
    expect(await screen.findByText('Test Driver')).toBeInTheDocument()
    expect(screen.getByText('20:00 to 06:00 (next day) WAT')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Submit vehicle' })).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Vehicle papers' }))
    await waitFor(() => expect(createSignedUrl).toHaveBeenCalledWith('papers.pdf', 300))
    expect(await screen.findByTitle('Vehicle papers')).toHaveAttribute('src', 'https://example.test/private-paper')
    expect(open).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  } finally { open.mockRestore() }
})
