import { useRef, useState, type ReactNode } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import PartnerVehicleRegistration from './PartnerVehicleRegistration'

type Props = { supabase: SupabaseClient; applicationId: string; userId: string; companyName?: string | null; documentReady: boolean; documentVersion?: string | null; documentForm: ReactNode; documentBusy: boolean; onError: (message: string) => void; onNotice: (message: string) => void }
export default function PartnerOnboarding({ supabase, applicationId, userId, companyName, documentReady, documentVersion = 'saved', documentForm, documentBusy, onError, onNotice }: Props) {
  const [selectedStep, setSelectedStep] = useState<number | null>(null)
  const [count, setCount] = useState(0)
  const [vehicleBusy, setVehicleBusy] = useState(false)
  const [draft, setDraft] = useState(false)
  const [editingDocumentVersion, setEditingDocumentVersion] = useState<string | null>(null)
  const editingDocuments = !documentReady || editingDocumentVersion === documentVersion
  const root = useRef<HTMLElement>(null)
  const step = selectedStep ?? (documentReady ? 1 : 0)
  const busy = documentBusy || vehicleBusy
  function go(next: number) {
    if (busy || (next > 0 && !documentReady) || (next === 2 && (!count || draft))) return
    setSelectedStep(next)
    window.requestAnimationFrame(() => root.current?.querySelector<HTMLElement>(`[data-slide="${next}"] h2`)?.focus())
  }
  return <section className="partner-onboarding" ref={root} aria-label="Partner signup steps">
    <nav className="partner-step-nav" aria-label="Registration progress">{['Documents', 'Vehicles', 'Review'].map((label, index) => {
      const done = index === 0 ? documentReady : index === 1 ? count > 0 && !draft : step === 2
      return <div className={`partner-step-item${done ? ' is-done' : ''}`} key={label}><button type="button" aria-current={step === index ? 'step' : undefined} disabled={busy || (index > 0 && !documentReady) || (index === 2 && (!count || draft))} onClick={() => go(index)}><span>{index + 1}</span>{label}{done && <small>Done</small>}</button>{done && index < 2 && <button className="text-button step-edit" type="button" disabled={busy} aria-label={`Edit ${label.toLowerCase()}`} onClick={() => { if (index === 0) setEditingDocumentVersion(documentVersion); go(index) }}>Edit</button>}</div>
    })}</nav>
    <div className="partner-slide-viewport">
      <div className="partner-slide" data-slide="0" data-active={step === 0} inert={step !== 0} aria-hidden={step !== 0} style={{ transform: `translateX(${(0 - step) * 105}%)` }}>
        <h2 tabIndex={-1}>Business documents</h2>
        {!editingDocuments && <div className="completed-step"><strong>Done - business document saved</strong><button className="text-button" type="button" disabled={busy} onClick={() => setEditingDocumentVersion(documentVersion)}>Edit document</button></div>}
        <div hidden={!editingDocuments}>{documentForm}</div>
        <div className="partner-step-actions"><button className="primary-button" type="button" disabled={!documentReady || busy} onClick={() => go(1)}>Next: vehicles</button></div>
      </div>
      <div className="partner-slide" data-slide="1" data-active={step === 1} inert={step !== 1} aria-hidden={step !== 1} style={{ transform: `translateX(${(1 - step) * 105}%)` }}>
        <h2 tabIndex={-1}>Your vehicles</h2>
        {documentReady && <PartnerVehicleRegistration supabase={supabase} applicationId={applicationId} userId={userId} companyName={companyName} onError={onError} onNotice={onNotice} onCountChange={setCount} onBusyChange={setVehicleBusy} onDraftChange={setDraft} />}
        {draft && count > 0 && <p className="section-intro">Save this vehicle before continuing.</p>}
        <div className="partner-step-actions"><button className="secondary-button" type="button" disabled={busy} onClick={() => go(0)}>Back</button><button className="primary-button" type="button" disabled={busy || !count || draft} onClick={() => go(2)}>Next: review</button></div>
      </div>
      <div className="partner-slide" data-slide="2" data-active={step === 2} inert={step !== 2} aria-hidden={step !== 2} style={{ transform: `translateX(${(2 - step) * 105}%)` }}>
        <h2 tabIndex={-1}>Ready for review</h2><p>{companyName || 'Your company'}</p><p>Business document saved.</p><p>{count} {count === 1 ? 'vehicle' : 'vehicles'} registered.</p><p className="section-intro">Your documents and vehicles are awaiting Super Admin approval.</p>
        <button className="secondary-button" type="button" disabled={busy} onClick={() => go(1)}>Back to vehicles</button>
      </div>
    </div>
  </section>
}
