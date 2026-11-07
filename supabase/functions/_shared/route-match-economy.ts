/** Keep optional road checks bounded without permanently hiding later riders.
 * Persistent searches retry every two minutes, so each attempt moves through
 * the eligible candidates instead of testing the same first riders forever.
 */
export function selectRoadCheckCandidates<T extends { distance_metres: number }>(
  candidates: T[], economyMode: boolean, attempt: number,
): T[] {
  const nearby = candidates.filter((candidate) => candidate.distance_metres <= 5000)
  const enRoute = candidates.filter((candidate) => candidate.distance_metres > 5000)
  if (!economyMode) return [...nearby.slice(0, 3), ...enRoute.slice(0, 3)]
  const take = (pool: T[], count: number) => {
    if (pool.length <= count) return pool
    const offset = ((Math.floor(attempt) % pool.length) + pool.length) % pool.length
    return Array.from({ length: count }, (_, index) => pool[(offset + index) % pool.length])
  }
  return [...take(nearby, 2), ...take(enRoute, 1)]
}
