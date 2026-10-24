/** Browser-only Google Maps prototype. A demo key must never be used for live service. */
export const googleMapsDemoEnabled = import.meta.env.DEV && import.meta.env.MODE !== 'test' && Boolean(import.meta.env.VITE_GOOGLE_MAPS_DEMO_KEY)

type Point = { latitude: number; longitude: number }
type LatLng = { lat(): number; lng(): number }
export type GooglePlace = {
  displayName?: string | { text: string }; formattedAddress?: string; location?: LatLng
  addressComponents?: Array<{ longText: string; types: string[] }>
  primaryType?: string; id?: string
}
export type GoogleGeocode = {
  formatted_address: string; geometry: { location: LatLng; location_type?: string }
  address_components: Array<{ long_name: string; types: string[] }>
  place_id?: string; types?: string[]
}
export type GoogleMapsApi = {
  Map: new (element: HTMLElement, options: Record<string, unknown>) => {
    setCenter(point: { lat: number; lng: number }): void; setZoom(zoom: number): void
    addListener(name: string, callback: (event?: { latLng?: LatLng }) => void): void
    getCenter(): LatLng | undefined
  }
  Marker: new (options: Record<string, unknown>) => { setPosition(point: { lat: number; lng: number }): void; setMap(map: null): void }
  Geocoder: new () => { geocode(request: Record<string, unknown>): Promise<{ results: GoogleGeocode[] }> }
  importLibrary(name: string): Promise<{ Place: { searchByText(request: Record<string, unknown>): Promise<{ places: GooglePlace[] }> } }>
}

declare global { interface Window { google?: { maps: GoogleMapsApi } } }
let loading: Promise<GoogleMapsApi> | undefined
export function loadGoogleMaps(): Promise<GoogleMapsApi> {
  if (!googleMapsDemoEnabled) return Promise.reject(new Error('Google Maps demo is not configured.'))
  if (window.google?.maps) return Promise.resolve(window.google.maps)
  if (!loading) loading = new Promise((resolve, reject) => {
    const script = document.createElement('script')
    script.src = `https://maps.googleapis.com/maps/api/js?key=${encodeURIComponent(import.meta.env.VITE_GOOGLE_MAPS_DEMO_KEY)}&v=weekly&libraries=places&loading=async`
    script.async = true
    script.onload = () => window.google?.maps ? resolve(window.google.maps) : reject(new Error('Google Maps did not load.'))
    script.onerror = () => { loading = undefined; reject(new Error('Google Maps could not load.')) }
    document.head.appendChild(script)
  })
  return loading
}

export const googlePoint = (point: Point) => ({ lat: point.latitude, lng: point.longitude })
