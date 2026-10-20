// Offline traffic model. This script makes no network or database requests.
const durationSeconds = 3600
const riders = 1000
const companies = 100
const watchingCustomers = 1000
const activeHoursPerDay = 8
const days = 30
const secondsPerMonth = activeHoursPerDay * 3600 * days
const regions = [
  ['Lagos', 280], ['Abuja', 130], ['Port Harcourt', 120], ['Kano', 100],
  ['Ibadan', 90], ['Aba', 70], ['Umuahia', 50], ['Enugu', 50],
  ['Benin City', 45], ['Owerri', 35], ['Calabar', 20], ['Other cities', 10],
]
if (regions.reduce((sum, [, count]) => sum + count, 0) !== riders) throw new Error('Region counts must add to rider count')

function addPeriodic(buckets, count, interval, requests) {
  for (let user = 0; user < count; user++) {
    const offset = (user * 7919) % interval
    for (let second = offset; second < buckets.length; second += interval) buckets[second] += requests
  }
}
function stats(values) {
  const sorted = [...values].sort((a, b) => a - b)
  return { meanPerSecond: +(values.reduce((sum, value) => sum + value, 0) / values.length).toFixed(1),
    p95PerSecond: sorted[Math.floor(sorted.length * 0.95)], peakPerSecond: sorted.at(-1) }
}
const baseReads = Array(durationSeconds).fill(0)
const gpsWrites = Array(durationSeconds).fill(0)
addPeriodic(baseReads, riders, 10, 6) // rider role lookup + five RPCs
addPeriodic(baseReads, companies, 30, 4) // company role lookup + three bid RPCs
addPeriodic(baseReads, watchingCustomers, 60, 1) // delivery tracking RPC
addPeriodic(gpsWrites, riders, 84, 1) // two live intervals observed: 80s and 88s
const modeledBase = {
  regions: Object.fromEntries(regions), riders, companies, watchingCustomers,
  riderReads: stats(Array.from({ length: durationSeconds }, (_, second) => {
    // Separate rider-only read curve; the total is tracked below.
    let count = 0
    for (let user = 0; user < riders; user++) if (second % 10 === (user * 7919) % 10) count += 6
    return count
  })),
  allBaselineReads: stats(baseReads), gpsWrites: stats(gpsWrites),
  monthly: {
    riderReads: riders * 6 / 10 * secondsPerMonth,
    companyPollingReads: companies * 4 / 30 * secondsPerMonth,
    customerTrackingReads: watchingCustomers / 60 * secondsPerMonth,
    gpsWritesObservedRate: Math.round(riders / 84 * secondsPerMonth),
    gpsWritesCodeCeiling: riders / 30 * secondsPerMonth,
    baselineEgressGBAtHalfKB: +(baseReads.reduce((sum, value) => sum + value, 0) / durationSeconds * secondsPerMonth * 0.5 / 1e6).toFixed(1),
    baselineEgressGBAtOneKB: +(baseReads.reduce((sum, value) => sum + value, 0) / durationSeconds * secondsPerMonth / 1e6).toFixed(1),
    baselineEgressGBAtFiveKB: +(baseReads.reduce((sum, value) => sum + value, 0) / durationSeconds * secondsPerMonth * 5 / 1e6).toFixed(1),
  },
}
const scenarios = [1, 10, 100].map((ordersPerSecond) => {
  const invitedCompaniesPerOrder = 10
  const invitedOnlyReads = 3 * invitedCompaniesPerOrder * ordersPerSecond
  const globalVisibleReads = 3 * companies * ordersPerSecond
  const unmatchedPerMinute = ordersPerSecond * 60 * 0.2
  return {
    ordersPerSecond, monthlyOrders: ordersPerSecond * secondsPerMonth,
    totalReadsPerSecondIfOnlyInvitedReload: +(modeledBase.allBaselineReads.meanPerSecond + invitedOnlyReads).toFixed(1),
    totalReadsPerSecondIfAllCompaniesReload: +(modeledBase.allBaselineReads.meanPerSecond + globalVisibleReads).toFixed(1),
    possibleRealtimeMessagesPerMonthAtTenInvites: ordersPerSecond * secondsPerMonth * invitedCompaniesPerOrder,
    unmatchedRetryQueueGrowthPerMinuteAt20PercentMisses: Math.max(0, unmatchedPerMinute - 100),
  }
})
console.log(JSON.stringify({ assumptions: { durationSeconds, activeHoursPerDay, days, observedGpsIntervalsSeconds: [80, 88],
  bidEvents: 'Two bounds: only ten invited companies reload, or all 100 subscribed companies reload. RLS fanout not measured.',
  orderMissRate: '20% illustrative; queue processes at most 100 rows/minute.' }, baseline: modeledBase, scenarios }, null, 2))
