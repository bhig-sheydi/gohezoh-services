import { useCallback, useEffect, useRef, useState, type ChangeEvent } from 'react'
import { getSupabaseClient } from './lib/supabase'
import './partner-company-welcome.css'

type Company = { partner_id: string; partner_name: string; ceo_name: string; logo_path: string | null; earnings_ngn: number }
type Props = { supabase: ReturnType<typeof getSupabaseClient>; onError: (message: string) => void; onNotice: (message: string) => void }

function localGreeting(hour: number) {
  return hour < 12 ? 'Good morning' : hour < 17 ? 'Good afternoon' : 'Good evening'
}

function localDayRange(now: Date) {
  return {
    p_day_start: new Date(now.getFullYear(), now.getMonth(), now.getDate()).toISOString(),
    p_day_end: new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1).toISOString(),
  }
}

export default function PartnerCompanyWelcome({ supabase, onError, onNotice }: Props) {
  const [company, setCompany] = useState<Company | null>(null)
  const [logoUrl, setLogoUrl] = useState<string | null>(null)
  const [now, setNow] = useState(() => new Date())
  const [busy, setBusy] = useState(false)
  const fileInput = useRef<HTMLInputElement>(null)
  const lastDay = useRef(localDayRange(new Date()).p_day_start)

  const refresh = useCallback(async () => {
    const { data, error } = await supabase.rpc('my_partner_company_welcome', localDayRange(new Date()))
    if (error) { onError(error.message); return }
    const row = (data as Company[] | null)?.[0] ?? null
    setCompany(row)
    if (!row?.logo_path) { setLogoUrl(null); return }
    const signed = await supabase.storage.from('partner-logos').createSignedUrl(row.logo_path, 3600)
    if (signed.error) { onError(signed.error.message); setLogoUrl(null) }
    else setLogoUrl(signed.data?.signedUrl ?? null)
  }, [onError, supabase])

  useEffect(() => {
    const initial = window.setTimeout(() => { void refresh() }, 0)
    const timer = window.setInterval(() => {
      const next = new Date()
      setNow(next)
      const day = localDayRange(next).p_day_start
      if (day !== lastDay.current) { lastDay.current = day; void refresh() }
    }, 60_000)
    return () => { window.clearTimeout(initial); window.clearInterval(timer) }
  }, [refresh])

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
      <button className="partner-company-logo" type="button" onClick={() => fileInput.current?.click()} disabled={busy} aria-label={logoUrl ? 'Change company logo' : 'Upload company logo'}>
        {logoUrl ? <img src={logoUrl} alt={`${company.partner_name} logo`} /> : <span aria-hidden="true">+</span>}
      </button>
      <input ref={fileInput} type="file" accept="image/jpeg,image/png,image/webp" onChange={(event) => void uploadLogo(event)} className="partner-company-file" aria-label="Company logo image" />
      <div><p className="eyebrow">{company.partner_name}</p><h1>{localGreeting(now.getHours())}, {company.ceo_name || 'partner'}</h1><p className="partner-company-logo-hint">{busy ? 'Saving logo...' : 'Tap the logo to change it'}</p></div>
    </div>
    <div className="partner-company-earnings"><span>Today's earnings</span><strong>{new Intl.NumberFormat('en-NG', { style: 'currency', currency: 'NGN' }).format(Number(company.earnings_ngn) || 0)}</strong><small>Confirmed from today's deliveries</small></div>
  </section>
}
