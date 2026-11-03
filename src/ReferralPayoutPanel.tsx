import { useCallback, useEffect, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'

type Bank = { code: string; name: string }
type State = { available_ngn: number; testMode?: boolean; account: null | { bank_name: string; account_name: string; account_last4: string }; withdrawals: Array<{ id: string; amount_ngn: number; status: string }> }
const money = (value: number) => new Intl.NumberFormat('en-NG', { style: 'currency', currency: 'NGN' }).format(value || 0)

export default function ReferralPayoutPanel({ supabase, onError, onNotice }: { supabase: SupabaseClient; onError: (value: string) => void; onNotice: (value: string) => void }) {
  const [state, setState] = useState<State | null>(null)
  const [banks, setBanks] = useState<Bank[]>([])
  const [bankCode, setBankCode] = useState('')
  const [number, setNumber] = useState('')
  const [name, setName] = useState('')
  const [editing, setEditing] = useState(false)
  const [confirming, setConfirming] = useState(false)
  const [busy, setBusy] = useState(false)
  const [key, setKey] = useState<string | null>(null)
  const invoke = useCallback(async (body: Record<string, unknown>) => {
    const { data, error } = await supabase.functions.invoke('paystack-referral-payout', { body })
    if (error) { onError(error.message); return null }
    return data
  }, [supabase, onError])
  const load = useCallback(async () => { const data = await invoke({ action: 'account' }); if (data) setState(data as State) }, [invoke])
  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer) }, [load])
  async function open() { setEditing(true); const data = await invoke({ action: 'banks' }); if (data) setBanks(data.banks as Bank[]) }
  async function verify() {
    setBusy(true)
    const data = await invoke({ action: 'resolve', bankCode, accountNumber: number })
    if (data) setName(data.accountName)
    setBusy(false)
  }
  async function save() {
    setBusy(true)
    const data = await invoke({ action: 'save-account', bankCode, accountNumber: number, accountName: name })
    if (data) { setEditing(false); setName(''); setNumber(''); onNotice('Payout account verified.'); await load() }
    setBusy(false)
  }
  async function withdraw() {
    const amountNgn = Math.floor(Number(state?.available_ngn ?? 0))
    const idempotencyKey = key ?? crypto.randomUUID()
    setKey(idempotencyKey); setBusy(true)
    const data = await invoke({ action: 'withdraw', amountNgn, idempotencyKey })
    if (data) { setKey(null); setConfirming(false); onNotice(data.testMode ? 'Test withdrawal submitted.' : 'Withdrawal submitted.'); await load() }
    setBusy(false)
  }
  async function check(withdrawalId: string) { setBusy(true); await invoke({ action: 'status', withdrawalId }); await load(); setBusy(false) }
  return <section className="form-card referral-payout" aria-label="Referral withdrawals">
    <div className="history-heading"><div><p className="eyebrow">REFERRAL EARNINGS</p><h3>Withdraw rewards</h3></div><strong>{money(Number(state?.available_ngn ?? 0))} available</strong></div>
    {state?.testMode && <p className="customer-payment-test-warning">TEST MODE — no real bank transfer will be made.</p>}
    {state?.account ? <p>Verified account: <strong>{state.account.account_name}</strong> · {state.account.bank_name} ····{state.account.account_last4}</p> : <p>Verify a bank account to withdraw earned rewards.</p>}
    {!editing && <button type="button" className="secondary-button" onClick={() => void open()} disabled={busy}>{state?.account ? 'Change account' : 'Add bank account'}</button>}
    {editing && <div className="form-grid"><label className="field"><span>Bank</span><select value={bankCode} onChange={(event) => { setBankCode(event.target.value); setName('') }}><option value="">Choose bank</option>{banks.map((bank) => <option key={bank.code} value={bank.code}>{bank.name}</option>)}</select></label>
      <label className="field"><span>Account number</span><input inputMode="numeric" maxLength={10} value={number} onChange={(event) => { setNumber(event.target.value.replace(/\D/g, '').slice(0, 10)); setName('') }} /></label>
      {name && <p role="status">Verified account name: <strong>{name}</strong></p>}
      <div><button type="button" className="secondary-button" disabled={busy || !bankCode || number.length !== 10 || !!name} onClick={() => void verify()}>Verify account</button> {name && <button type="button" className="primary-button" disabled={busy} onClick={() => void save()}>Save account</button>} <button type="button" className="secondary-button" onClick={() => setEditing(false)}>Cancel</button></div></div>}
    {state?.account && Math.floor(Number(state.available_ngn)) > 0 && !editing && (confirming ? <div><p>Withdraw {money(Math.floor(Number(state.available_ngn)))} to {state.account.account_name}?</p><button type="button" className="primary-button" disabled={busy} onClick={() => void withdraw()}>{busy ? 'Submitting…' : 'Confirm withdrawal'}</button> <button type="button" className="secondary-button" onClick={() => setConfirming(false)}>Cancel</button></div> : <button type="button" className="primary-button" onClick={() => setConfirming(true)}>Withdraw</button>)}
    {!!state?.withdrawals?.length && <div className="commission-plan-list">{state.withdrawals.map((row) => <div key={row.id} className="commission-plan-row"><span>{money(Number(row.amount_ngn))} · {row.status}</span>{!['successful', 'failed'].includes(row.status) && <button type="button" className="secondary-button" disabled={busy} onClick={() => void check(row.id)}>Check status</button>}</div>)}</div>}
  </section>
}
