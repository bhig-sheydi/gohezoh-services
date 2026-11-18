import { useCallback, useEffect, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'

type ConnectInstance = { setup(): void; open(): void }
type ConnectClass = new (options: Record<string, unknown>) => ConnectInstance
declare global { interface Window { Connect?: ConnectClass } }

const config = {
  appId: import.meta.env.VITE_DOJAH_APP_ID as string | undefined,
  publicKey: import.meta.env.VITE_DOJAH_PUBLIC_KEY as string | undefined,
  widgetId: import.meta.env.VITE_DOJAH_RIDER_WIDGET_ID as string | undefined,
}

let scriptPromise: Promise<void> | null = null
function loadWidget() {
  if (window.Connect) return Promise.resolve()
  scriptPromise ??= new Promise<void>((resolve, reject) => {
    const script = document.createElement('script')
    script.src = 'https://widget.dojah.io/widget.js'
    script.onload = () => window.Connect ? resolve() : reject(new Error('Dojah verification is unavailable'))
    script.onerror = () => { scriptPromise = null; reject(new Error('Could not load Dojah verification')) }
    document.head.appendChild(script)
  })
  return scriptPromise
}

export default function IndependentRiderVerification({ supabase, phone, onVerified }: {
  supabase: SupabaseClient; phone: string; onVerified: () => Promise<void>
}) {
  const [status, setStatus] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const [savedPhone, setSavedPhone] = useState(phone)

  const refresh = useCallback(async () => {
    const { data, error: checkError } = await supabase.rpc('my_independent_rider_verification')
    if (checkError) { setError(checkError.message); return }
    const record = Array.isArray(data) ? data[0] : null
    setStatus(record?.status ?? '')
    if (record?.status === 'verified') await onVerified()
    if (record?.status === 'failed') setError(record.failure_reason ?? 'Verification did not pass. Try again.')
  }, [supabase, onVerified])
  useEffect(() => { const timer = window.setTimeout(() => { void refresh() }, 0); return () => window.clearTimeout(timer) }, [refresh])

  async function start(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!config.appId || !config.publicKey || !config.widgetId) {
      setError('Rider verification is being set up. Please try again later.'); return
    }
    setBusy(true); setError('')
    try {
      const { data: reference, error: beginError } = await supabase.rpc('begin_independent_rider_verification', { p_phone: savedPhone.trim() })
      if (beginError) throw beginError
      await loadWidget()
      if (!window.Connect) throw new Error('Dojah verification is unavailable')
      const widget = new window.Connect({
        app_id: config.appId, p_key: config.publicKey, type: 'custom', embed: false,
        config: { widget_id: config.widgetId }, reference_id: reference,
        onSuccess: () => { setStatus('pending'); void refresh() },
        onError: () => setError('Verification was interrupted. Please try again.'),
      })
      widget.setup(); widget.open(); setStatus('pending')
    } catch (cause) { setError(cause instanceof Error ? cause.message : 'Could not start verification') }
    finally { setBusy(false) }
  }

  return <section className="form-card narrow" aria-label="Rider verification">
    <h1>Verify your rider identity</h1>
    <p>Complete your NIN, live face and address checks to receive deliveries.</p>
    <form className="form-grid" onSubmit={event => void start(event)}>
      <label className="field"><span>Phone number</span><input type="tel" value={savedPhone} onChange={event => setSavedPhone(event.target.value)} required /></label>
      <button className="primary-button" disabled={busy || status === 'verified'}>{busy ? 'Opening verification...' : status === 'failed' ? 'Try verification again' : status === 'pending' ? 'Continue verification' : 'Start verification'}</button>
    </form>
    {status === 'pending' && <p role="status">Verification pending. Delivery access opens after Dojah confirms all three checks.</p>}
    {error && <p role="alert">{error}</p>}
    <button className="secondary-button" type="button" onClick={() => void refresh()}>Check verification status</button>
  </section>
}
