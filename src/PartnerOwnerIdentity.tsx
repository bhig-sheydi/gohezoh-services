import { useEffect, useRef, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'

export default function PartnerOwnerIdentity({ supabase, applicationId, userId, ready, onSaved, onError }: {
  supabase: SupabaseClient; applicationId: string; userId: string; ready: boolean;
  onSaved: () => Promise<void>; onError: (message: string) => void
}) {
  const video = useRef<HTMLVideoElement>(null)
  const stream = useRef<MediaStream | null>(null)
  const [nin, setNin] = useState('')
  const [photo, setPhoto] = useState<Blob | null>(null)
  const [preview, setPreview] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [camera, setCamera] = useState(false)
  useEffect(() => () => { stream.current?.getTracks().forEach((track) => track.stop()) }, [])
  useEffect(() => () => { if (preview) URL.revokeObjectURL(preview) }, [preview])
  useEffect(() => { if (camera && video.current && stream.current) { video.current.srcObject = stream.current; void video.current.play() } }, [camera])

  async function startCamera() {
    onError('')
    if (!navigator.mediaDevices?.getUserMedia) { onError('Camera access is unavailable. Use HTTPS and allow camera permission.'); return }
    try {
      stream.current = await navigator.mediaDevices.getUserMedia({ audio: false, video: { facingMode: 'user' } })
      setCamera(true)
    } catch { onError('Camera permission was denied or the camera is unavailable.') }
  }
  function capture() {
    const frame = video.current
    if (!frame?.videoWidth || !frame.videoHeight) { onError('Wait for the camera image, then try again.'); return }
    const canvas = document.createElement('canvas')
    const scale = Math.min(1, 960 / frame.videoWidth)
    canvas.width = Math.round(frame.videoWidth * scale)
    canvas.height = Math.round(frame.videoHeight * scale)
    canvas.getContext('2d')?.drawImage(frame, 0, 0, canvas.width, canvas.height)
    canvas.toBlob((blob) => {
      if (!blob) { onError('Could not capture the photo.'); return }
      if (preview) URL.revokeObjectURL(preview)
      setPhoto(blob); setPreview(URL.createObjectURL(blob))
      stream.current?.getTracks().forEach((track) => track.stop())
      stream.current = null; setCamera(false)
    }, 'image/jpeg', 0.82)
  }
  async function save() {
    if (!/^[0-9]{11}$/.test(nin)) { onError('Enter the owner NIN as 11 digits.'); return }
    if (!photo || photo.size > 5242880) { onError('Capture an owner face photo under 5 MB.'); return }
    setBusy(true); onError('')
    const path = `${userId}/${applicationId}/${crypto.randomUUID()}.jpg`
    const bucket = supabase.storage.from('partner-verification')
    const uploaded = await bucket.upload(path, photo, { contentType: 'image/jpeg', upsert: false })
    if (uploaded.error) onError(uploaded.error.message)
    else {
      const result = await supabase.rpc('submit_partner_owner_identity', { p_application_id: applicationId, p_nin: nin, p_selfie_path: path })
      if (result.error) { await bucket.remove([path]); onError(result.error.message) }
      else { setNin(''); setPhoto(null); setPreview(null); await onSaved() }
    }
    setBusy(false)
  }
  return <div className="owner-identity"><h3>Company owner identity</h3>
    <p className="section-intro">Only the company owner may take this face photo. Do not take it if you are not the company owner. The NIN and photo are private and reviewed by Super Admin.</p>
    {ready && <p role="status">Owner NIN and face photo submitted. You can replace them before approval.</p>}
    <label className="field"><span>Company owner NIN (11 digits)</span><input inputMode="numeric" pattern="[0-9]{11}" maxLength={11} autoComplete="off" value={nin} onChange={(event) => setNin(event.target.value.replace(/\D/g, '').slice(0, 11))} /></label>
    {camera && <video ref={video} autoPlay playsInline muted aria-label="Live owner camera preview" />}
    {!camera && !photo && <button type="button" className="secondary-button" onClick={() => void startCamera()}>Open camera for live face photo</button>}
    {camera && <button type="button" className="secondary-button" onClick={capture}>Capture face photo</button>}
    {preview && <><img src={preview} alt="Captured owner face for review" className="owner-face-preview" /><button type="button" className="secondary-button" onClick={() => { setPhoto(null); setPreview(null) }}>Retake photo</button></>}
    <button type="button" className="primary-button" disabled={busy || !photo || nin.length !== 11} onClick={() => void save()}>{busy ? 'Saving...' : 'Submit owner identity'}</button>
  </div>
}
