import { useCallback, useEffect, useRef, useState, type ChangeEvent, type FormEvent } from 'react'
import { getSupabaseClient } from './lib/supabase'
import DeliveryLocationsEditor from './DeliveryLocationsEditor'

type SearchResult = { found: boolean; code?: string; status?: string; direction?: string | null }
type ParcelPalRequest = { code: string; status: string; direction: 'sent' | 'received'; full_name: string | null; avatar_path: string | null; avatar_url?: string | null; created_at: string }
export type ParcelDestination = { slot: number; label: string; address: string; city: string; state: string; secondary_phone: string | null }
export type ParcelPalContact = { code: string; full_name: string | null; phone: string | null; avatar_path: string | null; avatar_url?: string | null; address: string | null; city: string | null; state: string | null; destinations?: ParcelDestination[]; connected_at: string | null }
type Props = { supabase: ReturnType<typeof getSupabaseClient>; userId: string; onError: (message: string) => void; onNotice: (message: string) => void; onUseDestination?: (contact: ParcelPalContact, destination: ParcelDestination) => void; isEditingDestinations?: boolean; onCloseDestinationEditor?: () => void }

function rows<T>(value: unknown): T[] { return Array.isArray(value) ? value as T[] : [] }

export default function ParcelPalsPanel({ supabase, userId, onError, onNotice, onUseDestination, isEditingDestinations = false, onCloseDestinationEditor }: Props) {
  const [code, setCode] = useState('')
  const [searchCode, setSearchCode] = useState('')
  const [searchResult, setSearchResult] = useState<SearchResult | null>(null)
  const [requests, setRequests] = useState<ParcelPalRequest[]>([])
  const [contacts, setContacts] = useState<ParcelPalContact[]>([])
  const [busy, setBusy] = useState(false)
  const [avatarPath, setAvatarPath] = useState<string | null>(null)
  const [avatarUrl, setAvatarUrl] = useState<string | null>(null)
  const [photoBusy, setPhotoBusy] = useState(false)
  const [showPhotoReminder, setShowPhotoReminder] = useState(false)
  const [avatarFailed, setAvatarFailed] = useState(false)
  const [destinations, setDestinations] = useState<ParcelDestination[]>([])
  const profileLoaded = useRef(false)
  const photoInput = useRef<HTMLInputElement>(null)

  const signedPhotoUrl = useCallback(async (path: string | null) => {
    if (!path) return null
    const { data, error } = await supabase.storage.from('profile-photos').createSignedUrl(path, 3600)
    if (error) { onError(error.message); return null }
    return data?.signedUrl ?? null
  }, [onError, supabase])

  const refresh = useCallback(async () => {
    const [codeResult, requestResult, contactResult, profileResult] = await Promise.all([
      supabase.rpc('get_my_parcel_pal_code'),
      supabase.rpc('list_parcel_pal_requests'),
      supabase.rpc('list_my_parcel_pals'),
      supabase.from('profiles').select('avatar_path').eq('user_id', userId).maybeSingle(),
    ])
    const error = codeResult.error ?? requestResult.error ?? contactResult.error ?? profileResult.error
    if (error) { onError(error.message); return }
    setCode(typeof codeResult.data === 'string' ? codeResult.data : '')
    const profile = profileResult.data as { avatar_path?: string | null } | null
    const nextAvatarPath = profile?.avatar_path ?? null
    setAvatarPath(nextAvatarPath)
    setAvatarFailed(false)
    setAvatarUrl(await signedPhotoUrl(nextAvatarPath))
    if (!profileLoaded.current) {
      setShowPhotoReminder(!nextAvatarPath)
      profileLoaded.current = true
    }
    const requestRows = rows<ParcelPalRequest>(requestResult.data)
    const contactRows = rows<ParcelPalContact>(contactResult.data)
    const [requestsWithPhotos, contactsWithPhotos] = await Promise.all([
      Promise.all(requestRows.map(async (request) => ({ ...request, avatar_url: await signedPhotoUrl(request.avatar_path) }))),
      Promise.all(contactRows.map(async (contact) => ({ ...contact, avatar_url: await signedPhotoUrl(contact.avatar_path) }))),
    ])
    setRequests(requestsWithPhotos)
    setContacts(contactsWithPhotos)
    const locationResult = await supabase.from('customer_parcel_destinations').select('slot,label,address,city,state,secondary_phone').eq('user_id', userId).order('slot')
    if (locationResult.error) onError(locationResult.error.message)
    else setDestinations(rows<ParcelDestination>(locationResult.data))
  }, [onError, signedPhotoUrl, supabase, userId])

  useEffect(() => {
    const timer = window.setTimeout(() => { void refresh() }, 0)
    return () => window.clearTimeout(timer)
  }, [refresh])

  async function search(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!/^\d{6}$/.test(searchCode) || busy) return
    setBusy(true); setSearchResult(null); onError(''); onNotice('')
    const { data, error } = await supabase.rpc('search_parcel_pals', { p_code: searchCode })
    if (error) onError(error.message)
    else setSearchResult(data as SearchResult)
    setBusy(false)
  }

  async function copyMyCode() {
    if (!code) return
    try {
      await navigator.clipboard.writeText(code)
      onNotice('Your Parcel Pal number was copied.')
    } catch {
      onError('Could not copy the number. You can select and copy it manually.')
    }
  }

  async function uploadProfilePhoto(event: ChangeEvent<HTMLInputElement>) {
    const file = event.currentTarget.files?.[0]
    event.currentTarget.value = ''
    if (!file || photoBusy) return
    if (!['image/jpeg','image/png','image/webp'].includes(file.type) || file.size > 5 * 1024 * 1024) {
      onError('Choose a JPEG, PNG or WebP image under 5 MB.')
      return
    }
    const extension = file.type === 'image/jpeg' ? 'jpg' : file.type === 'image/png' ? 'png' : 'webp'
    const nextPath = `${userId}/${Date.now()}.${extension}`
    setPhotoBusy(true); onError(''); onNotice('')
    const bucket = supabase.storage.from('profile-photos')
    const { error: uploadError } = await bucket.upload(nextPath, file, { contentType: file.type, cacheControl: '3600', upsert: false })
    if (uploadError) {
      onError(uploadError.message)
      setPhotoBusy(false)
      return
    }
    const { error: saveError } = await supabase.rpc('set_my_parcel_pal_photo', { p_path: nextPath })
    if (saveError) {
      await bucket.remove([nextPath])
      onError(saveError.message)
      setPhotoBusy(false)
      return
    }
    const nextUrl = await signedPhotoUrl(nextPath)
    setAvatarPath(nextPath); setAvatarUrl(nextUrl); setAvatarFailed(false); setShowPhotoReminder(false)
    if (avatarPath && avatarPath !== nextPath) await bucket.remove([avatarPath])
    onNotice('Profile picture saved.')
    setPhotoBusy(false)
  }

  async function sendRequest() {
    const target = searchResult?.code ?? searchCode
    if (!/^\d{6}$/.test(target) || busy) return
    setBusy(true); onError(''); onNotice('')
    const { data, error } = await supabase.rpc('send_parcel_pal_request', { p_code: target })
    if (error) onError(error.message)
    else {
      const result = data as { status?: string } | null
      if (result?.status === 'pending') onNotice('Parcel Pal request sent. Their details stay private until they accept.')
      else if (result?.status === 'incoming_request') onNotice('They have already requested you. Review their request below.')
      else if (result?.status === 'accepted') onNotice('You are already Parcel Pals.')
      else onNotice('No Parcel Pal was found with that number.')
      await refresh()
      setSearchResult((current) => {
        if (!current) return current
        if (result?.status === 'pending') return { ...current, status: 'pending', direction: 'sent' }
        if (result?.status === 'incoming_request') return { ...current, status: 'pending', direction: 'received' }
        if (result?.status === 'accepted') return { ...current, status: 'accepted', direction: 'connected' }
        if (result?.status === 'not_found') return { found: false }
        return current
      })
    }
    setBusy(false)
  }

  async function respond(request: ParcelPalRequest, accept: boolean) {
    if (busy) return
    setBusy(true); onError(''); onNotice('')
    const { error } = await supabase.rpc('respond_to_parcel_pal_request', { p_code: request.code, p_accept: accept })
    if (error) onError(error.message)
    else {
      onNotice(accept ? 'Parcel Pal request accepted. You can now see each otherâ€™s shared contact details.' : 'Parcel Pal request declined.')
      setSearchResult(null)
      await refresh()
    }
    setBusy(false)
  }

  return <section className="parcel-pals-panel" aria-labelledby="parcel-pals-heading">
    <div className="parcel-pals-heading">
      <div><p className="eyebrow">PARCEL PALS</p><h2 id="parcel-pals-heading">Your number</h2><p>Share it to connect with someone.</p></div>
      <div className="parcel-pal-own-code">
        <button type="button" className="parcel-pal-avatar parcel-pal-avatar-own" aria-label={avatarUrl && !avatarFailed ? 'Change profile picture' : 'Add profile picture'} title="Change profile picture" onClick={() => photoInput.current?.click()}>
          {avatarUrl && !avatarFailed ? <img src={avatarUrl} alt="Your profile picture" onError={() => setAvatarFailed(true)} /> : <span aria-hidden="true">{avatarPath ? '!' : '+'}</span>}
        </button>
        <input ref={photoInput} className="visually-hidden" type="file" accept="image/jpeg,image/png,image/webp" aria-label="Choose a profile picture" onChange={(event) => void uploadProfilePhoto(event)} />
        <span>YOUR PARCEL PAL NUMBER</span><strong aria-label="Your Parcel Pal number">{code || '------'}</strong><button type="button" className="secondary-button" disabled={!code} onClick={() => void copyMyCode()}>Copy number</button><small className="parcel-pal-photo-state" aria-live="polite">{avatarUrl && !avatarFailed ? 'Profile picture set Â· tap to change' : avatarPath ? 'Picture unavailable Â· tap to replace' : 'Add a profile picture'}</small>
      </div>
    </div>
    {showPhotoReminder && <div className="parcel-pal-photo-reminder" role="dialog" aria-modal="true" aria-labelledby="parcel-pal-photo-title"><div className="parcel-pal-photo-prompt"><span className="parcel-pal-photo-prompt-icon" aria-hidden="true">+</span><h3 id="parcel-pal-photo-title">Add a profile picture</h3><p>Use your business logo or a clear photo of your face.</p><button type="button" className="primary-button" disabled={photoBusy} onClick={() => photoInput.current?.click()}>{photoBusy ? 'Saving...' : 'Choose picture'}</button><button type="button" className="text-button" onClick={() => setShowPhotoReminder(false)}>Don't remind me again</button></div></div>}
    <button className="text-button parcel-pal-refresh" type="button" aria-label="Refresh Parcel Pals" onClick={() => void refresh()}>Refresh</button>
    <p className="parcel-pal-privacy"><span aria-hidden="true">â—†</span> Contact details appear after acceptance.</p>
    {isEditingDestinations && <DeliveryLocationsEditor key={userId} supabase={supabase} userId={userId} destinations={destinations} onSaved={refresh} onClose={onCloseDestinationEditor} onError={onError} onNotice={onNotice} />}
    <form className="parcel-pal-search" onSubmit={search}>
      <label className="field"><span>Find a Parcel Pal</span><input aria-label="Search by Parcel Pal number" type="text" inputMode="numeric" autoComplete="off" maxLength={6} pattern="[0-9]{6}" value={searchCode} onChange={(event) => { setSearchCode(event.target.value.replace(/\D/g, '').slice(0, 6)); setSearchResult(null) }} placeholder="6-digit number" /></label>
      <button className="secondary-button" disabled={busy || searchCode.length !== 6}>{busy ? 'Searching...' : 'Search'}</button>
    </form>
    {searchResult && <div className="parcel-pal-search-result" aria-live="polite">
      {!searchResult.found ? <p>No Parcel Pal was found with that number.</p> : <>
        <strong>Parcel Pal number {searchResult.code} found</strong>
        {searchResult.status === 'none' && <button className="primary-button" disabled={busy} onClick={() => void sendRequest()}>Send Parcel Pal request</button>}
        {searchResult.status === 'pending' && <p>{searchResult.direction === 'sent' ? 'Request sent. Waiting for them to accept.' : 'They have already sent you a request. Review it below.'}</p>}
        {searchResult.status === 'accepted' && <p>You are already Parcel Pals. Their shared details are below.</p>}
        {['declined','cancelled'].includes(searchResult.status ?? '') && <button className="primary-button" disabled={busy} onClick={() => void sendRequest()}>Send a new request</button>}
      </>}
    </div>}
    <div className="parcel-pal-lists">
      <section aria-labelledby="parcel-pal-requests-heading"><div className="history-heading"><div><h3 id="parcel-pal-requests-heading">Requests</h3></div><span className="request-count">{requests.length}</span></div>
        {requests.length === 0 ? <p className="parcel-pal-empty">No pending requests.</p> : <div className="parcel-pal-request-list">{requests.map((request) => <article className="parcel-pal-request" key={`${request.code}-${request.direction}`}><div className="parcel-pal-request-person"><span className="parcel-pal-avatar parcel-pal-avatar-small">{request.avatar_url ? <img src={request.avatar_url} alt="" /> : <span aria-hidden="true">{(request.full_name || 'P').trim().slice(0,1).toUpperCase()}</span>}</span><div><strong>{request.direction === 'received' ? request.full_name || `Parcel Pal ${request.code}` : `Parcel Pal ${request.code}`}</strong><small>{request.direction === 'received' ? 'Wants to connect' : 'Waiting for acceptance'}</small></div></div>{request.direction === 'received' ? <div className="parcel-pal-actions"><button className="secondary-button" disabled={busy} onClick={() => void respond(request, false)}>Decline</button><button className="primary-button" disabled={busy} onClick={() => void respond(request, true)}>Accept</button></div> : <span className="finance-status">Pending</span>}</article>)}</div>}
      </section>
      <section aria-labelledby="parcel-pal-connected-heading"><div className="history-heading"><div><h3 id="parcel-pal-connected-heading">Connected</h3></div><span className="request-count">{contacts.length}</span></div>
        {contacts.length === 0 ? <p className="parcel-pal-empty">Accepted connections will appear here.</p> : <div className="parcel-pal-contact-list">{contacts.map((contact) => <article className="parcel-pal-contact" key={contact.code}><div className="parcel-pal-contact-heading"><span className="parcel-pal-avatar parcel-pal-avatar-small">{contact.avatar_url ? <img src={contact.avatar_url} alt="" /> : <span aria-hidden="true">{(contact.full_name || 'P').trim().slice(0,1).toUpperCase()}</span>}</span><div className="request-item-top"><strong>{contact.full_name || `Parcel Pal ${contact.code}`}</strong><span className="finance-status finance-status-paid">Connected</span></div></div><p>Number {contact.code}</p>{contact.phone && <p>Phone: <a href={`tel:${contact.phone}`}>{contact.phone}</a></p>}{contact.destinations?.length ? <div className="parcel-pal-contact-destinations"><strong>Preferred delivery locations</strong>{contact.destinations.map((destination) => <div className="parcel-pal-contact-destination" key={destination.slot}><span><b>{destination.label}</b><br />{[destination.address,destination.city,destination.state].join(', ')}{destination.secondary_phone && <><br />Second phone: {destination.secondary_phone}</>}</span><button className="secondary-button" type="button" onClick={() => onUseDestination?.(contact,destination)}>Use this destination</button></div>)}</div> : contact.address || contact.city || contact.state ? <p>Address: {[contact.address,contact.city,contact.state].filter(Boolean).join(', ')}</p> : <small>No saved delivery locations are available.</small>}</article>)}</div>}
      </section>
    </div>
  </section>
}
