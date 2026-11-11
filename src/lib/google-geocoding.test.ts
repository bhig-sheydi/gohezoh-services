import { beforeEach, describe, expect, it, vi } from 'vitest'
import { googleAutocomplete, googleClosestLandmark, googleNearby, googleReverse, googleSearch, googleSuggest, newGoogleAutocompleteSession } from './google-geocoding'
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
  it('uses one autocomplete session and resolves a Nigerian landmark with Essentials-only details', async () => {
    const fetchFields = vi.fn(async () => {})
    const selectedPlace = { location: location(4.8821755, 7.0098946), formattedAddress: 'Orji Woko Close, Eliozu, Port Harcourt, Nigeria',
      addressComponents: [{ longText: 'Port Harcourt', types: ['locality'] }, { longText: 'Rivers', types: ['administrative_area_level_1'] }],
      types: ['establishment'], fetchFields }
    const fetchAutocompleteSuggestions = vi.fn(async (_request: Record<string, unknown>) => ({ suggestions: [{ placePrediction: {
      placeId: 'divine-benevolent-care', mainText: { text: 'Divine Benevolent Care Organisation' },
      secondaryText: { text: 'Eliozu, Port Harcourt, Nigeria' }, text: { text: 'Divine Benevolent Care Organisation, Eliozu' },
      toPlace: () => selectedPlace,
    } }] }))
    vi.mocked(loadGoogleMaps).mockResolvedValue({ importLibrary: async () => ({
      AutocompleteSessionToken: class {}, AutocompleteSuggestion: { fetchAutocompleteSuggestions },
    }) } as never)
    const session = newGoogleAutocompleteSession()
    const first = await googleAutocomplete('Divine Benevolent, Port Harcourt, Nigeria', session)
    await googleAutocomplete('Divine Benevolent Care, Port Harcourt, Nigeria', session)
    expect(fetchAutocompleteSuggestions).toHaveBeenCalledTimes(2)
    expect(fetchAutocompleteSuggestions.mock.calls[0][0]).toMatchObject({ includedRegionCodes: ['ng'], region: 'ng' })
    expect(fetchAutocompleteSuggestions.mock.calls[0][0].sessionToken).toBe(fetchAutocompleteSuggestions.mock.calls[1][0].sessionToken)
    expect(first[0]).toMatchObject({ address: 'Divine Benevolent Care Organisation', detail: 'Eliozu, Port Harcourt, Nigeria' })
    const result = await first[0].select()
    expect(fetchFields).toHaveBeenCalledWith({ fields: ['formattedAddress', 'location', 'addressComponents', 'types'] })
    expect(result).toMatchObject({ address: 'Divine Benevolent Care Organisation', city: 'Port Harcourt', state: 'Rivers',
      evidence: { latitude: 4.8821755, longitude: 7.0098946, source: 'search' } })
    expect(searchByText).not.toHaveBeenCalled()
  })
  it('reads location fields from a Google Place instance after fetching details', async () => {
    class GooglePlaceInstance {
      get location() { return location(4.8821755, 7.0098946) }
      get formattedAddress() { return 'Orji Woko Close, Port Harcourt, Nigeria' }
      get addressComponents() { return [{ longText: 'Port Harcourt', types: ['locality'] }, { longText: 'Rivers', types: ['administrative_area_level_1'] }] }
      get types() { return ['street_address'] }
      async fetchFields() { return undefined }
    }
    vi.mocked(loadGoogleMaps).mockResolvedValue({ importLibrary: async () => ({
      AutocompleteSessionToken: class {}, AutocompleteSuggestion: { fetchAutocompleteSuggestions: async () => ({ suggestions: [{ placePrediction: {
        placeId: 'orji-woko', mainText: { text: 'Orji Woko Close' }, text: { text: 'Orji Woko Close' },
        toPlace: () => new GooglePlaceInstance(),
      } }] }) },
    }) } as never)
    const [option] = await googleAutocomplete('Orji Woko Close', newGoogleAutocompleteSession())
    const result = await option.select()
    expect(result).toMatchObject({ address: 'Orji Woko Close', city: 'Port Harcourt',
      evidence: { latitude: 4.8821755, longitude: 7.0098946 } })
  })
  it('does not return stale autocomplete results after the caller aborts', async () => {
    let finish!: (value: unknown) => void
    const fetchAutocompleteSuggestions = vi.fn(() => new Promise((resolve) => { finish = resolve }))
    vi.mocked(loadGoogleMaps).mockResolvedValue({ importLibrary: async () => ({
      AutocompleteSessionToken: class {}, AutocompleteSuggestion: { fetchAutocompleteSuggestions },
    }) } as never)
    const controller = new AbortController()
    const pending = googleAutocomplete('Eliozu, Port Harcourt, Nigeria', newGoogleAutocompleteSession(), controller.signal)
    await vi.waitFor(() => expect(fetchAutocompleteSuggestions).toHaveBeenCalledTimes(1))
    controller.abort()
    finish({ suggestions: [] })
    await expect(pending).rejects.toMatchObject({ name: 'AbortError' })
  })
  it('rejects coordinates outside the globe when resolving a prediction', async () => {
    const fetchAutocompleteSuggestions = vi.fn(async () => ({ suggestions: [{ placePrediction: {
      placeId: 'bad-place', mainText: { text: 'Bad place' }, text: { text: 'Bad place' },
      toPlace: () => ({ location: location(100, 7.01), fetchFields: async () => {} }),
    } }] }))
    vi.mocked(loadGoogleMaps).mockResolvedValue({ importLibrary: async () => ({
      AutocompleteSessionToken: class {}, AutocompleteSuggestion: { fetchAutocompleteSuggestions },
    }) } as never)
    const options = await googleAutocomplete('Bad place', newGoogleAutocompleteSession())
    await expect(options[0].select()).rejects.toThrow('invalid place')
  })
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
  it('shares one in-flight provider call for street and landmark searches, then releases it', async () => {
    const point = { latitude: 4.882269, longitude: 7.0096482 }
    let finish!: (value: unknown) => void
    searchByText.mockImplementationOnce(() => new Promise((resolve) => { finish = resolve }))
      .mockResolvedValue({ places: [] })
    const landmark = googleNearby('Orji Woko', point, 'amenity')
    const street = googleNearby('Orji Woko', point, 'street')
    await vi.waitFor(() => expect(searchByText).toHaveBeenCalledTimes(1))
    finish({ places: [{ displayName: 'Orji Woko Close', location: location(4.882269, 7.0096482),
      primaryType: 'route', addressComponents: [{ longText: 'Orji Woko Close', types: ['route'] }] }] })
    expect(await landmark).toHaveLength(1)
    expect(await street).toHaveLength(1)
    await googleNearby('Orji Woko', point, 'street')
    expect(searchByText).toHaveBeenCalledTimes(2)
  })
})
