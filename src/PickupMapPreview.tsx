import { useEffect, useRef, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { mapTile } from './lib/geoapify-geocoding'

const zoom = 16
const tileSize = 256

function Tile({ supabase, x, y, left, top }: { supabase: SupabaseClient; x: number; y: number; left: number; top: number }) {
  const [url, setUrl] = useState('')
  useEffect(() => {
    const controller = new AbortController()
    let objectUrl = ''
    void mapTile(supabase, zoom, x, y, controller.signal).then((blob) => {
      if (controller.signal.aborted) return
      objectUrl = URL.createObjectURL(blob)
      setUrl(objectUrl)
    }).catch(() => {})
    return () => { controller.abort(); if (objectUrl) URL.revokeObjectURL(objectUrl) }
  }, [supabase, x, y])
  return url ? <img className="pin-map-tile" src={url} alt="" draggable={false} style={{ left, top }} /> : null
}

export default function PickupMapPreview({ supabase, latitude, longitude, label }: {
  supabase: SupabaseClient; latitude: number; longitude: number; label: string
}) {
  const map = useRef<HTMLDivElement>(null)
  const [width, setWidth] = useState(320)
  useEffect(() => {
    const element = map.current
    if (!element) return
    const measure = () => setWidth(element.clientWidth || 320)
    measure()
    if (typeof ResizeObserver === 'undefined') return
    const observer = new ResizeObserver(measure)
    observer.observe(element)
    return () => observer.disconnect()
  }, [])
  const size = tileSize * 2 ** zoom
  const radians = Math.max(-85, Math.min(85, latitude)) * Math.PI / 180
  const centerX = (longitude + 180) / 360 * size
  const centerY = (1 - Math.log(Math.tan(radians) + 1 / Math.cos(radians)) / Math.PI) / 2 * size
  const tiles = []
  for (let x = Math.floor((centerX - width / 2) / tileSize); x <= Math.floor((centerX + width / 2) / tileSize); x++) {
    for (let y = Math.floor((centerY - 110) / tileSize); y <= Math.floor((centerY + 110) / tileSize); y++) {
      if (x >= 0 && y >= 0 && x < 2 ** zoom && y < 2 ** zoom) tiles.push({ x, y, left: x * tileSize - centerX + width / 2, top: y * tileSize - centerY + 110 })
    }
  }
  return <figure className="pickup-map-preview" aria-label="Selected pickup street on map">
    <div ref={map} className="pickup-map-viewport">
      {tiles.map((tile) => <Tile key={`${tile.x}-${tile.y}`} supabase={supabase} {...tile} />)}
      <span className="pin-map-marker" aria-hidden="true" />
    </div>
    <figcaption>{label} · approximate street location</figcaption>
    <small>© <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noreferrer">OpenStreetMap contributors</a> · <a href="https://www.geoapify.com/" target="_blank" rel="noreferrer">Geoapify</a></small>
  </figure>
}
