import { it, expect, vi } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import type { SupabaseClient } from '@supabase/supabase-js'
import StaffAccessPanel from './StaffAccessPanel'

it('shows the Super Admin rejection reason to the applicant', async () => {
  const query = { select: vi.fn(), eq: vi.fn(), order: vi.fn(async () => ({ data: [{ id: 'a', requested_role: 'partner', status: 'rejected', rejection_reason: 'Upload clearer vehicle papers.' }], error: null })) }
  query.select.mockReturnValue(query); query.eq.mockReturnValue(query)
  render(<StaffAccessPanel supabase={{ from: () => query } as unknown as SupabaseClient} userId="owner" onError={vi.fn()} onNotice={vi.fn()} />)
  expect(await screen.findByText('Upload clearer vehicle papers.')).toBeInTheDocument()
})

it.each([null, 'company-invitation'])('shows vehicle registration only for company applicants after document submission (%s)', async (invitation) => {
  const application = { id: 'app-1', requested_role: 'partner', status: 'pending', partner_document_path: 'company.pdf', organization_name: 'Acme Logistics', partner_invitation_id: invitation }
  const query = { select: vi.fn(), eq: vi.fn(), order: vi.fn(async () => ({ data: [application], error: null })) }
  query.select.mockReturnValue(query); query.eq.mockReturnValue(query)
  const vehicles = { select: vi.fn(), eq: vi.fn(), order: vi.fn(async () => ({ data: [], error: null })) }
  vehicles.select.mockReturnValue(vehicles); vehicles.eq.mockReturnValue(vehicles)
  const supabase = { from: (table: string) => table === 'staff_applications' ? query : vehicles } as unknown as SupabaseClient
  render(<StaffAccessPanel supabase={supabase} userId="owner" onError={vi.fn()} onNotice={vi.fn()} />)
  await screen.findByText('Document submitted. You may replace it before approval.')
  if (invitation) expect(screen.queryByRole('heading', { name: 'Your vehicles' })).not.toBeInTheDocument()
  else expect(await screen.findByRole('heading', { name: 'Your vehicles' })).toBeInTheDocument()
})

it('uploads a partner document and registers it for approval', async () => {
  vi.stubGlobal('crypto', { randomUUID: () => 'document-1' })
  const application = { id: 'app-1', requested_role: 'partner', status: 'pending', created_at: '2026-10-10', partner_document_type: null, partner_document_path: null }
  const query = { select: vi.fn(), eq: vi.fn(), order: vi.fn(async () => ({ data: [application], error: null })) }
  query.select.mockReturnValue(query)
  query.eq.mockReturnValue(query)
  const upload = vi.fn(async () => ({ error: null }))
  const rpc = vi.fn(async () => ({ error: null }))
  const supabase = { from: () => query, storage: { from: () => ({ upload, remove: vi.fn() }) }, rpc } as unknown as SupabaseClient
  const onError = vi.fn()
  const onNotice = vi.fn()
  render(<StaffAccessPanel supabase={supabase} userId="user-1" onError={onError} onNotice={onNotice} />)
  const input = await screen.findByLabelText('NIN or CAC document')
  fireEvent.change(input, { target: { files: [new File(['document'], 'registration.pdf', { type: 'application/pdf' })] } })
  fireEvent.change(screen.getByLabelText('Document type'), { target: { value: 'cac' } })
  fireEvent.submit(screen.getByRole('button', { name: 'Submit document' }).closest('form')!)
  await waitFor(() => expect(onError).not.toHaveBeenCalledWith('Choose a PDF or image under 5 MB.'))
  await waitFor(() => expect(rpc).toHaveBeenCalledWith('submit_partner_document', expect.objectContaining({ p_application_id: 'app-1', p_document_type: 'cac' })))
  expect(upload).toHaveBeenCalledWith(expect.stringMatching(/^user-1\/app-1\/.+\.pdf$/), expect.any(File), { contentType: 'application/pdf', upsert: false })
  expect(onNotice).toHaveBeenCalledWith('Document submitted for Super Admin review.')
})
