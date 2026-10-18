import { afterEach, describe, expect, it, vi } from 'vitest'
import { LocationError, type PositionFix } from './proximity'
import { startRiderTracking } from './rider-tracking'

afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks() })
const fix = (): PositionFix => ({ latitude: 6.45, longitude: 3.4, accuracyMetres: 18, capturedAt: Date.now(), source: 'browser' })

describe('rider duty tracking', () => {
  it('reports a fresh fix only while on duty and clears presence when stopped', async () => {
    vi.useFakeTimers()
    const report = vi.fn(async () => {}), offline = vi.fn(async () => {}), status = vi.fn()
    const getPosition = vi.fn(async () => fix())
    const stop = startRiderTracking({ report, offline, status, failed: vi.fn(), getPosition })
    await vi.waitFor(() => expect(report).toHaveBeenCalledTimes(1))
    await vi.advanceTimersByTimeAsync(30_000)
    expect(getPosition).toHaveBeenCalledTimes(2)
    expect(report).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(30_000)
    expect(report).toHaveBeenCalledTimes(2)
    stop()
    await vi.waitFor(() => expect(offline).toHaveBeenCalledTimes(1))
    await vi.advanceTimersByTimeAsync(60_000)
    expect(getPosition).toHaveBeenCalledTimes(3)
  })

  it('stops on denied permission without reporting any position', async () => {
    vi.useFakeTimers()
    const report = vi.fn(async () => {}), offline = vi.fn(async () => {}), failed = vi.fn()
    startRiderTracking({ report, offline, status: vi.fn(), failed,
      getPosition: vi.fn(async () => { throw new LocationError('permission_denied', 'Permission denied') }) })
    await vi.waitFor(() => expect(failed).toHaveBeenCalledTimes(1))
    expect(report).not.toHaveBeenCalled()
    expect(offline).toHaveBeenCalledTimes(1)
  })

  it('retries temporary GPS timeouts without going off duty or deleting a recent fix', async () => {
    vi.useFakeTimers()
    const report = vi.fn(async () => {}), offline = vi.fn(async () => {}), failed = vi.fn()
    const getPosition = vi.fn()
      .mockResolvedValueOnce(fix())
      .mockRejectedValueOnce(new LocationError('timeout', 'GPS timed out'))
      .mockResolvedValueOnce(fix())
    const stop = startRiderTracking({ report, offline, status: vi.fn(), failed, getPosition })
    await vi.waitFor(() => expect(report).toHaveBeenCalledTimes(1))
    await vi.advanceTimersByTimeAsync(30_000)
    expect(offline).not.toHaveBeenCalled()
    expect(failed).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(10_000)
    expect(getPosition).toHaveBeenCalledTimes(3)
    expect(report).toHaveBeenCalledTimes(1)
    stop()
    await vi.waitFor(() => expect(offline).toHaveBeenCalledTimes(1))
  })
})
