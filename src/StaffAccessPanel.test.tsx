import { it, expect, vi } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import type { SupabaseClient } from '@supabase/supabase-js'
import StaffAccessPanel from './StaffAccessPanel'

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
