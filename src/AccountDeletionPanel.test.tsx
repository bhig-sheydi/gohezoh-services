import { it, expect, vi } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import type { SupabaseClient } from '@supabase/supabase-js'
import AccountDeletionPanel from './AccountDeletionPanel'

it('requires an explicit confirmation before saving a deletion request', async () => {
  const rpc = vi.fn(async () => ({ data: '2026-11-05T12:00:00Z', error: null }))
  const maybeSingle = vi.fn(async () => ({ data: null, error: null }))
  const query = { select: vi.fn(), eq: vi.fn(), maybeSingle }
  query.select.mockReturnValue(query); query.eq.mockReturnValue(query)
  const supabase = { from: () => query, rpc } as unknown as SupabaseClient
  render(<AccountDeletionPanel supabase={supabase} userId="customer-1" onError={vi.fn()} />)
  const button = screen.getByRole('button', { name: 'Request account deletion' })
  expect(button).toBeDisabled()
  fireEvent.click(screen.getByRole('checkbox'))
  fireEvent.click(button)
  await waitFor(() => expect(rpc).toHaveBeenCalledWith('request_account_deletion'))
  expect(await screen.findByText(/Your deletion request was received/)).toBeInTheDocument()
})
