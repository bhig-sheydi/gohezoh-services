import { useCallback, useEffect, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'

type Request = { request_id: string; user_id: string; email: string; requested_at: string; status: string }
export default function AccountDeletionAdminPanel({ supabase, onError }: { supabase: SupabaseClient; onError: (message: string) => void }) {
  const [requests, setRequests] = useState<Request[]>([])
  const [busy, setBusy] = useState(false)
  const [maintenance, setMaintenance] = useState('')
  const load = useCallback(async () => {
    setBusy(true)
    const { data, error } = await supabase.rpc('list_account_deletion_requests')
    if (error) onError(error.message)
    else setRequests((data ?? []) as Request[])
    setBusy(false)
  }, [supabase, onError])
  useEffect(() => { const timer = window.setTimeout(() => { void load() }, 0); return () => window.clearTimeout(timer) }, [load])
  async function removeOldEvidence() {
    setBusy(true); onError(''); setMaintenance('')
    const { data, error } = await supabase.functions.invoke('privacy-maintenance', { body: {} })
    if (error) onError(error.message)
    else setMaintenance(`${Number(data?.removed ?? 0)} unlinked verification files older than 30 days removed.`)
    setBusy(false)
  }
  return <section className="form-card"><h2>Account deletion requests</h2>
    <p>Verify open deliveries, refunds and payouts, then delete the account and associated data. Keep only records required for a documented legal obligation, and respond to the requester.</p>
    <button className="secondary-button" type="button" disabled={busy} onClick={() => void load()}>Refresh requests</button>
    <button className="secondary-button" type="button" disabled={busy} onClick={() => void removeOldEvidence()}>Clean old verification files</button>
    {maintenance && <p role="status">{maintenance}</p>}
    {requests.length ? <div className="admin-list">{requests.map((request) => <article className="admin-row" key={request.request_id}><strong>{request.email}</strong><span>{new Date(request.requested_at).toLocaleString('en-NG')} · {request.status}</span><small>User ID: {request.user_id}</small></article>)}</div> : <p>No account deletion requests.</p>}
  </section>
}
