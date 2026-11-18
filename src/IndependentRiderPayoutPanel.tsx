import { useCallback, useEffect, useRef, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { parseWithdrawalQuote, type WithdrawalQuote } from './lib/withdrawalQuote'
import WithdrawalFeePreview from './WithdrawalFeePreview'

type Bank = { code: string; name: string }
type Account = { bankName: string; accountName: string; accountLast4: string }
type Earnings = { available_ngn: number; pending_delivery_ngn: number; withdrawal_pending_ngn: number; total_paid_ngn: number }
type Withdrawal = { withdrawal_id: string; transfer_amount_ngn: number; status: string; created_at: string }
const money = (value: number) => new Intl.NumberFormat('en-NG', { style: 'currency', currency: 'NGN' }).format(value || 0)

export default function IndependentRiderPayoutPanel({ supabase }: { supabase: SupabaseClient }) {
  const [earnings, setEarnings] = useState<Earnings | null>(null)
  const [withdrawals, setWithdrawals] = useState<Withdrawal[]>([])
  const [account, setAccount] = useState<Account | null>(null)
  const [banks, setBanks] = useState<Bank[]>([])
  const [bankCode, setBankCode] = useState('')
  const [accountNumber, setAccountNumber] = useState('')
  const [accountName, setAccountName] = useState('')
  const [editing, setEditing] = useState(false)
  const [quote, setQuote] = useState<WithdrawalQuote | null>(null)
  const [accepted, setAccepted] = useState(false)
  const [busy, setBusy] = useState(false)
  const [testMode, setTestMode] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const key = useRef<string | null>(null)

  const invoke = useCallback(async (body: Record<string, unknown>) => {
    const { data, error: callError } = await supabase.functions.invoke('paystack-rider-payout', { body })
    if (callError || data?.error) {
      setError(String(data?.error ?? callError?.message ?? 'Payout is unavailable. Try again later.'))
      return null
    }
    setTestMode(Boolean(data?.testMode))
    return data as Record<string, unknown>
  }, [supabase])

  const refresh = useCallback(async () => {
    const [payables, history, details] = await Promise.all([
      supabase.rpc('get_my_independent_rider_payables'),
      supabase.rpc('list_my_independent_rider_withdrawals'),
      invoke({ action: 'account' }),
    ])
    if (payables.error || history.error) {
      setError(payables.error?.message ?? history.error?.message ?? 'Rider earnings are unavailable')
      return
    }
    setEarnings((payables.data as Earnings[] | null)?.[0] ?? null)
    setWithdrawals((history.data as Withdrawal[] | null) ?? [])
    if (details) setAccount((details.account as Account | null) ?? null)
  }, [supabase, invoke])

  useEffect(() => { const timer = window.setTimeout(() => void refresh(), 0); return () => window.clearTimeout(timer) }, [refresh])

  async function openAccount() {
    setEditing(true); setError(''); setAccountName(''); setAccountNumber('')
    if (banks.length) return
    const result = await invoke({ action: 'banks' })
    if (result) setBanks((result.banks as Bank[] | undefined) ?? [])
  }
  async function verifyAccount() {
    if (!bankCode || !/^\d{10}$/.test(accountNumber) || busy) return
    setBusy(true); setError('')
    const result = await invoke({ action: 'resolve', bankCode, accountNumber })
    if (result?.accountName && result.accountNumber === accountNumber && result.bankCode === bankCode)
      setAccountName(String(result.accountName))
    setBusy(false)
  }
  async function saveAccount() {
    if (!accountName || busy) return
    setBusy(true); setError('')
    const result = await invoke({ action: 'save-account', bankCode, accountNumber, accountName })
    if (result) { setEditing(false); setAccountName(''); setAccountNumber(''); setNotice('Bank account verified.'); await refresh() }
    setBusy(false)
  }
  async function preview() {
    const available = Math.floor(Number(earnings?.available_ngn ?? 0))
    if (!account || available < 60 || busy) return
    setBusy(true); setError(''); setAccepted(false)
    const result = await invoke({ action: 'quote' })
    if (result) {
      const next = parseWithdrawalQuote(result, available)
      if (next) setQuote(next)
      else setError('Could not calculate bank charges. Refresh your balance and try again.')
    }
    setBusy(false)
  }
  async function withdraw() {
    if (!account || !quote || !accepted || busy ||
      quote.grossDebitNgn + quote.remainderNgn !== Math.floor(Number(earnings?.available_ngn ?? 0))) return
    setBusy(true); setError(''); setNotice('')
    const idempotencyKey = key.current ?? crypto.randomUUID()
    key.current = idempotencyKey
    const result = await invoke({ action: 'withdraw', amountNgn: quote.netAmountNgn, idempotencyKey })
    if (result?.withdrawalId) {
      key.current = null; setQuote(null); setAccepted(false)
      setNotice(`Withdrawal ${String(result.status ?? 'submitted')}. Check its status below.`)
      await refresh()
    }
    setBusy(false)
  }
  async function checkStatus(withdrawalId: string) {
    setBusy(true); setError('')
    const result = await invoke({ action: 'status', withdrawalId })
    if (result) await refresh()
    setBusy(false)
  }

  return <section className="form-card referral-payout" aria-label="Rider withdrawals">
    <div className="history-heading"><div><p className="eyebrow">YOUR DELIVERY EARNINGS</p><h2>Withdraw to bank</h2></div><strong>{money(Number(earnings?.available_ngn ?? 0))} available</strong></div>
    <p>Your completed, paid deliveries earn you the full 75% rider share. Bank transfer charges are shown before you confirm.</p>
    {testMode && <p className="customer-payment-test-warning">TEST MODE — no real bank transfer will be made.</p>}
    {error && <p role="alert">{error}</p>}{notice && <p role="status">{notice}</p>}
    {account ? <p>Verified account: <strong>{account.accountName}</strong> · {account.bankName} ····{account.accountLast4}</p> : <p>Verify your bank account before withdrawing.</p>}
    {!editing && <button type="button" className="secondary-button" disabled={busy} onClick={() => void openAccount()}>{account ? 'Change bank account' : 'Add bank account'}</button>}
    {editing && <div className="form-grid"><label className="field"><span>Bank</span><select value={bankCode} onChange={(event) => { setBankCode(event.target.value); setAccountName('') }}><option value="">Choose bank</option>{banks.map((bank) => <option key={bank.code} value={bank.code}>{bank.name}</option>)}</select></label>
      <label className="field"><span>Account number</span><input inputMode="numeric" maxLength={10} value={accountNumber} onChange={(event) => { setAccountNumber(event.target.value.replace(/\D/g, '').slice(0, 10)); setAccountName('') }} /></label>
      {accountName && <p role="status">Verified account name: <strong>{accountName}</strong></p>}
      <div><button type="button" className="secondary-button" disabled={busy || !bankCode || accountNumber.length !== 10 || !!accountName} onClick={() => void verifyAccount()}>Verify account</button> {accountName && <button type="button" className="primary-button" disabled={busy} onClick={() => void saveAccount()}>Save account</button>} <button type="button" className="secondary-button" disabled={busy} onClick={() => setEditing(false)}>Cancel</button></div></div>}
    {account && !editing && Math.floor(Number(earnings?.available_ngn ?? 0)) >= 60 && (quote ? <div className="referral-payout-confirm" role="group" aria-label="Confirm rider withdrawal"><p>Send to {account.accountName} at {account.bankName} ending {account.accountLast4}</p><WithdrawalFeePreview quote={quote} /><label className="withdrawal-charges-ack"><input type="checkbox" checked={accepted} onChange={(event) => setAccepted(event.target.checked)} disabled={busy} /> I understand these charges will be deducted from my earnings.</label><div className="referral-payout-confirm-actions"><button type="button" className="primary-button" disabled={busy || !accepted} onClick={() => void withdraw()}>Confirm withdrawal</button><button type="button" className="secondary-button" disabled={busy} onClick={() => { setQuote(null); setAccepted(false) }}>Cancel</button></div></div> : <button type="button" className="primary-button" disabled={busy} onClick={() => void preview()}>Withdraw</button>)}
    {earnings && <p>{money(Number(earnings.withdrawal_pending_ngn))} in pending withdrawals · {money(Number(earnings.total_paid_ngn))} paid</p>}
    {withdrawals.length > 0 && <div className="commission-plan-list">{withdrawals.map((row) => <div key={row.withdrawal_id} className="commission-plan-row"><span>{money(Number(row.transfer_amount_ngn))} to bank · {row.status}</span>{!['successful','failed'].includes(row.status) && <button type="button" className="secondary-button" disabled={busy} onClick={() => void checkStatus(row.withdrawal_id)}>Check status</button>}</div>)}</div>}
  </section>
}
