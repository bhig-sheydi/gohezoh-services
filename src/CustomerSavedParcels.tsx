import { useCallback, useEffect, useRef, useState, type ChangeEvent, type FormEvent } from 'react'
import type { getSupabaseClient } from './lib/supabase'
import BikeItemPicker, { type BikeItem } from './BikeItemPicker'
import { bikeItemEstimate, MAX_GOODS_VALUE_NGN } from './lib/bike-item-space'

export type SavedParcel = {
  id: string
  user_id: string
  item_name: string
  description: string
  declared_value: number
  price: number
  length_cm: number
  width_cm: number
  height_cm: number
  weight_kg: number
  catalog_code?: string | null
  pages?: number | null
  photo_path: string
  photo_url?: string
  created_at: string
}

type Props = {
  supabase: ReturnType<typeof getSupabaseClient>
  userId: string
  onError: (message: string) => void
  onNotice: (message: string) => void
  onUse: (parcel: SavedParcel) => void
}

const selectFields = 'id,user_id,item_name,description,declared_value,price,length_cm,width_cm,height_cm,weight_kg,catalog_code,pages,photo_path,created_at'

export default function CustomerSavedParcels({ supabase, userId, onError, onNotice, onUse }: Props) {
  const [items, setItems] = useState<SavedParcel[]>([])
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const fileInput = useRef<HTMLInputElement>(null)
  const [photo, setPhoto] = useState<File | null>(null)
  const [photoPreview, setPhotoPreview] = useState('')
  const [selectedType, setSelectedType] = useState<BikeItem | null>(null)

  const refresh = useCallback(async () => {
    const { data, error } = await supabase.from('customer_saved_parcels').select(selectFields).eq('user_id', userId).order('created_at', { ascending: false })
    if (error) { onError(error.message); setLoading(false); return }
    const rows = (data ?? []) as unknown as SavedParcel[]
    const signed = await Promise.all(rows.map(async (item) => {
      const { data: urlData, error: urlError } = await supabase.storage.from('customer-saved-parcels').createSignedUrl(item.photo_path, 3600)
      if (urlError) onError(urlError.message)
      return { ...item, photo_url: urlData?.signedUrl ?? '' }
    }))
    setItems(signed)
    setLoading(false)
  }, [onError, supabase, userId])

  useEffect(() => {
    const timer = window.setTimeout(() => { void refresh() }, 0)
    return () => window.clearTimeout(timer)
  }, [refresh])
  useEffect(() => () => { if (photoPreview) URL.revokeObjectURL(photoPreview) }, [photoPreview])

  function choosePhoto(event: ChangeEvent<HTMLInputElement>) {
    const next = event.currentTarget.files?.[0] ?? null
    event.currentTarget.value = ''
    if (!next) return
    if (!['image/jpeg','image/png','image/webp'].includes(next.type) || next.size > 5 * 1024 * 1024) {
      onError('Choose a JPEG, PNG or WebP photo under 5 MB.')
      return
    }
    if (photoPreview) URL.revokeObjectURL(photoPreview)
    setPhoto(next)
    setPhotoPreview(URL.createObjectURL(next))
  }

  async function saveItem(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const formElement = event.currentTarget
    const form = new FormData(event.currentTarget)
    if (!photo) { onError('Add a parcel photo to save this item.'); return }
    const pages = Number(form.get('parcel_pages') || 1)
    if (!selectedType || !bikeItemEstimate(selectedType, 1, pages).fits) { onError('Choose an item that fits a bike box.'); return }
    const declaredValue = Number(form.get('declared_value'))
    if (!Number.isFinite(declaredValue) || declaredValue < 0 || declaredValue > MAX_GOODS_VALUE_NGN) {
      onError('Declared worth must be ₦70,000 or less.'); return
    }
    const extension = photo.type === 'image/jpeg' ? 'jpg' : photo.type === 'image/png' ? 'png' : 'webp'
    const path = `${userId}/${Date.now()}.${extension}`
    setSaving(true); onError(''); onNotice('')
    const bucket = supabase.storage.from('customer-saved-parcels')
    const { error: uploadError } = await bucket.upload(path, photo, { contentType: photo.type, cacheControl: '3600', upsert: false })
    if (uploadError) { onError(uploadError.message); setSaving(false); return }
    const { error } = await supabase.from('customer_saved_parcels').insert({
      user_id: userId,
      item_name: String(form.get('item_name')).trim(),
      description: String(form.get('description')).trim(),
      declared_value: declaredValue,
      price: Number(form.get('price')),
      catalog_code: selectedType.code,
      pages: selectedType.measurement === 'pages' ? pages : null,
      length_cm: selectedType.length_cm,
      width_cm: selectedType.width_cm,
      height_cm: bikeItemEstimate(selectedType, 1, pages).height,
      weight_kg: bikeItemEstimate(selectedType, 1, pages).weight,
      photo_path: path,
    })
    if (error) {
      await bucket.remove([path])
      onError(error.message)
      setSaving(false)
      return
    }
    formElement.reset()
    setSelectedType(null)
    setPhoto(null); setPhotoPreview('')
    onNotice('Saved item added.')
    setSaving(false)
    await refresh()
  }

  async function removeItem(item: SavedParcel) {
    const { error } = await supabase.from('customer_saved_parcels').delete().eq('id', item.id).eq('user_id', userId)
    if (error) { onError(error.message); return }
    const [requestUse, otherSavedUse] = await Promise.all([
      supabase.from('service_requests').select('id').eq('parcel_photo_path', item.photo_path).limit(1),
      supabase.from('customer_saved_parcels').select('id').eq('photo_path', item.photo_path).limit(1),
    ])
    if (!requestUse.error && !otherSavedUse.error && !requestUse.data?.length && !otherSavedUse.data?.length) {
      const { error: photoError } = await supabase.storage.from('customer-saved-parcels').remove([item.photo_path])
      if (photoError) onError(photoError.message)
    }
    setItems((current) => current.filter((saved) => saved.id !== item.id))
    onNotice('Saved item removed.')
  }

  return <section className="saved-parcels-panel" aria-labelledby="saved-parcels-heading">
    <div className="saved-parcels-heading"><div><p className="eyebrow">REUSE YOUR PARCEL DETAILS</p><h2 id="saved-parcels-heading">Items to send</h2></div><span className="request-count">{items.length}</span></div>
    <details className="saved-parcel-add"><summary>Add items to send</summary><form className="form-grid" onSubmit={(event) => void saveItem(event)}>
      <label className="saved-parcel-photo"><input ref={fileInput} aria-label="Parcel photo" type="file" accept="image/jpeg,image/png,image/webp" onChange={choosePhoto} /><span>{photoPreview ? <img src={photoPreview} alt="Parcel preview" /> : <span aria-hidden="true">＋</span>}</span><small>{photo ? photo.name : 'Add parcel photo'}</small></label>
      <label className="field"><span>Item name</span><input name="item_name" required maxLength={100} placeholder="e.g. Phone accessories" /></label>
      <label className="field"><span>Parcel description</span><input name="description" required maxLength={500} placeholder="Describe what is inside" /></label>
      <div className="field-row"><label className="field"><span>Declared worth (₦)</span><input name="declared_value" type="number" min="0" max="70000" step="0.01" required /></label><label className="field"><span>Price paid (₦)</span><input name="price" type="number" min="0" step="0.01" required /></label></div>
      <BikeItemPicker supabase={supabase} onSelected={setSelectedType} />
      <button className="primary-button" disabled={saving}>{saving ? 'Saving item…' : 'Save item'}</button>
    </form></details>
    {loading ? <p className="saved-parcel-empty">Loading saved items…</p> : items.length === 0 ? <p className="saved-parcel-empty">Save a parcel once to add it faster next time.</p> : <div className="saved-parcel-list">{items.map((item) => <article className="saved-parcel-card" key={item.id}><img src={item.photo_url} alt={item.item_name} /><div className="saved-parcel-copy"><strong>{item.item_name}</strong><span>{item.length_cm} × {item.width_cm} × {item.height_cm} cm estimated packed size</span><small>Declared worth ₦{Number(item.declared_value).toLocaleString('en-NG')}</small></div><button className="primary-button" type="button" onClick={() => onUse(item)}>Use item</button><button className="text-button" type="button" aria-label={`Remove ${item.item_name}`} onClick={() => void removeItem(item)}>Remove</button></article>)}</div>}
  </section>
}
