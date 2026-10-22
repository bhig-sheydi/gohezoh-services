import type { Point, RoadMatrix } from './rider-route-planner.ts'

type Cell = { time?: number | null; distance?: number | null }
type MatrixResponse = { sources_to_targets?: Cell[][] }
const valid = (p: Point) => Number.isFinite(p.latitude) && Number.isFinite(p.longitude) &&
  Math.abs(p.latitude) <= 90 && Math.abs(p.longitude) <= 180
const key = (p: Point) => `${p.latitude.toFixed(6)},${p.longitude.toFixed(6)}`

/** One bounded all-to-all road matrix. Reservations are deliberately not refunded on HTTP failure. */
export async function geoapifyRoadMatrix(
  points: Point[], apiKey: string,
  reserve: (credits: number) => Promise<boolean>,
  fetcher: typeof fetch = fetch,
): Promise<RoadMatrix | undefined> {
  if (!apiKey || points.length < 2 || points.length > 10 || points.some((p) => !valid(p))) return undefined
  const unique = [...new Map(points.map((point) => [key(point), point])).values()]
  if (unique.length === 1) return (from, to) => key(from) === key(unique[0]) && key(to) === key(unique[0])
    ? { minutes: 0, kilometres: 0 } : undefined
  const credits = unique.length ** 2
  if (credits > 100 || !await reserve(credits)) return undefined
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 3500)
  try {
    const response = await fetcher(`https://api.geoapify.com/v1/routematrix?apiKey=${encodeURIComponent(apiKey)}`, {
      method: 'POST', headers: { 'content-type': 'application/json' }, signal: controller.signal,
      body: JSON.stringify({ mode: 'drive', traffic: 'approximated',
        sources: unique.map((p) => ({ location: [p.longitude, p.latitude] })),
        targets: unique.map((p) => ({ location: [p.longitude, p.latitude] })) }),
    })
    if (!response.ok) return undefined
    const body = await response.json() as MatrixResponse
    if (!Array.isArray(body.sources_to_targets) || body.sources_to_targets.length !== unique.length ||
      body.sources_to_targets.some((row) => !Array.isArray(row) || row.length !== unique.length)) return undefined
    const lookup = new Map(unique.map((p, i) => [key(p), i]))
    return (from, to) => {
      const i = lookup.get(key(from)); const j = lookup.get(key(to))
      if (i === undefined || j === undefined) return undefined
      const cell = body.sources_to_targets?.[i]?.[j]
      if (!cell || typeof cell.time !== 'number' || !Number.isFinite(cell.time) || cell.time < 0 ||
        typeof cell.distance !== 'number' || !Number.isFinite(cell.distance) || cell.distance < 0) return undefined
      return { minutes: cell.time / 60, kilometres: cell.distance / 1000 }
    }
  } catch { return undefined }
  finally { clearTimeout(timer) }
}
