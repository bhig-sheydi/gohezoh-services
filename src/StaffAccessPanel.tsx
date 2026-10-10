import { useCallback, useEffect, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'

type Application = { id: string; requested_role: string; status: string; created_at: string; partner_document_type: string | null; partner_document_path: string | null }

export default function StaffAccessPanel({ supabase, userId, onError, onNotice }: {
  supabase: SupabaseClient; userId: string; onError: (message: string) => void; onNotice: (message: string) => void
}) {
  const [applications, setApplications] = useState<Application[]>([])
  const [busy, setBusy] = useState(false)
  const load = useCallback(async () => {
    const { data, error } = await supabase.from('staff_applications').select('id,requested_role,status,created_at,partner_document_type,partner_document_path').eq('user_id', userId).order('created_at', { ascending: false })
    if (error) onError(error.message)
    else setApplications((data ?? []) as Application[])
  }, [supabase, userId, onError])
  useEffect(() => { const timer = window.setTimeout(() => { void load() }, 0); return () => window.clearTimeout(timer) }, [load])

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const form = new FormData(event.currentTarget)
    setBusy(true); onError('')
    const { error } = await supabase.rpc('request_staff_access', {
      p_role: String(form.get('role')),
      p_organization_name: String(form.get('organization_name') ?? '').trim() || null,
    })
    if (error) onError(error.message)
    else { onNotice('Your request is awaiting Super Admin approval.'); await load() }
    setBusy(false)
  }

  async function uploadDocument(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const application = applications.find((item) => item.requested_role === 'partner' && item.status === 'pending')
    if (!application) return
    const form = new FormData(event.currentTarget)
    const file = (event.currentTarget.elements.namedItem('document') as HTMLInputElement | null)?.files?.[0]
    if (!file || !file.size || file.size > 5242880 || !['application/pdf', 'image/jpeg', 'image/png', 'image/webp'].includes(file.type)) {
      onError('Choose a PDF or image under 5 MB.'); return
    }
    const extension = ({ 'application/pdf': 'pdf', 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' } as Record<string, string>)[file.type]
    const path = `${userId}/${application.id}/${crypto.randomUUID()}.${extension}`
    setBusy(true); onError('')
    const bucket = supabase.storage.from('partner-verification')
    const uploaded = await bucket.upload(path, file, { contentType: file.type, upsert: false })
    if (uploaded.error) onError(uploaded.error.message)
    else {
      const { error } = await supabase.rpc('submit_partner_document', { p_application_id: application.id, p_document_type: String(form.get('document_type')), p_storage_path: path })
      if (error) { await bucket.remove([path]); onError(error.message) }
      else {
        if (application.partner_document_path && application.partner_document_path !== path) await bucket.remove([application.partner_document_path])
        onNotice('Document submitted for Super Admin review.'); await load()
      }
    }
    setBusy(false)
  }

  const latest = applications[0]
  return <section className="form-card narrow"><p className="eyebrow">ACCOUNT ACCESS</p><h1>{latest?.status === 'pending' ? 'Staff access pending' : 'Request staff access'}</h1>
    {latest?.status === 'pending' ? <p className="section-intro">Your {latest.requested_role.replaceAll('_', ' ')} request is awaiting Super Admin review. Your email must be confirmed before approval.</p> : <p className="section-intro">Choose the category you need. A Super Admin must approve it before you can use that workspace.</p>}
    {applications.length > 0 && <div className="admin-list">{applications.map((application) => <p key={application.id}>{application.requested_role.replaceAll('_', ' ')}: {application.status}</p>)}</div>}
    {applications.some((item) => item.requested_role === 'partner' && item.status === 'pending') && <form className="form-grid" onSubmit={uploadDocument}><h2>Partner verification</h2><p className="section-intro">Submit a NIN or CAC registration document. Super Admin approval waits for this file. PDF or image, up to 5 MB.</p>{applications.find((item) => item.requested_role === 'partner' && item.status === 'pending')?.partner_document_path && <p>Document submitted. You may replace it before approval.</p>}<label className="field"><span>Document type</span><select name="document_type" required><option value="nin">NIN</option><option value="cac">CAC registration</option></select></label><label className="field"><span>NIN or CAC document</span><input name="document" type="file" accept=".pdf,.jpg,.jpeg,.png,.webp,application/pdf,image/jpeg,image/png,image/webp" required /></label><button className="primary-button" disabled={busy}>{busy ? 'Uploading...' : 'Submit document'}</button></form>}
    {!latest || ['rejected','revoked'].includes(latest.status) ? <form className="form-grid" onSubmit={submit}><label className="field"><span>Requested category</span><select name="role" required><option value="operations">Operations</option><option value="warehouse">Warehouse</option><option value="finance">Finance</option><option value="bdo">Business Development</option><option value="partner">Logistics Partner</option><option value="management">Management</option></select></label><label className="field"><span>Organization or partner name</span><input name="organization_name" /></label><button className="primary-button" disabled={busy}>{busy ? 'Submitting...' : 'Request access'}</button></form> : null}
    <button className="secondary-button" onClick={() => void load()}>Refresh status</button>
  </section>
}
