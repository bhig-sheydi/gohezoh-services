# Rider assignment and route sequencing specification

Status: stages 1, 2, and server-owned next-stop sequencing are deployed. Route-aware bid invitations remain in shadow evaluation pending real-outcome validation. Scope: local, in-state deliveries using the current customer -> private company bid -> customer choice -> verified payment -> rider pickup-code -> recipient-code/customer-confirmed delivery flow. Interstate handoffs need a separate leg model before this planner can operate across companies.

Current implementation: a server-only worker consumes assignment, custody, and material GPS events; it calls Geoapify's road matrix under a 1,500-credit daily application budget, records candidate scores without changing live invitations, and commits versioned next stops for assigned riders. The existing proximity invitation continues to choose companies for bids. The worker is awakened on queue inserts, with a one-minute retry schedule. A stale or unavailable road matrix does not justify claiming route alignment. Activation of route-aware invitations needs measured shadow results and end-to-end customer/company tests.

Deployment needs `GEOAPIFY_API_KEY` and a generated `ROUTE_WORKER_SECRET` in Supabase Edge secrets. Put the same worker secret in Supabase Vault under `route_worker_secret` so the database queue can wake the Edge Function. Keep the value outside Git. For long routes, all assigned stops remain recorded, but only the first nine stops receive road ETAs per planning pass; later ETAs stay unset until they enter that horizon.

## Existing integration points and gaps

The current local matcher uses a fresh (`<2 minutes`), accurate (`<=100 m`) rider GPS fix within 5 km of the pickup, chooses the closest eligible rider per company, and invites up to 50 companies for a one-minute bid. The invited rider is assigned when the paid company award is accepted, subject to fresh GPS and the rider-reported full state. The customer's chosen company and its bid remain authoritative. The company, not the rider, bids. These rules are the compatibility boundary for this design.

The database now has rider-reported load state, versioned stop plans, a bounded route queue, and road-matrix budget enforcement. Customer deadline promises and full invitation activation still need outcome validation. The rider's box capacity remains unknown, so the rider's own `full` declaration controls fit. The existing invitation's `rider_id` is a candidate, not a guaranteed reservation. Address-search coordinates can be approximate; device GPS accuracy must not be inferred from them.

The planner never assigns a company on behalf of the customer, changes a selected price, bypasses payment, or changes the existing custody codes. It selects the best rider *within each eligible company* for an invitation and commits a feasible route only after that company wins and payment is verified. No super-admin or BDO approval is part of this dispatch algorithm.

## Architecture and data contract

1. **Request normalizer** validates pickup/drop-off coordinates and their source, parcel aggregate weight and dimensions, desired pickup time, handling needs, and service area. It records missing or uncertain location evidence. A street centroid is a search hint, not an exact entrance or reliable ETA anchor.
2. **Candidate discovery** uses PostGIS spatial indexes for fresh on-duty rider locations, plus a bounded expansion around *projected next stops* for riders with committed routes. It filters by active rider/company credentials, rider-reported load state (`available` or `almost_full`, never `full`), current commitments, and company service area. It may look beyond the present 5 km radius only for route-aligned riders with a credible road ETA to pickup. Discovery returns several riders per company, then keeps the best feasible one; an `almost_full` rider remains eligible but carries a warning to the company.
3. **Travel-time provider** supplies a road-network duration and distance matrix for the rider's present position, the new pickup/drop-off, and that rider's remaining stops. The provider must be separately configured, priced, cached, and tested. The current Geoapify address lookup/map tiles do not establish that a routing endpoint is configured. Cache by rounded coordinate pair, travel mode, traffic bucket, and short TTL; mark every estimate with source and age. Straight-line distance is suitable for cheap prefiltering only. If the road provider is unavailable, use a conservative calibrated distance estimate for *simple idle-rider pickup ranking*; do not claim route alignment or rearrange loaded riders from this estimate.
4. **Per-rider sequencer** builds an ordered stop plan and ETA for every candidate. It treats collected goods as already on board, pickup-before-drop-off as mandatory, and the rider's `full` state as an exclusion from new work. It does not fabricate a box weight or volume limit. It keeps completed stops out of the active plan.
5. **Company invitation ranker** compares each company's best feasible candidate, creates one private invitation per company, and stores the proposed rider, score, estimate provenance, and expiration. Existing one-minute private bidding and customer choice remain intact. A preliminary candidate is not a rider assignment.
6. **Award committer** revalidates the winning company's proposed rider and plan after verified payment. It serializes the rider and job, checks that the rider has not marked `full`, enforces the rider-reported full state, and writes the assignment and route version atomically, or selects the next eligible rider *from the same company*. If none is eligible, it follows a controlled failed-award/requote path; it never silently assigns another company.
7. **Replanner** updates only affected riders after pickup-code verification, delivery confirmation, material movement, newly committed jobs, unavailability, or material traffic changes. It publishes a new version only if feasible and materially better. The rider sees one next stop with concise directions and a version number; an acknowledged or nearly reached stop is temporarily pinned to prevent churn.

Suggested new tables/fields: a rider-controlled `load_state` (`available`, `almost_full`, `full`), `load_state_changed_at` and actor; `delivery_commitments` (accepted time windows and latest acceptable times); `rider_route_plans` (rider, version, state, estimate source/time, objective, created_at); `rider_route_stops` (sequence, job, pickup/drop-off, coordinates, status, ETA, service time); `dispatch_decisions` (request, company, rider, load state at invitation, tier, score components, rejected candidates/reasons, matrix version, algorithm version, idempotency key); and a bounded `route_replan_events` queue. Exact names may differ, but these facts must be persisted and access-controlled. Existing customer parcel weight and dimensions remain visible to the company for its fit decision; they do not become an invented rider-box capacity. Do not retain a rider GPS trail solely for planning; use the existing latest-presence row and audit decisions without raw location history.

### Rider-controlled load state

The rider has three clear choices while on duty: **Available**, **Almost full**, and **Full**. This is a declaration about usable box space, not a calculated measurement. **Full** immediately excludes the rider from new candidate discovery, bid invitations, and paid-award revalidation. It does not set the rider off duty, delete their latest presence, stop GPS updates, hide active jobs, cancel committed pickups, or interrupt customer tracking and route updates for parcels already assigned. The rider stays visible as **On duty · Full** to their company. Only that rider (or an explicitly authorized company rider manager) may change the state; the server records actor and time.

**Almost full** still allows invitations. On the company bid screen, show a conspicuous **red “Rider almost full” badge** next to that rider and the parcel's supplied size/weight, so the company can decide whether it fits and whether to bid. The company may decline; if it bids, its existing availability confirmation must explicitly cover the parcel fitting the proposed rider's available space. An `available` rider may be preferred when practical, but `almost_full` is not an automatic rejection. This warning is for the company before bidding, not a customer-facing claim about measured capacity.

The state stays `full` until the rider or authorized company manager explicitly changes it to `almost_full` or `available`. Completing a delivery does not clear it automatically. Re-enabling invitations still requires fresh accurate GPS and active rider access. If the rider marks full after an invitation but before the customer's paid award, revalidate and select another eligible rider from the same company or surface the assignment issue. Already paid/assigned work remains the rider's responsibility unless the normal custody-safe reassignment procedure is used. Load state is separate from the existing off-duty action, which stops new location reports and availability.

## Feasibility, priority tiers, and scoring

Hard constraints are checked before scoring: active on-duty rider and company; fewer than six assigned, unfinished parcels; rider load state not `full`; fresh usable location; company service eligibility; valid pickup and drop-off; pickup before its drop-off; explicit accepted deadlines; and no assignment already committed elsewhere. Routine delay to existing parcels is not a rejection criterion. The planner cannot calculate whether goods physically fit an unmeasured box. The company sees parcel details and the rider's `almost_full` warning before it bids; the rider can mark `full` whenever no further parcel will fit.

For each feasible insertion, calculate `T_pickup`, total additional road minutes `DeltaT`, additional road kilometres `DeltaD`, maximum positive delay to any committed stop `MaxDelay`, weighted sum of those delays `DelaySum`, estimated empty kilometres saved compared with a separate trip, and route alignment. An aligned destination is close in **road travel time** or lies on the planned route with a small marginal detour, not merely near it on a map. A rider is travelling toward a point only when recent positions and the committed next stop support that direction; a single GPS reading cannot prove heading.

Assign a preference tier after feasibility:

| Tier | Meaning | Required evidence |
| --- | --- | --- |
| 1 | Pickup reachable soon **and** new destination coincides with or lies on/near a committed delivery path | Road ETA to pickup, insertion cost, and destination overlap all within configured bounds |
| 2 | Present rider position is farther away, but a committed route reaches the pickup area soon; the onward destination aligns | Projected arrival at a committed stop, then feasible pickup and onward insertion |
| 3 | Nearby rider can serve the request with a reasonable new route despite no destination overlap | Feasible insertion and bounded detour to existing jobs |
| 4 | Other feasible rider | Meets all hard limits, with a bounded pickup ETA; includes idle riders and expanded-radius fallback |

The live invitation rule compares feasible tiers in strict order: nearby aligned, then farther aligned, then nearby non-aligned. A candidate must pass the pickup and explicit deadline limits before entering a tier. Scores and rider IDs break ties within a tier. A possible future corridor has **zero** current score unless a real accepted job already uses it.

Use a lexicographic objective, not one opaque weighted sum:

1. Reject plans that breach the six-active-parcel limit, pickup ETA limit, or an explicit accepted deadline.
2. Compare nearby aligned routes before farther aligned routes, then nearby non-aligned routes. Do not rank by routine delay to existing parcels.
3. Within a tier, minimize `J = 4*T_pickup + DeltaT + DeltaD` using road minutes and kilometres. Tune coefficients with recorded outcomes; this score never overrides step 1.
4. Compare eligible tiers 1, 2, 3, then 4 before comparing scores within a tier. Avoid reassigning an already committed rider for a marginal score improvement.

The tier and score thresholds are **launch policy proposals**, not existing product promises. Record them in versioned configuration so outcomes can be reproduced and tuned without changing historical decisions.

## Stop sequencing

Represent each undelivered job as a pickup `P(j)` and drop-off `D(j)`. A picked-up job has only `D(j)`. A pending unpaid selection has neither committed stop. Include current load at the rider's present position. Every candidate sequence must satisfy `P(j) < D(j)`, time windows, legal load at each step, and non-negative service time. Evaluate road travel from present position through all stops, not straight-line distances.

For the existing small workload, enumerate **all insertion positions** for the new pickup/drop-off into the current order; for a picked-up job insert only its drop-off. Then apply a bounded local search (swap/relocate compatible stops and 2-opt where precedence survives) with a deterministic time/iteration cap. A beam search of at most 32 partial plans is the fallback when 10 or more stops make exhaustive insertion expensive. Keep the best feasible plan under the lexicographic objective. Never reorder an active handoff, a stop already acknowledged within its no-churn radius, or a time-critical committed stop without a material gain and deadline proof.

The server owns the plan. Clients display `next_stop`, ETA range, and `plan_version`; a client never computes the authoritative order. Replan on a **meaningful event**, not every 15-second GPS write: a new funded job, pickup/delivery verification, rider offline, deviation beyond a proposed 500 m/5-minute threshold, or traffic ETA change beyond a proposed 10%. Debounce repeated events for the same rider, use the latest event, and rate-limit road matrix calls. Position changes below the threshold update display ETA only. A route update is published only if the improvement exceeds a proposed 3-minute/10% hysteresis or repairs an infeasible plan. Pin the next stop once the rider is within a proposed 300 m or 3 minutes, unless safety or cancellation requires a change.

## Current live invitation behavior (22 October 2026)

For new local requests with confirmed coordinates, a short `matching` stage now precedes the one-minute company bid window. The worker road-scores a bounded set of fresh, on-duty riders: first up to three within 5 km of pickup, then up to three farther riders whose committed next stop is within 2 km of pickup. Within that candidate set it invites companies from the first available tier: nearby riders with a feasible aligned route (tier 1), then farther riders with a feasible aligned route (tier 2), then nearby feasible riders without alignment. Only one rider represents each invited company. A rider with six assigned, unfinished parcels is ineligible for a seventh; parcels already in transit still count. Existing bids retain their original window.

Routine delay to an existing parcel is measured for diagnostics but does not disqualify or rank an otherwise feasible rider. Explicit delivery deadlines and the pickup ETA limit still apply. The rider's own `full` setting can stop invitations sooner than six parcels.

This is a bounded candidate search, so it does not prove the globally best rider among all online riders. The road API quota is capped in the database. If road scoring fails or the quota is exhausted, the matching stage falls back to eligible nearby riders; no distant rider is invited merely because its straight-line route looks useful. A cron fallback resolves a matching stage left open for more than 45 seconds. Distant riders are rechecked for fresh GPS, active access and a committed next stop near pickup when their company bids and when paid assignment occurs. A selected company with no eligible rider still requires the existing paid-booking resolution workflow. The untested real-traffic cost and ETA claims below remain design targets, not verified production results.

## Execution pseudocode

```text
on_request_ready(request):
    validate_request_and_location(request)
    riders = spatial_candidates_near_pickup(request, bounded_limit)
           union riders_whose_committed_next_stops_reach_pickup(request, bounded_limit)
    riders = filter_active_not_full_company_pickup_guard_and_location(riders)
    for rider in riders, bounded_parallelism:
        plan = load_committed_plan(rider)
        matrix = road_matrix_or_safe_degraded_mode(rider, plan, request)
        proposal = best_feasible_insertion(plan, request, matrix)
        if proposal exists: score_and_tier(proposal)
    invite_at_most_one_best_rider_per_company(up_to_50, one_minute_window)
    if none: enqueue_bounded_retry_and_explain_wait_to_customer()

on_customer_selection_and_verified_payment(request, company, payment):
    assert selected_bid_belongs_to_company_and_payment_is_verified(payment)
    lock_request_and_company_candidates_in_stable_order()
    for rider in ranked_company_candidates:
        lock_rider_row(); reload_load_state_presence_pickup_guard_job_status_and_plan_version()
        proposal = recompute_feasible_insertion_using_fresh_state()
        if proposal feasible:
            atomically assign_job_once_and_commit_incremented_plan_version()
            append_decision_audit(); publish_next_stop(); return success
    transition_to_controlled_failed_award_or_requote_with_payment_reconciliation()

on_material_event(rider, event_id):
    enqueue_idempotently(rider, event_id)
    worker locks_rider_and_latest_plan_version()
    discard_completed_stops(); refresh_current_load_and_commitments()
    candidate = optimize_remaining_stops_with_budget()
    if candidate feasible and (old infeasible or materially_better(candidate, old)):
        compare_and_swap_plan_version(); audit_change(); publish_new_next_stop()

on_pickup_code_or_delivery_confirmation(job):
    verify_existing_custody_rule_atomically(); update_stop_state_once()
    enqueue_replan_for_assigned_rider(); update_customer_eta_from_committed_plan()
```

Use a unique `(request_id, company_id)` invitation key, one selected bid, one active rider assignment per job, idempotent worker events, and transaction-level row locks or compare-and-swap route versions. Lock rider rows in stable UUID order for multi-rider transfers. Payment and custody functions remain the only transitions that unlock pickup and completion. An assignment retry must first read the committed result; it must not create a second job, debit, invitation, or payout.

## Worked examples

All times below are illustrative **road ETAs**, not promises derived from the current app.

| Scenario | Feasible candidates and effect | Decision |
| --- | --- | --- |
| Nearby and aligned | Rider A is 4 min from pickup and already going toward its drop-off; insertion adds 3 min and delays an existing delivery by 2 min. Idle B is 2 min away but adds 18 min of empty driving. | A is tier 1 and wins if both meet the pickup promise; B wins if A's pickup ETA breaches it. |
| Farther rider approaching pickup | A is 3 km away but will finish a committed drop-off 2 min from the new pickup in 7 min, then travel to the matching destination. Nearby B can arrive in 5 min but would make a separate 9 km trip. | A is tier 2 only if its 7-minute projected pickup and all existing commitments are acceptable; otherwise B wins. |
| New useful route | A can detour 4 min to pick up and then deliver after its current parcel with no deadline violation. No aligned rider exists. | A is tier 3; future demand contributes no benefit. |
| Drop-off along a route | Current road itinerary is A -> D. New pickup is 3 min away and drop-off C lies on the road to D; insertion adds 2 min. A geographically close point across a river would add 25 min. | The first is tier 1; the across-river case is rejected or ranked lower after road routing. |
| Competing orders | Two requests seek the same rider while the rider still reports available space. Both optimization workers read version 8. | The first transaction commits version 9. The other retries against version 9, chooses another rider or surfaces an assignment issue; it cannot overwrite the first route. Physical fit remains the company's and rider's decision. |

## Failure and safety behavior

- **Poor/stale GPS:** Exclude fixes older than two minutes or outside the accepted accuracy rule from automatic invitations. Ask the rider to refresh location. Search/saved-address coordinates carry their source and uncertainty; require customer confirmation and conservative ETA handling.
- **Road service outage/quota:** Serve cached recent matrices if valid. For an idle rider with no committed stops, offer a degraded approximate pickup ranking clearly marked as such; do not stack or resequence active jobs. Queue a short retry and cap provider calls per request.
- **No suitable rider:** Keep the request waiting with a bounded retry and visible status. Do not create a paid assignment with no feasible rider. Re-open bidding only under the existing quote-window rules; do not extend the one-minute deadline silently.
- **Rider offline, lost device, or failed pickup:** Freeze the last committed route, stop offering new work, and trigger controlled reassignment of uncollected jobs within the chosen company. Goods already in custody require a documented physical handoff and custody verification; never merely move their database assignment to another rider.
- **Traffic/deadline conflict:** Protect accepted commitments first; if all plans breach them, surface an exception and revised ETA instead of silently changing a promise. Route changes cannot override an active handoff or safety instructions.
- **Unknown box capacity:** Do not infer a physical fit from order count, weight, or dimensions alone. The rider declares load state, and the company decides whether the shown parcel fits before bidding.
- **Rider marks almost full:** Keep invitations enabled, display the red warning and parcel details on the company bid screen, and require the company to confirm fit if it bids. Do not present this as a measured capacity percentage.
- **Rider marks full:** Stop new invitations and assignments immediately, including pending-award revalidation, but continue GPS reports, customer tracking, next-stop instructions, and custody for existing jobs. Do not automatically clear the rider's full state when a parcel is delivered.
- **Location privacy:** Company receives only its invited pickup details; rider receives only assigned stops; customer receives only the existing restricted tracking view. Keep current location ephemeral and log scored decision factors rather than a GPS trail.

## Performance, rollout, and tests

Use the existing GiST index on `rider_presence.position`, a fresh-presence partial/partner index, indexed future stops, and a spatial search radius with a bounded top-K. Replan only riders touched by a job or material event. Cache road legs, batch matrix requests, cap per-request candidates and optimization time, and enqueue overflow. A bounded worker queue with dead-letter/retry state is preferable to expensive optimization inside a database trigger. At 1,000 riders, the planner should query tens of candidates per request, not every rider; load testing should use synthetic/local data rather than high-volume traffic on the free production database.

The load-state and route-planning stages are active. New requests use route-aware invitations with a bounded candidate set; an outage falls back to nearby riders. Existing open bids and paid jobs keep their original terms. Candidate limits, provider cost, actual ETA quality, and paid-booking resolution still need measured production validation before nationwide scale.

Test the pure planner with deterministic matrices: all five examples above; pickup-before-drop-off; goods already aboard; deadlines; ambiguous coordinates; along-route versus across-river; idle fallback; stable tie breaks; hysteresis; route-provider failure; stale GPS; and completion removing stops. Test SQL concurrency with simultaneous awards, stale plan versions, duplicate queue events, rider revocation, unavailable rider, company permission failures, a rider marking full during bidding or just before paid-award revalidation, and no automatic return to accepting work after delivery. End-to-end tests must prove the company gets the bid, the customer chooses/pays, the invited rider receives the job or same-company fallback, codes advance custody, and only the assigned rider sees next-stop instructions. They must also prove **On duty · Full** stops new orders without stopping GPS updates, existing route instructions, or customer tracking; **Almost full** keeps the invitation eligible and visibly warns the company in red before its bid; and returning to **Available** resumes matching only when GPS is fresh. Do not change current live invitations until these pass.

Track pickup-wait p50/p90/p95, on-time pickup/delivery rates, extra kilometres and minutes per job, empty kilometres, rider active/idle time, route changes per job, customer ETA error, failed or reversed assignments, cost per routed job, matrix cache hit rate, and planner p95 latency. Compare with a nearest-rider baseline in shadow mode and by controlled cohorts. Launch gates should include no increase in missed commitments or double assignments, a measurable reduction in pickup wait/empty kilometres, and stable provider spend under a defined daily budget; exact numerical targets require baseline data.
