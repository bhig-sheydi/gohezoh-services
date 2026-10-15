import { expect, it, vi } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import type { SupabaseClient } from '@supabase/supabase-js'
import PartnerOnboarding from './PartnerOnboarding'

it('shows one horizontal step, gates progress and preserves input on Back', async () => {
  const query = { select: vi.fn(), eq: vi.fn(), order: vi.fn(async () => ({ data: [], error: null })) }
  query.select.mockReturnValue(query); query.eq.mockReturnValue(query)
  const props = { supabase: { from: () => query } as unknown as SupabaseClient, applicationId: 'app', userId: 'owner', companyName: 'Acme', documentReady: false, documentBusy: false, documentForm: <label>Document reference<input defaultValue="saved draft" /></label>, onError: vi.fn(), onNotice: vi.fn() }
  const view = render(<PartnerOnboarding {...props} />)
  expect(screen.getByRole('heading', { name: 'Business documents' })).toBeInTheDocument()
  expect(screen.queryByRole('heading', { name: 'Your vehicles' })).not.toBeInTheDocument()
  expect(screen.getByRole('button', { name: 'Next: vehicles' })).toBeDisabled()
  view.rerender(<PartnerOnboarding {...props} documentReady />)
  expect(screen.getByRole('heading', { name: 'Your vehicles' })).toBeInTheDocument()
  expect(screen.getByRole('button', { name: 'Next: review' })).toBeDisabled()
  await waitFor(() => expect(screen.getByLabelText('Driver full name')).not.toBeDisabled())
  fireEvent.change(screen.getByLabelText('Driver full name'), { target: { value: 'Unfinished driver' } })
  fireEvent.click(screen.getByRole('button', { name: 'Back' }))
  expect(screen.getByRole('heading', { name: 'Business documents' })).toBeInTheDocument()
  expect(screen.getByText('Done - business document saved')).toBeInTheDocument()
  fireEvent.click(screen.getByRole('button', { name: 'Edit document' }))
  expect(screen.getByLabelText('Document reference')).toHaveValue('saved draft')
  fireEvent.click(screen.getByRole('button', { name: 'Next: vehicles' }))
  expect(screen.getByLabelText('Driver full name')).toHaveValue('Unfinished driver')
  expect(document.querySelector('[data-slide="0"]')).toHaveAttribute('inert')
  expect(document.querySelector('[data-slide="1"]')).toHaveAttribute('data-active', 'true')
})
