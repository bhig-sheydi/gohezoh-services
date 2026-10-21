import { describe, expect, it } from 'vitest'
import { routeLabel } from './route-label'

describe('routeLabel', () => {
  it('uses saved streets and communities for a same-city delivery', () => {
    expect(routeLabel('Police Post, Eliozu', 'Port Harcourt', 'Farm Road 2, Eliozu', 'Port Harcourt'))
      .toBe('Police Post, Eliozu → Farm Road 2, Eliozu')
  })

  it('falls back to cities for older records without addresses', () => {
    expect(routeLabel(null, 'Aba', '', 'Port Harcourt')).toBe('Aba → Port Harcourt')
  })
})
