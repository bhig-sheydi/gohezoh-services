import { useCallback, useEffect, useRef, useState, type ChangeEvent } from 'react'
import { getSupabaseClient } from './lib/supabase'
import './partner-company-welcome.css'

type Company = { partner_id: string; partner_name: string; ceo_name: string; logo_path: string | null; earnings_ngn: number }
type Payables = { partner_id: string; currency: string; available_ngn: number; pending_delivery_ngn: number; withdrawal_pending_ngn: number; total_paid_ngn: number }
type Bank = { code: string; name: string }
type PayoutAccount = { bankName: string; accountLast4: string; accountName: string; verifiedAt: string }
type ResolvedAccount = { bankCode: string; bankName: string; accountNumber: string; accountName: string }
type Withdrawal = { withdrawalId: string; status: 'reserved' | 'initiating' | 'queued' | 'successful' | 'failed' | 'unknown'; amountNgn: number; transferReference?: string }
type Props = { supabase: ReturnType<typeof getSupabaseClient>; onError: (message: string) => void; onNotice: (message: string) => void; showPayout?: boolean; canEditLogo?: boolean }

async function payoutErrorMessage(error: { message: string; context?: unknown }) {
  if (error.context instanceof Response) {
    try {
      const body: unknown = await error.context.clone().json()
      if (body && typeof body === 'object' && 'error' in body && typeof body.error === 'string') return body.error
    } catch { /* Keep the network error when the response has no JSON body. */ }
  }
  return error.message
}

function localGreeting(hour: number) {
  return hour < 12 ? 'Good morning' : hour < 17 ? 'Good afternoon' : 'Good evening'
}

function localDayRange(now: Date) {
  return {
    p_day_start: new Date(now.getFullYear(), now.getMonth(), now.getDate()).toISOString(),
    p_day_end: new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1).toISOString(),
  }
}

export default function PartnerCompanyWelcome({ supabase, onError, onNotice, showPayout = true, canEditLogo = true }: Props) {
  const [company, setCompany] = useState<Company | null>(null)
  const [logoUrl, setLogoUrl] = useState<string | null>(null)
  const [now, setNow] = useState(() => new Date())
  const [busy, setBusy] = useState(false)
  const [payables, setPayables] = useState<Payables | null>(null)
  const [withdrawing, setWithdrawing] = useState(false)
  const [account, setAccount] = useState<PayoutAccount | null>(null)
  const [banks, setBanks] = useState<Bank[]>([])
  const [editingAccount, setEditingAccount] = useState(false)
  const [bankCode, setBankCode] = useState('')
  const [accountNumber, setAccountNumber] = useState('')
  const [resolvedAccount, setResolvedAccount] = useState<ResolvedAccount | null>(null)
  const [accountBusy, setAccountBusy] = useState(false)
  const [confirmingWithdrawal, setConfirmingWithdrawal] = useState(false)
  const [withdrawal, setWithdrawal] = useState<Withdrawal | null>(null)
  const [testMode, setTestMode] = useState(false)
  const [verificationTestMode, setVerificationTestMode] = useState(false)
  const withdrawalKey = useRef<string | null>(null)
  const fileInput = useRef<HTMLInputElement>(null)
  const lastDay = useRef(localDayRange(new Date()).p_day_start)
  const companyId = useRef<string | null>(null)
  const payablesLoading = useRef(false)

  const refreshPayables = useCallback(async (partnerId?: string) => {
    if (payablesLoading.current) return
    payablesLoading.current = true
    try {
      const [{ data, error }, withdrawalResult] = await Promise.all([
        supabase.rpc('get_my_partner_payables'),
        (partnerId ?? companyId.current) ? supabase.rpc('list_my_partner_withdrawals', { p_partner_id: partnerId ?? companyId.current }) : Promise.resolve({ data: [], error: null }),
      ])
      if (error) { onError(error.message); return }
      if (withdrawalResult.error) onError(withdrawalResult.error.message)
      const rows = (data as Payables[] | null) ?? []
      setPayables(rows.find((item) => item.partner_id === (partnerId ?? companyId.current)) ?? null)
      const latest = (withdrawalResult.data as Array<{ withdrawal_id: string; status: string; amount_ngn: number }> | null)?.[0]
      if (latest?.withdrawal_id && ['reserved', 'initiating', 'queued', 'successful', 'failed', 'unknown'].includes(latest.status)) setWithdrawal({ withdrawalId: latest.withdrawal_id, status: latest.status as Withdrawal['status'], amountNgn: Number(latest.amount_ngn) })
    } finally { payablesLoading.current = false }
  }, [onError, supabase])

  const refresh = useCallback(async () => {
    const { data, error } = await supabase.rpc('my_partner_company_welcome', localDayRange(new Date()))
    if (error) { onError(error.message); return }
    const row = (data as Company[] | null)?.[0] ?? null
    setCompany(row)
    companyId.current = row?.partner_id ?? null
    if (showPayout) await refreshPayables(row?.partner_id)
    if (row && showPayout) {
      const payout = await supabase.functions.invoke('flutterwave-payout', { body: { action: 'account', partnerId: row.partner_id } })
      if (payout.error) onError(await payoutErrorMessage(payout.error))
      else { setAccount((payout.data as { account?: PayoutAccount | null })?.account ?? null); setTestMode(!!payout.data?.testMode); setVerificationTestMode(!!payout.data?.verificationTestMode) }
    }
    if (!row?.logo_path) { setLogoUrl(null); return }
    const signed = await supabase.storage.from('partner-logos').createSignedUrl(row.logo_path, 3600)
    if (signed.error) { onError(signed.error.message); setLogoUrl(null) }
    else setLogoUrl(signed.data?.signedUrl ?? null)
  }, [onError, refreshPayables, showPayout, supabase])

  async function openAccountEditor() {
    if (!company) return
    setEditingAccount(true)
    setResolvedAccount(null)
    setAccountNumber('')
    if (banks.length) return
    setAccountBusy(true)
    const { data, error } = await supabase.functions.invoke('flutterwave-payout', { body: { action: 'banks', partnerId: company.partner_id } })
    if (error) onError(await payoutErrorMessage(error))
    else { setBanks((data as { banks?: Bank[] })?.banks ?? []); setTestMode(!!data?.testMode); setVerificationTestMode(!!data?.verificationTestMode) }
    setAccountBusy(false)
  }

  async function resolveBankAccount() {
    if (!company || !bankCode || !/^\d{10}$/.test(accountNumber) || accountBusy) return
    setAccountBusy(true)
    setResolvedAccount(null)
    const { data, error } = await supabase.functions.invoke('flutterwave-payout', { body: { action: 'resolve', partnerId: company.partner_id, bankCode, accountNumber } })
    if (error) onError(await payoutErrorMessage(error))
    else if (data?.accountName && data?.accountNumber === accountNumber && data?.bankCode === bankCode) { setResolvedAccount(data as ResolvedAccount); if (data?.testMode) setTestMode(true) }
    else onError('The account could not be verified. Check the bank and account number.')
    setAccountBusy(false)
  }

  async function saveBankAccount() {
    if (!company || !resolvedAccount || accountBusy) return
    setAccountBusy(true)
    const { data, error } = await supabase.functions.invoke('flutterwave-payout', { body: { action: 'save-account', partnerId: company.partner_id, bankCode: resolvedAccount.bankCode, accountNumber: resolvedAccount.accountNumber, accountName: resolvedAccount.accountName } })
    if (error) onError(await payoutErrorMessage(error))
    else if (data?.account) { setAccount(data.account as PayoutAccount); setEditingAccount(false); setResolvedAccount(null); setAccountNumber(''); if (data?.testMode) setTestMode(true); onNotice('Verified payout account saved.') }
    else onError('The payout account was not saved.')
    setAccountBusy(false)
  }

  async function requestWithdrawal() {
    if (!company || !account || !payables || withdrawing || Number(payables.available_ngn) <= 0) return
    setWithdrawing(true)
    const idempotencyKey = withdrawalKey.current ?? crypto.randomUUID()
    withdrawalKey.current = idempotencyKey
    const { data, error } = await supabase.functions.invoke('flutterwave-payout', { body: {
      action: 'withdraw', partnerId: company.partner_id, amountNgn: Math.floor(Number(payables.available_ngn)), idempotencyKey,
    } })
    if (error) onError(await payoutErrorMessage(error))
    else if (data?.withdrawalId) {
      setWithdrawal(data as Withdrawal)
      if (data?.testMode) setTestMode(true)
      setConfirmingWithdrawal(false)
      withdrawalKey.current = null
      onNotice('Withdrawal submitted. Check its status below.')
      await refreshPayables(company.partner_id)
    } else onError('The withdrawal status is unknown. Check again before retrying.')
    setWithdrawing(false)
  }

  async function checkWithdrawal() {
    if (!withdrawal) return
    const { data, error } = await supabase.functions.invoke('flutterwave-payout', { body: { action: 'status', partnerId: company?.partner_id, withdrawalId: withdrawal.withdrawalId } })
    if (error) onError(await payoutErrorMessage(error))
    else if (data?.withdrawalId === withdrawal.withdrawalId) { setWithdrawal(data as Withdrawal); if (data?.testMode) setTestMode(true); await refreshPayables(company?.partner_id) }
  }

  useEffect(() => {
    const initial = window.setTimeout(() => { void refresh() }, 0)
    const timer = window.setInterval(() => {
      const next = new Date()
      setNow(next)
      const day = localDayRange(next).p_day_start
      if (day !== lastDay.current) { lastDay.current = day; void refresh() }
    }, 60_000)
    const payablesTimer = window.setInterval(() => {
      if (showPayout && document.visibilityState === 'visible') void refreshPayables()
    }, 30_000)
    const focused = () => { if (showPayout) void refreshPayables() }
    window.addEventListener('focus', focused)
    return () => { window.clearTimeout(initial); window.clearInterval(timer); window.clearInterval(payablesTimer); window.removeEventListener('focus', focused) }
  }, [refresh, refreshPayables, showPayout])

  async function uploadLogo(event: ChangeEvent<HTMLInputElement>) {
    const file = event.currentTarget.files?.[0]
    event.currentTarget.value = ''
    if (!file || !company || busy) return
    if (!['image/jpeg', 'image/png', 'image/webp'].includes(file.type) || file.size > 5 * 1024 * 1024) {
      onError('Choose a JPEG, PNG, or WebP logo under 5 MB.'); return
    }
    setBusy(true)
    const extension = file.type === 'image/jpeg' ? 'jpg' : file.type === 'image/png' ? 'png' : 'webp'
    const path = `${company.partner_id}/${crypto.randomUUID()}.${extension}`
    const bucket = supabase.storage.from('partner-logos')
    const uploaded = await bucket.upload(path, file, { contentType: file.type, upsert: false })
    if (uploaded.error) { onError(uploaded.error.message); setBusy(false); return }
    const saved = await supabase.rpc('set_my_partner_logo', { p_partner_id: company.partner_id, p_path: path })
    if (saved.error) {
      await bucket.remove([path]); onError(saved.error.message); setBusy(false); return
    }
    if (company.logo_path && company.logo_path !== path) await bucket.remove([company.logo_path])
    onNotice('Company logo saved.')
    await refresh()
    setBusy(false)
  }

  if (!company) return null
  return <section className="partner-company-welcome" aria-label="Company overview">
    <div className="partner-company-identity">
      <button className="partner-company-logo" type="button" onClick={() => fileInput.current?.click()} disabled={busy || !canEditLogo} aria-label={logoUrl ? 'Change company logo' : 'Upload company logo'}>
        {logoUrl ? <img src={logoUrl} alt={`${company.partner_name} logo`} /> : <span aria-hidden="true">+</span>}
      </button>
      <input ref={fileInput} type="file" accept="image/jpeg,image/png,image/webp" onChange={(event) => void uploadLogo(event)} className="partner-company-file" aria-label="Company logo image" />
      <div><p className="eyebrow">{company.partner_name}</p><h1>{localGreeting(now.getHours())}, {company.ceo_name || 'partner'}</h1>{canEditLogo && <p className="partner-company-logo-hint">{busy ? 'Saving logo...' : 'Tap the logo to change it'}</p>}</div>
    </div>
    {showPayout && <div className="partner-company-finances">
      <div className="partner-company-earnings"><span>Today's earnings</span><strong>{new Intl.NumberFormat('en-NG', { style: 'currency', currency: 'NGN' }).format(Number(company.earnings_ngn) || 0)}</strong><small>Confirmed from today's deliveries</small></div>
      {payables && <div className="partner-company-payables" aria-label="Company payout balance">
        {testMode && <p className="partner-payout-test-mode">Test mode — no real bank transfer will be made.</p>}
        <div><span>Available to withdraw</span><strong>{formatNaira(payables.available_ngn)}</strong></div>
        <div><span>Paid deliveries awaiting confirmation</span><strong>{formatNaira(payables.pending_delivery_ngn)}</strong></div>
        {Number(payables.withdrawal_pending_ngn) > 0 && <p>Transfer in progress: {formatNaira(payables.withdrawal_pending_ngn)}</p>}
        <div className="partner-payout-destination">
          {account ? <><span>Verified payout account</span><strong>{account.accountName}</strong><small>{account.bankName} ·•••• {account.accountLast4}</small></> : <small>Add a bank account before withdrawing.</small>}
          {!confirmingWithdrawal && <button type="button" className="secondary-button" onClick={() => void openAccountEditor()}>{account ? 'Change bank account' : 'Add bank account'}</button>}
        </div>
        {!confirmingWithdrawal ? <button type="button" className="primary-button" disabled={withdrawing || !account || Number(payables.available_ngn) < 1 || (testMode && !verificationTestMode)} onClick={() => setConfirmingWithdrawal(true)}>Withdraw</button> : <div className="partner-payout-confirm" role="group" aria-label="Confirm withdrawal"><p>Send {formatNaira(Math.floor(Number(payables.available_ngn)))} to {account?.accountName} at {account?.bankName} ending {account?.accountLast4}?</p><button type="button" className="primary-button" disabled={withdrawing} onClick={() => void requestWithdrawal()}>{withdrawing ? 'Submitting...' : 'Confirm withdrawal'}</button><button type="button" className="secondary-button" disabled={withdrawing} onClick={() => setConfirmingWithdrawal(false)}>Cancel</button></div>}
        {testMode && !verificationTestMode && <small>Bank verification is available. Withdrawals remain off until live transfers are ready.</small>}
        {withdrawal && <div className="partner-payout-status" role="status"><span>Latest withdrawal</span><strong>{formatWithdrawalStatus(withdrawal.status)}</strong><small>{formatNaira(withdrawal.amountNgn)}{withdrawal.transferReference ? ` · ${withdrawal.transferReference}` : ''}</small>{!['successful','failed'].includes(withdrawal.status) && <button type="button" className="secondary-button" onClick={() => void checkWithdrawal()}>Check status</button>}</div>}
        <small>Paid delivery earnings become withdrawable after the recipient's code or booking customer's confirmation completes delivery.</small>
      </div>}
    </div>}
    {showPayout && editingAccount && <div className="partner-payout-account-form" aria-label="Bank account details">
      <div className="partner-payout-form-heading"><div><p className="eyebrow">PAYOUT DETAILS</p><h2>{account ? 'Change bank account' : 'Add bank account'}</h2><p>Choose your bank and enter your account number. We will show the account name before you save.</p></div><button type="button" className="partner-payout-close" aria-label="Close bank account form" onClick={() => { setEditingAccount(false); setResolvedAccount(null); setAccountNumber('') }}>×</button></div>
      {verificationTestMode && <p className="partner-payout-sandbox-note">Bank verification is in test mode. Flutterwave accepts Access Bank sample accounts 0690000031–0690000041 only. To verify your real account, a live verification key must be configured; this does not enable withdrawals.</p>}
      <div className="partner-payout-fields">
        <label className="field"><span>Bank</span><select value={bankCode} onChange={(event) => { setBankCode(event.target.value); setResolvedAccount(null) }} disabled={accountBusy}><option value="">Select bank</option>{banks.map((bank) => <option value={bank.code} key={bank.code}>{bank.name}</option>)}</select></label>
        <label className="field"><span>Account number</span><input value={accountNumber} onChange={(event) => { setAccountNumber(event.target.value.replace(/\D/g, '').slice(0, 10)); setResolvedAccount(null) }} inputMode="numeric" autoComplete="off" maxLength={10} placeholder="10 digits" /></label>
      </div>
      {resolvedAccount && <div className="partner-payout-resolved" role="status"><span>Verified account name</span><strong>{resolvedAccount.accountName}</strong><small>Confirm this is the right person or business before saving.</small></div>}
      <div className="partner-payout-actions"><button type="button" className="primary-button" disabled={accountBusy || !bankCode || accountNumber.length !== 10 || !!resolvedAccount} onClick={() => void resolveBankAccount()}>{accountBusy ? 'Checking account...' : 'Verify account'}</button>{resolvedAccount && <button type="button" className="primary-button" disabled={accountBusy} onClick={() => void saveBankAccount()}>Confirm and save</button>}</div>
    </div>}
  </section>
}

function formatNaira(amount: number) {
  return new Intl.NumberFormat('en-NG', { style: 'currency', currency: 'NGN' }).format(Number(amount) || 0)
}

function formatWithdrawalStatus(status: Withdrawal['status']) {
  return ({ reserved: 'Reserved', initiating: 'Starting transfer', queued: 'Transfer queued', successful: 'Transfer successful', failed: 'Transfer failed', unknown: 'Checking transfer' })[status]
}
