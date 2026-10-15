import { useEffect, useRef, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import './partner-vehicles.css'

export type PreviewDocument = { bucket: 'partner-verification' | 'partner-vehicles'; path: string; title: string }
export default function DocumentPreview({ supabase, document, onClose }: { supabase: SupabaseClient; document: PreviewDocument; onClose: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null)
  const [url, setUrl] = useState('')
  const [error, setError] = useState(false)
  useEffect(() => {
    const element = dialog.current
    const previous = window.document.activeElement as HTMLElement | null
    if (element && !element.open) { if (element.showModal) element.showModal(); else element.setAttribute('open', '') }
    let active = true
    void supabase.storage.from(document.bucket).createSignedUrl(document.path, 300).then(({ data, error }) => {
      if (active) { if (error || !data?.signedUrl) setError(true); else setUrl(data.signedUrl) }
    }).catch(() => { if (active) setError(true) })
    return () => { active = false; element?.close?.(); previous?.focus() }
  }, [supabase, document.bucket, document.path])
  return <dialog ref={dialog} className="document-preview" aria-label={document.title} onCancel={(event) => { event.preventDefault(); onClose() }}>
    <header><strong>{document.title}</strong><button className="secondary-button" type="button" autoFocus onClick={onClose}>Cancel</button></header>
    {error ? <p role="alert">Could not load this document. Close and try again.</p> : !url ? <p role="status">Loading document...</p> : /\.pdf$/i.test(document.path) ? <iframe title={document.title} src={url} /> : <img src={url} alt={document.title} onError={() => setError(true)} />}
  </dialog>
}
