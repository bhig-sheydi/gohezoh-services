import { beforeEach, describe, expect, it, vi } from 'vitest'
import { googleClosestLandmark, googleReverse, googleSearch, googleSuggest } from './google-geocoding'
import { loadGoogleMaps } from './google-maps'

vi.mock('./google-maps', () => ({ loadGoogleMaps: vi.fn(), googlePoint: (point: { latitude: number; longitude: number }) => ({ lat: point.latitude, lng: point.longitude }) }))
const location = (latitude: number, longitude: number) => ({ lat: () => latitude, lng: () => longitude })
const searchByText = vi.fn()
const fetchGeocode = vi.fn()
beforeEach(() => {
  searchByText.mockReset(); fetchGeocode.mockReset(); vi.stubGlobal('fetch', fetchGeocode)
  vi.mocked(loadGoogleMaps).mockResolvedValue({ importLibrary: async () => ({ Place: { searchByText } }) } as never)
})
describe('Google demo address adapter', () => {
  it('finds a named business and keeps its actual location', async () => {
    searchByText.mockResolvedValue({ places: [{ displayName: 'Divine Benevolent Care Organisation', formattedAddress: 'Orji Woko Street, Port Harcourt, Nigeria',
      location: location(4.8821755, 7.0098946), primaryType: 'orphanage', id: 'google-place', addressComponents: [
        { longText: 'Port Harcourt', types: ['locality'] }, { longText: 'Rivers', types: ['administrative_area_level_1'] },
      ] }] })
    const result = await googleSearch('Divine Benevolent Care Organisation')
    expect(result.address).toBe('Divine Benevolent Care Organisation')
    expect(result.city).toBe('Port Harcourt')
    expect(result.evidence).toMatchObject({ latitude: 4.8821755, longitude: 7.0098946, source: 'search' })
  })
  it('keeps device coordinates when reverse geocoding returns a different building', async () => {
    fetchGeocode.mockResolvedValue({ ok: true, json: async () => ({ results: [{ formattedAddress: '2 Waga Ave', location: { latitude: 4.8812117, longitude: 7.0088121 }, granularity: 'ROOFTOP', addressComponents: [] }] }) })
    const result = await googleReverse({ latitude: 4.882269, longitude: 7.0096482, accuracyMetres: 15, capturedAt: Date.now(), source: 'browser' })
    expect(result.evidence).toMatchObject({ latitude: 4.882269, longitude: 7.0096482 })
    expect(result.distanceMetres).toBeGreaterThan(100)
    expect(fetchGeocode).toHaveBeenCalledWith('https://geocode.googleapis.com/v4/geocode/location/4.882269,7.0096482', expect.anything())
  })
  it('offers Eliozu using its mapped road as an approximate community anchor', async () => {
    searchByText.mockResolvedValueOnce({ places: [{ displayName: 'Eliozu Guest House', location: location(4.8633, 7.0212), primaryType: 'guest_house' }] })
      .mockResolvedValueOnce({ places: [{ displayName: 'Eliozu Road', location: location(4.8661, 7.0219), primaryType: null,
        addressComponents: [{ longText: 'Eliozu Road', types: ['route'] }, { longText: 'Port Harcourt', types: ['locality'] }, { longText: 'Rivers', types: ['administrative_area_level_1'] }] }] })
    const results = await googleSuggest('Eliozu', 'locality')
    expect(results[0]).toMatchObject({ address: 'Eliozu', latitude: 4.8661, longitude: 7.0219, resultType: 'suburb', specificity: 'area' })
    expect(searchByText).toHaveBeenCalledTimes(2)
  })
  it('finds the nearest named place to the supplied phone point', async () => {
    fetchGeocode.mockResolvedValue({ ok: true, json: async () => ({ places: [
      { displayName: { text: 'DIVINE BENEVOLENT CARE ORGANISATION' }, formattedAddress: 'No 18 Orji Woko Street, Port Harcourt', location: { latitude: 4.8821755, longitude: 7.0098946 } },
      { displayName: { text: 'Another shop' }, location: { latitude: 4.881163, longitude: 7.009708 } },
    ] }) })
    const landmark = await googleClosestLandmark({ latitude: 4.882269, longitude: 7.0096482 })
    expect(landmark).toMatchObject({ name: 'DIVINE BENEVOLENT CARE ORGANISATION', distanceMetres: 29 })
    expect(fetchGeocode).toHaveBeenCalledWith('https://places.googleapis.com/v1/places:searchNearby', expect.objectContaining({ method: 'POST' }))
  })
})
