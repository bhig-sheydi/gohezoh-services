import { describe, expect, it } from 'vitest'
import { selectRoadCheckCandidates } from '../../supabase/functions/_shared/route-match-economy'

const candidates = [
  ...Array.from({ length: 5 }, (_, index) => ({ id: `near-${index}`, distance_metres: 1000 + index })),
  ...Array.from({ length: 4 }, (_, index) => ({ id: `route-${index}`, distance_metres: 5001 + index })),
]

describe('economy road-check selection', () => {
  it('keeps the established candidate search in normal mode', () => {
    expect(selectRoadCheckCandidates(candidates, false, 99).map((candidate) => candidate.id))
      .toEqual(['near-0', 'near-1', 'near-2', 'route-0', 'route-1', 'route-2'])
  })

  it('spends on fewer new-job road checks while still considering nearby and en-route riders', () => {
    const selected = selectRoadCheckCandidates(candidates, true, 0)
    expect(selected.map((candidate) => candidate.id)).toEqual(['near-0', 'near-1', 'route-0'])
  })

  it('rotates across retry attempts so a later eligible company is not excluded forever', () => {
    const visited = new Set<string>()
    for (let attempt = 0; attempt < 5; attempt++) {
      const selected = selectRoadCheckCandidates(candidates, true, attempt)
      expect(selected).toHaveLength(3)
      selected.forEach((candidate) => visited.add(candidate.id))
    }
    expect(visited).toEqual(new Set(candidates.map((candidate) => candidate.id)))
  })

  it('checks every remaining rider when fewer are eligible than the reduced budget', () => {
    const remaining = candidates.filter((candidate) => candidate.id === 'near-4' || candidate.id === 'route-3')
    expect(selectRoadCheckCandidates(remaining, true, 42)).toEqual(remaining)
  })
})
