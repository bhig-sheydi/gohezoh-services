// @vitest-environment node
import { describe, expect, it, vi } from 'vitest'
import { createLocationAddressHandler } from './location-address'

const origin = 'https://gohezoh-services.vercel.app'
const reverse = { action: 'reverse', latitude: 5.5296, longitude: 7.4861 }
const record = {
  address_line1: '10 Market Road', city: 'Umuahia', state: 'Abia',
  lat: 5.5297, lon: 7.4862, result_type: 'building', housenumber: '10', street: 'Market Road',
  distance: 16, rank: { confidence: 0.97 },
}
const request = (body: unknown = reverse, headers: Record<string, string> = {}) => new Request('https://example.supabase.co/functions/v1/location-address', {
  method: 'POST', headers: { Origin: origin, Authorization: 'Bearer user-token', 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body),
})
const upstreamResponse = (result: unknown = record) => Response.json({ results: [result] })
const setup = (options: Partial<Parameters<typeof createLocationAddressHandler>[0]> = {}) => {
  const fetcher = vi.fn<typeof fetch>(async () => upstreamResponse())
  const authenticate = vi.fn(async () => 'user-1' as string | null)
  const handler = createLocationAddressHandler({ apiKey: 'server-only-secret', fetcher, authenticate, ...options })
  return { handler, fetcher, authenticate }
}

describe('authenticated location-address handler', () => {
  it('returns normalized building information and never returns the provider key', async () => {
    const { handler, fetcher, authenticate } = setup()
    const result = await handler(request())
    expect(result.status).toBe(200)
    expect(result.headers.get('Cache-Control')).toBe('no-store')
    expect(result.headers.get('Access-Control-Allow-Origin')).toBe(origin)
    expect(await result.json()).toEqual({ address: '10 Market Road', city: 'Umuahia', state: 'Abia', latitude: 5.5297, longitude: 7.4862, specificity: 'building', resultType: 'building', distanceMetres: 16, confidence: 0.97 })
    expect(authenticate).toHaveBeenCalledWith('Bearer user-token')
    const url = new URL(String(fetcher.mock.calls[0][0]))
    expect(url.origin + url.pathname).toBe('https://api.geoapify.com/v1/geocode/reverse')
    expect(Object.fromEntries(url.searchParams)).toMatchObject({ lat: '5.5296', lon: '7.4861', limit: '1', lang: 'en', format: 'json', apiKey: 'server-only-secret' })
    expect(fetcher.mock.calls[0][1]?.redirect).toBe('error')
  })

  it('restricts search to Nigeria without using IP-country inference', async () => {
    const { handler, fetcher } = setup()
    expect((await handler(request({ action: 'search', text: '  10 Market Road, Umuahia  ' }))).status).toBe(200)
    const url = new URL(String(fetcher.mock.calls[0][0]))
    expect(url.pathname).toBe('/v1/geocode/search')
    expect(url.searchParams.get('text')).toBe('10 Market Road, Umuahia')
    expect(url.searchParams.get('filter')).toBe('countrycode:ng')
    expect(url.searchParams.has('bias')).toBe(false)
  })

  it('returns several bounded Nigerian autocomplete candidates instead of silently choosing one', async () => {
    const fetcher = vi.fn(async () => Response.json({ results: [record, { ...record, address_line1: '12 Market Road', lat: 5.5298 }] }))
    const { handler } = setup({ fetcher })
    const response = await handler(request({ action: 'suggest', text: 'Market Road, Umuahia' }))
    expect(response.status).toBe(200)
    expect((await response.json()).suggestions).toHaveLength(2)
    const url = new URL(String(fetcher.mock.calls[0][0]))
    expect(url.pathname).toBe('/v1/geocode/autocomplete')
    expect(url.searchParams.get('filter')).toBe('countrycode:ng')
    expect(url.searchParams.get('limit')).toBe('5')
  })

  it('does not fabricate city, confidence, precision or distance for coarse results', async () => {
    const { handler } = setup({ fetcher: vi.fn(async () => upstreamResponse({ address_line1: 'Abia', county: 'Umuahia North', lat: 5.53, lon: 7.49, result_type: 'state' })) })
    expect(await (await handler(request())).json()).toMatchObject({ city: '', specificity: 'area', resultType: 'state', distanceMetres: null, confidence: null })
  })

  it('uses street specificity when a building result has no house number', async () => {
    const { handler } = setup({ fetcher: vi.fn(async () => upstreamResponse({ ...record, housenumber: undefined, rank: { confidence: 0.4 } })) })
    expect(await (await handler(request())).json()).toMatchObject({ specificity: 'street', confidence: 0.4 })
  })

  it('denies missing or invalid authentication before any provider access', async () => {
    const { handler, fetcher, authenticate } = setup()
    expect((await handler(request(reverse, { Authorization: '' }))).status).toBe(401)
    authenticate.mockResolvedValue(null)
    expect((await handler(request())).status).toBe(401)
    expect(fetcher).not.toHaveBeenCalled()
  })

  it('returns a sanitized temporary error if authentication fails', async () => {
    const { handler, fetcher } = setup({ authenticate: vi.fn(async () => { throw new Error('private auth details') }) })
    const response = await handler(request())
    expect(response.status).toBe(503)
    expect(await response.text()).not.toContain('private auth details')
    expect(fetcher).not.toHaveBeenCalled()
  })

  it('rejects unknown origins but allows local preflight and no-origin native requests', async () => {
    const { handler, fetcher } = setup()
    expect((await handler(request(reverse, { Origin: 'https://untrusted.example' }))).status).toBe(403)
    expect(fetcher).not.toHaveBeenCalled()
    const preflight = await handler(new Request('https://example.test', { method: 'OPTIONS', headers: { Origin: 'http://localhost:3000' } }))
    expect(preflight.status).toBe(204)
    expect(preflight.headers.get('Access-Control-Allow-Origin')).toBe('http://localhost:3000')
    expect(preflight.headers.get('Access-Control-Expose-Headers')).toContain('Retry-After')
    const native = request(); native.headers.delete('Origin')
    expect((await handler(native)).status).toBe(200)
  })

  it.each([
    { action: 'reverse', latitude: 91, longitude: 7 },
    { action: 'reverse', latitude: 5, longitude: -181 },
    { action: 'reverse', latitude: '5', longitude: 7 },
    { action: 'ip' }, { action: 'search', text: 'x' },
    { action: 'search', text: 'A'.repeat(301) },
    { action: 'suggest', text: 'x' },
    { action: 'map', latitude: 5, longitude: 7, zoom: 20 },
    { action: 'tile', z: 20, x: 0, y: 0 },
    { action: 'tile', z: 3, x: 8, y: 0 },
    { action: 'tile', z: 3, x: 0, y: -1 },
    { action: 'tile', z: 3, x: 0, y: 1.2 },
  ])('rejects unsupported or invalid request %j without provider access', async body => {
    const { handler, fetcher } = setup()
    expect((await handler(request(body))).status).toBe(400)
    expect(fetcher).not.toHaveBeenCalled()
  })

  it('rejects malformed JSON, non-JSON, oversized and streamed oversized requests', async () => {
    const { handler, fetcher } = setup()
    const headers = { Authorization: 'Bearer user-token', 'Content-Type': 'application/json' }
    expect((await handler(new Request('https://example.test', { method: 'POST', headers, body: '{bad' }))).status).toBe(400)
    expect((await handler(request(reverse, { 'Content-Type': 'text/plain' }))).status).toBe(415)
    expect((await handler(request(reverse, { 'Content-Length': '9999' }))).status).toBe(413)
    expect((await handler(new Request('https://example.test', { method: 'POST', headers, body: ' '.repeat(2049) }))).status).toBe(413)
    expect(fetcher).not.toHaveBeenCalled()
  })

  it('handles absent server secret without provider access', async () => {
    const { handler, fetcher } = setup({ apiKey: undefined })
    const result = await handler(request())
    expect(result.status).toBe(503)
    expect(await result.json()).toMatchObject({ code: 'not_configured' })
    expect(fetcher).not.toHaveBeenCalled()
  })

  it('returns provider 429 and bounded Retry-After without retrying or exposing its body', async () => {
    const fetcher = vi.fn(async () => new Response('provider-secret', { status: 429, headers: { 'Retry-After': '9999' } }))
    const { handler } = setup({ fetcher })
    const result = await handler(request())
    expect(result.status).toBe(429)
    expect(result.headers.get('Retry-After')).toBe('300')
    expect(await result.text()).not.toContain('provider-secret')
    expect(fetcher).toHaveBeenCalledTimes(1)
  })

  it('retries once for network errors and 5xx then reports service outages without details', async () => {
    const fetcher = vi.fn<typeof fetch>().mockRejectedValueOnce(new Error('key=server-only-secret')).mockResolvedValueOnce(upstreamResponse())
    const { handler } = setup({ fetcher })
    expect((await handler(request())).status).toBe(200)
    expect(fetcher).toHaveBeenCalledTimes(2)
    fetcher.mockReset().mockResolvedValue(new Response('server-only-secret', { status: 503 }))
    const failure = await handler(request())
    expect(failure.status).toBe(503)
    expect(await failure.text()).not.toContain('server-only-secret')
    expect(fetcher).toHaveBeenCalledTimes(2)
  })

  it('bounds upstream timeouts to two attempts', async () => {
    const fetcher = vi.fn<typeof fetch>(async (_url, init) => new Promise((_resolve, reject) => {
      init?.signal?.addEventListener('abort', () => reject(new Error('aborted')), { once: true })
    }))
    const { handler } = setup({ fetcher, upstreamTimeoutMs: 5 })
    expect((await handler(request())).status).toBe(503)
    expect(fetcher).toHaveBeenCalledTimes(2)
  })

  it.each([
    { results: [{}] }, { results: [{ ...record, lat: 999 }] },
    { results: [{ ...record, rank: { confidence: 1.2 } }] },
    { results: [{ ...record, distance: -1 }] },
    { results: [{ ...record, city: { name: 'bad' } }] },
    { features: [] },
  ])('handles invalid provider schema %j without retrying', async payload => {
    const fetcher = vi.fn(async () => Response.json(payload))
    const { handler } = setup({ fetcher })
    expect((await handler(request())).status).toBe(502)
    expect(fetcher).toHaveBeenCalledTimes(1)
  })

  it('handles missing results and non-JSON provider responses', async () => {
    const fetcher = vi.fn<typeof fetch>().mockResolvedValueOnce(Response.json({ results: [] })).mockResolvedValueOnce(new Response('bad', { headers: { 'Content-Type': 'text/html' } }))
    const { handler } = setup({ fetcher })
    expect((await handler(request())).status).toBe(404)
    expect((await handler(request())).status).toBe(502)
  })

  it('serves fixed-host bounded map tiles as binary PNG with no secret in returned data', async () => {
    const png = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10, 0])
    const fetcher = vi.fn<typeof fetch>(async () => new Response(png, { headers: { 'Content-Type': 'image/png' } }))
    const { handler } = setup({ fetcher })
    const response = await handler(request({ action: 'tile', z: 12, x: 2133, y: 1987, url: 'https://untrusted.example' }))
    expect(response.status).toBe(200)
    expect(response.headers.get('Content-Type')).toBe('application/octet-stream')
    expect(response.headers.get('X-Image-Type')).toBe('image/png')
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(png)
    expect(String(fetcher.mock.calls[0][0])).toBe('https://maps.geoapify.com/v1/tile/osm-bright/12/2133/1987.png?apiKey=server-only-secret')
  })

  it('rejects fake PNG content', async () => {
    const { handler } = setup({ fetcher: vi.fn(async () => new Response('not an image', { headers: { 'Content-Type': 'image/png' } })) })
    expect((await handler(request({ action: 'tile', z: 0, x: 0, y: 0 }))).status).toBe(502)
  })

  it('serves a bounded static pin map without exposing the provider key', async () => {
    const jpeg = new Uint8Array([255, 216, 255, 1, 2, 3])
    const fetcher = vi.fn(async () => new Response(jpeg, { headers: { 'Content-Type': 'image/jpeg' } }))
    const { handler } = setup({ fetcher })
    const response = await handler(request({ action: 'map', latitude: 5.5296, longitude: 7.4861, zoom: 17 }))
    expect(response.status).toBe(200)
    expect(response.headers.get('X-Image-Type')).toBe('image/jpeg')
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(jpeg)
    const url = new URL(String(fetcher.mock.calls[0][0]))
    expect(url.pathname).toBe('/v1/staticmap')
    expect(url.searchParams.get('center')).toBe('lonlat:7.4861,5.5296')
    expect(url.searchParams.get('width')).toBe('320')
  })

  it('limits per-user requests and resets counters after expiry', async () => {
    let now = 0
    const { handler, fetcher } = setup({ now: () => now })
    for (let i = 0; i < 30; i++) expect((await handler(request())).status).toBe(200)
    const limited = await handler(request())
    expect(limited.status).toBe(429)
    expect(limited.headers.get('Retry-After')).toBe('60')
    expect(fetcher).toHaveBeenCalledTimes(30)
    now = 60_001
    expect((await handler(request())).status).toBe(200)
  })
})
