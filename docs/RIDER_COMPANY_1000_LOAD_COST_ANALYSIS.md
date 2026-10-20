 # Rider and logistics-company load and cost analysis (20 October 2026)

This is a **free, offline simulation**, not a database benchmark. The script at [`scripts/simulate-rider-company-load.mjs`](../scripts/simulate-rider-company-load.mjs) sends no network traffic. It models 1,000 riders across 12 Nigerian regions, 100 company dashboard sessions, 1,000 customers viewing tracking, and 1, 10, or 100 new orders per second. It assumes eight active hours per day for 30 days. A two-fix live observation from one rider showed 80- and 88-second intervals; this is a short sample, not a stable population average.

## What the current code does

| Feature | Active traffic | Cost exposure |
| --- | --- | --- |
| Rider GPS | Browser checks about every 30 seconds; sends a fix after 60 seconds or 50 metres of movement. The server refuses writes under 15 seconds apart. One current and one previous fix are retained per rider. | Write load and database CPU/WAL, not a growing GPS-history table. Browser background tracking pauses. |
| Rider job screen | Every visible rider polls a role query plus five job/profile/location RPCs every 10 seconds. | Six requests per 10 seconds per rider; this dominates steady-state traffic. |
| Company bidding screen | Every visible company polls three RPCs every 30 seconds, plus the shared app checks its role every 30 seconds. A Postgres Changes event can trigger another three-RPC reload. | Baseline reads plus event amplification and Realtime connections/messages. Photo signed URLs are renewed as needed. |
| Company welcome/team/roster | Welcome refreshes on initial load and at day change. Team, invitations, rider jobs, and roster load initially and after actions. | Small steady-state load; can become large with very large rosters or returned job lists. |
| Customer rider tracking | One tracking RPC every 60 seconds while visible. Exact-address checks call a quota RPC; a successful check invokes reverse geocoding and landmark lookup. | Database reads, Edge invocations, Geoapify credits. The two-check hourly cap is per customer, not a global provider quota. |
| Dispatch matching | Each new local order tries a 5-km PostGIS search. If unmatched, a once-per-minute worker retries at most 100 queued requests per run. A quote can invite up to 50 companies. | CPU rises with order rate and nearby-rider count; unmatched bursts can accumulate. |
| Documents/photos | Rider credentials, license and NIN evidence, customer parcel photos, company logos and signed photo URLs are action-driven. | Storage capacity, storage egress, and signed-URL calls; image size and retention matter more than rider count alone. |

## Offline simulation output

The script spreads rider polling phases over time; it does not assume every phone's timer fires at the same instant. The baseline already includes 1,000 customer tracking views, which may be conservative or aggressive depending on the number of simultaneous paid deliveries. It excludes the rest of the customer and admin app.

| Metric | 1,000 active riders / 100 visible companies / 1,000 tracking customers |
| --- | ---: |
| Rider dashboard reads | 600 requests/second; 518.4 million/month |
| Company baseline polling | 13.3 requests/second; 11.52 million/month |
| Customer tracking | 16.7 requests/second; 14.4 million/month |
| All baseline reads | 630 requests/second; 544.32 million/month |
| GPS writes at the observed 84-second interval | 11.9 writes/second; 10.29 million/month |
| GPS writes at the code's approximate 30-second ceiling | 33.3 writes/second; 28.8 million/month |
| Peak one-second baseline in this phased model | 633 reads and 12 observed-rate GPS writes |

Order events create an additional range because the actual Realtime audience and row-level-security fanout were not load-measured. The lower bound assumes only ten invited companies reload; the upper bound assumes all 100 subscribed companies reload for every quote-window event. Each reload makes three RPCs. These are **traffic envelopes**, not measured production behavior.

| Orders/second | Orders per 8-hour-day month | Total read requests/second, lower–upper | Unmatched retry queue growth/minute if 20% miss |
| ---: | ---: | ---: | ---: |
| 1 | 864,000 | 660–930 | 0 |
| 10 | 8.64 million | 930–3,630 | 20 |
| 100 | 86.4 million | 3,630–30,630 | 1,100 |

The queue-growth example assumes 20% unmatched orders and the current 100-rows-per-minute worker. It is not a predicted miss rate. At 100 orders/second, the synchronous initial match attempt would also need to execute 100 times/second; this has not been benchmarked.

## Free-plan consequence

Supabase Free currently includes [5 GB egress, a 500 MB database, 1 GB storage, 500,000 Edge invocations, 2 million Realtime messages, and 200 peak Realtime connections](https://supabase.com/docs/guides/platform/billing-on-supabase). The modeled **baseline response egress alone** is 272 GB/month if each database response averages just 0.5 KB, 544 GB at 1 KB, or 2.72 TB at 5 KB. These are payload assumptions, not measured response sizes, and exclude order-event reloads, images, authentication, and the rest of the app. A free project would hit its 5 GB allowance long before this sustained load; it is not a viable 1,000-active-rider production tier. [Supabase explains that free-plan excess can result in restrictions rather than ordinary overage billing](https://supabase.com/docs/guides/platform/cost-control).

One company bid screen uses one Realtime connection. One hundred company screens fit under the stated 200-connection Free limit in isolation; two hundred or more would collide with other project connections. At ten delivered invitation events per order, even one order/second for eight hours daily would imply 8.64 million delivered events/month, above the 2 million Free message allowance. Actual delivered message counts require measurement because RLS and subscriptions govern delivery. [Supabase Realtime limits](https://supabase.com/docs/guides/realtime/limits).

Geoapify's [Free plan allows 3,000 credits/day and up to five requests/second](https://www.geoapify.com/pricing/). A rider-address check uses reverse geocoding plus a nearby-places lookup; [reverse geocoding uses one credit](https://www.geoapify.com/pricing-details/) and Places credits depend on result count. If 1,000 customers each used the maximum two checks **per hour** for eight hours, that would be 16,000 checks/day and at least 16,000 reverse-geocoding credits before Places usage. The two-per-customer/hour security cap does not protect the shared free provider quota. Those 32,000 Edge calls/day would also exceed Supabase Free's 500,000 monthly invocation allowance after about 16 days at that rate. Normal usage may be much lower.

Parcel photos could independently exhaust the 1 GB Free storage allowance. For illustration, 864,000 orders/month with one retained 100 KB photo each would add about 86 GB before other evidence; actual order rate, image compression, and retention policy are unknown. The database's 500 MB limit can likewise be exceeded by order/bid records; exact row and index sizes need measurement.

## Cost envelope if moved to Pro later

The paid plan is **not being enabled by this analysis**. Supabase lists a $25 Pro subscription, $10 monthly compute credit, and roughly $111/month Large, $210/month XL, or $410/month 2XL compute. That corresponds to about $126, $225, or $425/month before egress, storage and other extras. No tier is certified to handle these query rates; a staging load test would be needed. [Supabase compute prices](https://supabase.com/docs/guides/platform/manage-your-usage/compute).

Pro includes [250 GB uncached egress, then $0.09/GB](https://supabase.com/docs/guides/platform/manage-your-usage/egress). Under the baseline-only response-size assumptions above, incremental egress would be about $2/month at 0.5 KB, $26/month at 1 KB, or $222/month at 5 KB. Event reloads and photos can materially increase it. These are arithmetic scenarios, **not a quote**.

## What to change before 1,000 concurrent riders

1. Replace the rider's six 10-second queries with one compact, indexed job-state RPC and either event-driven invalidation or a much slower fallback poll (for example, 30–60 seconds). This is the largest steady-state saving. Do not slow the GPS feed merely to compensate for dashboard polling.
2. Remove the company bid screen's whole-table event reload behavior. Subscribe to only company-relevant invitations, debounce event reloads, and keep a bounded 30–60-second fallback poll. Measure delivered Realtime messages and connections.
3. Batch or parallelize the unmatched-order worker only after observing queue depth and matching-query time. The current 100/minute retry ceiling can accumulate backlog under sustained misses.
4. Measure actual per-endpoint response bytes, DB latency, CPU, WAL, and storage growth on a non-production dataset. Capture P95 and P99 latency, not only averages. Then select compute and set alerts.
5. Enforce a global daily address-provider budget and show a safe GPS/map fallback when exhausted. Compress and expire nonessential parcel images and signed URLs according to retention requirements.

Changing six rider requests every 10 seconds to **one every 30 seconds** would cut rider-screen polling from 600 to about 33 requests/second (about 94% fewer). One every 60 seconds would be about 17/second. Even the 30-second option still means roughly 28.8 million rider responses/month at the modeled activity level, so optimization alone does not make 1,000 concurrently active riders fit the Free plan's 5 GB egress allowance at ordinary response sizes.

No production load was generated, no paid resource was started, and no database data was changed. The live `pg_stat_statements` view was read once for context: historical mean execution times were approximately 14 ms for rider jobs, 11 ms for pickup locations, 7 ms for delivery locations, 34 ms for selected pickups, 13 ms for partner bids, and 137 ms for GPS reports. These historical, low-concurrency statement timings **cannot** be multiplied into a reliable 1,000-rider capacity claim: they include unknown workload and wait time, and the counter reset period is unknown.
