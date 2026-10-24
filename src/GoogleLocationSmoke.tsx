import { useEffect, useState } from 'react'
import GoogleMapCanvas from './GoogleMapCanvas'
import { googleReverse, googleSearch } from './lib/google-geocoding'

export default function GoogleLocationSmoke() {
  const [point, setPoint] = useState({ latitude: 4.882269, longitude: 7.0096482 })
  const [message, setMessage] = useState('')
  const [query, setQuery] = useState('Divine Benevolent Care Organisation')
  useEffect(() => { void googleSearch('Divine Benevolent Care Organisation').then((result) => setMessage(`Found: ${result.address} · ${result.latitude}, ${result.longitude}`)).catch((error) => setMessage(String(error))) }, [])
  return <main style={{ maxWidth: 700, margin: '2rem auto', padding: 16 }}>
    <h1>Google location test</h1>
    <p>Search a place or move the map pin. This test uses a demo key and does not save an address.</p>
    <label>Place name <input value={query} onChange={(event) => setQuery(event.target.value)} /></label>
    <button type="button" onClick={() => void googleSearch(query).then((result) => { setPoint(result); setMessage(`${result.address} · ${result.latitude}, ${result.longitude}`) }).catch((error) => setMessage(String(error)))}>Search</button>
    <button type="button" onClick={() => void googleReverse({ ...point, accuracyMetres: null, capturedAt: Date.now(), source: 'map' }).then((result) => setMessage(`${result.address} · match is ${result.distanceMetres} m from the pin`)).catch((error) => setMessage(String(error)))}>Check pin</button>
    <p role="status" id="google-location-result">{message}</p>
    <GoogleMapCanvas point={point} zoom={18} onChoose={setPoint} />
  </main>
}
