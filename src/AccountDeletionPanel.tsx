import { useEffect, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'

export default function AccountDeletionPanel({ supabase, userId, onError }: {
  supabase: SupabaseClient; userId: string; onError: (message: string) => void
}) {
  const [requestedAt, setRequestedAt] = useState<string | null>(null)
  const [confirmed, setConfirmed] = useState(false)
  const [busy, setBusy] = useState(false)
  useEffect(() => {
    let active = true
    void supabase.from('account_deletion_requests').select('requested_at').eq('user_id', userId).maybeSingle()
      .then(({ data, error }) => { if (active) { if (error) onError(error.message); else setRequestedAt(data?.requested_at ?? null) } })
    return () => { active = false }
  }, [supabase, userId, onError])
  async function requestDeletion() {
    if (!confirmed || busy) return
    setBusy(true); onError('')
    const { data, error } = await supabase.rpc('request_account_deletion')
    if (error) onError(error.message)
    else setRequestedAt(String(data))
    setBusy(false)
  }
  return <section className="form-card narrow" aria-label="Account deletion">
    <h1>Delete your Kwik-Parsel account</h1>
    {requestedAt ? <p role="status">Your deletion request was received on {new Date(requestedAt).toLocaleDateString('en-NG')}. We will review active deliveries, payouts, and records we must keep before deleting your account and other data. Contact <a href="mailto:info@gohezohservices.org">info@gohezohservices.org</a> for an update.</p> : <>
      <p>Request deletion of your account and associated personal data. Active deliveries and outstanding payments may need to be resolved first. We will explain any records we must keep for legal or accounting reasons.</p>
      <p><a href="/privacy-policy.html">Read our privacy policy</a></p>
      <label><input type="checkbox" checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} /> I understand that account deletion will remove access to my deliveries and records.</label>
      <button className="primary-button" type="button" disabled={!confirmed || busy} onClick={() => void requestDeletion()}>{busy ? 'Sending request...' : 'Request account deletion'}</button>
    </>}
    <a href="/">Return to Kwik-Parsel</a>
  </section>
}
