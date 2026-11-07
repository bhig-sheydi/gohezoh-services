import { useCallback, useEffect, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { parseWithdrawalQuote, type WithdrawalQuote } from './lib/withdrawalQuote'
import WithdrawalFeePreview from './WithdrawalFeePreview'

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
  const [quote, setQuote] = useState<WithdrawalQuote | null>(null)
  const [quoting, setQuoting] = useState(false)
  const [chargesAccepted, setChargesAccepted] = useState(false)
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
    if (data) { setEditing(false); setConfirming(false); setQuote(null); setName(''); setNumber(''); onNotice('Payout account verified.'); await load() }
    setBusy(false)
  }
  async function openWithdrawalPreview() {
    if (!state?.account || quoting || busy) return
    const amountNgn = Math.floor(Number(state.available_ngn))
    if (amountNgn <= 0) return
    setQuoting(true)
    setQuote(null)
    setChargesAccepted(false)
    const data = await invoke({ action: 'quote', amountNgn })
    if (data) {
      const next = parseWithdrawalQuote(data, amountNgn)
      if (!next) onError('Could not calculate the bank charges. Please try again.')
      else { setQuote(next); setConfirming(true) }
    }
    setQuoting(false)
  }
  async function withdraw() {
    if (!state?.account || !quote || !chargesAccepted || busy
      || quote.grossDebitNgn + quote.remainderNgn !== Math.floor(Number(state.available_ngn))) return
    const idempotencyKey = key ?? crypto.randomUUID()
    setKey(idempotencyKey); setBusy(true)
    const data = await invoke({ action: 'withdraw', amountNgn: quote.netAmountNgn, idempotencyKey })
    if (data) { setKey(null); setConfirming(false); setQuote(null); setChargesAccepted(false); onNotice(data.testMode ? 'Test withdrawal submitted.' : 'Withdrawal submitted.'); await load() }
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
    {state?.account && Math.floor(Number(state.available_ngn)) > 0 && !editing && (confirming ? <div className="referral-payout-confirm" role="group" aria-label="Confirm withdrawal"><p>Send to {state.account.account_name} at {state.account.bank_name} ending {state.account.account_last4}</p>{quote && <WithdrawalFeePreview quote={quote} />}<label className="withdrawal-charges-ack"><input type="checkbox" checked={chargesAccepted} onChange={(event) => setChargesAccepted(event.target.checked)} disabled={busy} /> I understand these charges will be deducted from my earnings.</label><div className="referral-payout-confirm-actions"><button type="button" className="primary-button" disabled={busy || !chargesAccepted || !quote || quote.grossDebitNgn + quote.remainderNgn !== Math.floor(Number(state.available_ngn))} onClick={() => void withdraw()}>{busy ? 'Submitting…' : 'Confirm withdrawal'}</button><button type="button" className="secondary-button" disabled={busy} onClick={() => { setConfirming(false); setQuote(null); setChargesAccepted(false) }}>Cancel</button></div></div> : <><small>Bank transfer charges will be deducted from your earnings. You will see the exact amount before confirming.</small><button type="button" className="primary-button" disabled={quoting || busy} onClick={() => void openWithdrawalPreview()}>{quoting ? 'Calculating charges...' : 'Withdraw'}</button></>)}
    {!!state?.withdrawals?.length && <div className="commission-plan-list">{state.withdrawals.map((row) => <div key={row.id} className="commission-plan-row"><span>To bank: {money(Number(row.amount_ngn))} · {row.status}</span>{!['successful', 'failed'].includes(row.status) && <button type="button" className="secondary-button" disabled={busy} onClick={() => void check(row.id)}>Check status</button>}</div>)}</div>}
  </section>
}
