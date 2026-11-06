# Traffic spike review and optimizations (2026-11-06)

This review traces the current customer address picker, rider dashboard, road
matching, and quote-expiry worker. Counts below come from code paths and
arithmetic, **not a production load test or a certified capacity estimate**.
No synthetic traffic was sent to paid services for this review.

| Path | Before | After this change | Remaining limit |
| --- | --- | --- | --- |
| Visible rider screen | 7 dashboard HTTP requests/10 s plus 1 session check/15 s | 1 dashboard snapshot/10 s; session check remains for hidden or failed-snapshot periods | Snapshot still runs the six scoped SQL readers; DB CPU and p95 need measurement. |
| Idle rider road scoring | 3×3 matrix = 9 Google elements/candidate | Rider→pickup plus pickup→drop-off = 2 elements for first candidate, then 1 per additional idle candidate because the common delivery leg is reused only within that request | Active riders/replans still use square matrices of up to 100 elements. |
| Quote expiry | At most 100 due jobs/minute, cron every minute | At most 100 due jobs/10 s, theoretical 600/minute | Each batch is sequential and may take longer than 10 s; a real backlog can still accumulate. |
| Shared-place typeahead | One DB lookup after each 350 ms pause; a local DB error automatically starts a provider lookup | 600 ms debounce; identical recent local queries share one request and a short result cache; provider lookup after local failure needs an explicit tap | Unique text misses still use Google automatically. Provider quota and real hit rate need measurement. |

At the six-idle-candidate maximum, road elements fall from 54 to 7 per order
(six rider→pickup legs and one pickup→drop-off leg), assuming all points are
distinct and every route is available. The 5,000-element/day application guard
would then allow at most `floor(5000/7) = 714` such fully scored orders/day
before replans, failed Google calls, and active-rider comparisons. It is a
**spend guard**, not the capacity of Supabase Team or a Google free allowance.
When the guard is exhausted, a read-only budget check avoids contending for
the daily counter's update lock; the final atomic update still enforces the
limit under concurrent workers. The route worker also skips repeat reservations
of an already-denied size within one UTC day and invocation.
Google documents [per-element Matrix billing](https://developers.google.com/maps/documentation/routes/usage-and-billing)
and [the origins-and-destinations request shape](https://developers.google.com/maps/documentation/routes/compute_route_matrix).

The quote-expiry schedule raises the *possible* service rate to 600/minute if
each 100-job run completes within 10 seconds. A hypothetical 100,000
orders/day with a 5× daily-average burst creates about 347 expiries/minute
**only if every order opens a quote window**. The new schedule has arithmetic
headroom for that scenario, but it does not establish p95 expiry delay or
end-to-end order capacity. A 1,000,000-orders/day 5× scenario exceeds it.
[Supabase Cron supports sub-minute schedules](https://supabase.com/docs/guides/cron),
but worker run time and backlog still need observation after deployment.

For launch monitoring, record hourly quote queue age and dead-letter count;
route-matrix elements reserved per order, active-stop distribution and budget
denials; rider snapshot p50/p95/p99 latency; address local-hit rate and Google
fallback calls; and database CPU, connections, WAL and I/O. Measure against a
separate staging project and real Nigerian traffic patterns before raising the
Google spend guard or claiming a user-capacity figure.
