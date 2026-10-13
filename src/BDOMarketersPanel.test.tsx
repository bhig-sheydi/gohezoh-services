import { describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { BDOMarketersPanel } from './BDOMarketersPanel'

describe('BDO marketer invitations', () => {
  it('creates an invitation URL that the BDO can share', async () => {
    const rpc = vi.fn(async (name: string) => name === 'create_bdo_marketer_invite'
      ? { data: 'secret-invite-token', error: null }
      : { data: [], error: null })
    const supabase = { rpc } as unknown as Parameters<typeof BDOMarketersPanel>[0]['supabase']
    render(<BDOMarketersPanel supabase={supabase} onError={vi.fn()} onNotice={vi.fn()} />)
    const user = userEvent.setup()
    await user.type(screen.getByLabelText('Marketer email'), 'new.marketer@example.test')
    fireEvent.submit(screen.getByRole('button', { name: 'Create invitation link' }).closest('form')!)
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('create_bdo_marketer_invite', { p_email: 'new.marketer@example.test' }))
    expect(await screen.findByLabelText('Invitation link')).toHaveValue(`https://gohezoh-services.vercel.app/?marketer_invite=secret-invite-token`)
  })
})
