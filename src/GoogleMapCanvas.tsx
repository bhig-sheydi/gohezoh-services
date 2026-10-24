import { useEffect, useRef, useState } from 'react'
import { googlePoint, loadGoogleMaps, type GoogleMapsApi } from './lib/google-maps'

type Point = { latitude: number; longitude: number }
export default function GoogleMapCanvas({ point, zoom, onChoose }: { point: Point; zoom: number; onChoose: (point: Point) => void }) {
  const element = useRef<HTMLDivElement>(null)
  const instance = useRef<InstanceType<GoogleMapsApi['Map']> | null>(null)
  const marker = useRef<InstanceType<GoogleMapsApi['Marker']> | null>(null)
  const latest = useRef(onChoose)
  const [error, setError] = useState('')
  useEffect(() => { latest.current = onChoose }, [onChoose])
  useEffect(() => {
    let active = true
    void loadGoogleMaps().then((google) => {
      if (!active || !element.current) return
      const map = new google.Map(element.current, { center: googlePoint(point), zoom, mapTypeControl: false, streetViewControl: false })
      const pin = new google.Marker({ position: googlePoint(point), map })
      instance.current = map; marker.current = pin
      map.addListener('click', (event) => {
        if (event?.latLng) latest.current({ latitude: event.latLng.lat(), longitude: event.latLng.lng() })
      })
      map.addListener('dragend', () => {
        const center = map.getCenter()
        if (center) latest.current({ latitude: center.lat(), longitude: center.lng() })
      })
    }).catch((cause) => { if (active) setError(cause instanceof Error ? cause.message : 'Google Maps could not load.') })
    return () => { active = false; marker.current?.setMap(null); marker.current = null; instance.current = null }
    // The map is created once; subsequent point/zoom changes are synchronized below.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])
  useEffect(() => { instance.current?.setCenter(googlePoint(point)); marker.current?.setPosition(googlePoint(point)) }, [point])
  useEffect(() => { instance.current?.setZoom(zoom) }, [zoom])
  return <><div ref={element} className="pin-map-image google-pin-map" role="region" aria-label="Tap or drag Google map to choose a point" />{error && <small role="alert">{error}</small>}</>
}
