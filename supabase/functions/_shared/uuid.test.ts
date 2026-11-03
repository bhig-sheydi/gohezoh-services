import { describe, expect, it } from 'vitest'
import { isUuid } from './uuid'

describe('UUID validation for payment endpoints', () => {
  it('accepts a real delivery request ID', () => {
    expect(isUuid('b9883c0c-c348-46c2-b548-cdceb6b91a1e')).toBe(true)
  })

  it('rejects malformed IDs', () => {
    expect(isUuid('REQ-01999')).toBe(false)
    expect(isUuid('b9883c0c-c348-46c2-b548-cdceb6b91a1')).toBe(false)
  })
})
