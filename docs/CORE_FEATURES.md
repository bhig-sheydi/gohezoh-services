# Kwik-Parsel Core Features

This is the ordered customer-and-partner product scope for local and interstate goods transportation. Detailed requirements and acceptance checks are in [RENOVATION_SPEC.md](RENOVATION_SPEC.md). It reflects the latest decision: Gohezo withholds a 20% platform fee from eligible partner transport earnings; it does not add that fee to the customer's quote.

## Build order

1. **Route availability:** Customer selects local or interstate service, then only enabled origin/destination corridors. Backend rejects disabled routes. Umuahia route pairs are explicit.
2. **Shipment request:** Collect pickup/drop-off details, parcel type, known dimensions and weight, quantity, timing, and handling needs; return a request reference.
2a. **Customer saved parcels and focused workspaces:** Let standalone customer accounts save photographed, frequently sent items with declared worth, price paid, dimensions, and weight; choose one to prefill a request and select 1–50 matching items for one destination. Warn as soon as the selected count exceeds the estimated capacity, combining item weight and a rotatable regular-grid size estimate. Keep Parcel Pals prominent, and open Send items, Updates, and Tracking as separate customer app frames. Enforce a packed shipment cap of 99 × 60 × 70.5 cm and 9.9 kg (three times the researched 33 × 20 × 23.5 cm, 3.3 kg reference carton) until carrier-specific tiers are defined.
2b. **Parcel Pal delivery destinations:** Customer accounts may save up to three destinations (Work, Home, Other), each with address, city, state, and an optional alternate phone. Open the editor from **Edit my delivery info**; keep address forms hidden until opened. **Get address** explicitly requests device permission and bounded high-accuracy readings. Reverse geocoding uses an authenticated server proxy with a server-only Geoapify key. No map is shown. Fill all available fields, including area-only results and coarse readings, then allow manual correction. Never invent missing details. Keep copy brief and support dark mode. Device accuracy, result specificity, provider distance and optional confidence are evaluated separately; no IP fallback or guaranteed building accuracy is claimed. Coarse readings, denied permission and API failures preserve manual entry. Require review of suggested addresses before saving. Precise coordinates/accuracy/timestamps are transient edit-session evidence; only confirmed address text is persisted. See [Location detection](LOCATION_DETECTION.md) for documented API capabilities, quotas, error handling, privacy and deployment checks. Only accepted Parcel Pals can see saved address details. Choosing one from a connected pal prefills recipient name, primary phone, alternate phone, and destination. The sender must confirm with the recipient that the destination is correct before submitting. Require a primary customer phone at signup.
3. **Partner matching:** Invite only approved partners eligible for the corridor, service, and capacity.
4. **Confidential two-hour bidding:** Partners submit their price, availability, estimated timing, inclusions, exclusions, and declared surcharges. They cannot see competing bids.
5. **Lowest-valid-quote selection:** Close bidding server-side; select the lowest valid quote. Preserve audit details and send no-bid, tie, or declined-winner cases to a defined fallback.
6. **Transparent customer quote:** Show the selected transport price and terms. Do not append a separate 20% platform fee to the customer charge. Requote and get renewed acceptance if material shipment details change.
7. **Partner fee preview:** Disclose that Gohezo retains 20% of the accepted and collected eligible transport charge from partner settlement. Show partner gross, fee, and net before award acceptance. Calculate once per eligible performed leg.
8. **Customer acceptance and confirmed award:** Require acceptance and required payment or approved credit before awarding the job; require partner confirmation and handle declined/expired awards.
9. **Shipment tracking and custody:** Show accurate customer milestones and record partner handoffs, scans, condition, and timestamps.
10. **Port Harcourt inbound flow:** Require Gohezo hub receipt and linked last-mile delivery for Port Harcourt-bound shipments, subject only to an audited authorized exception.
11. **Verified delivery:** Use recipient OTP for configured jobs, with server-side expiry/attempt checks and proof of delivery. Do not mark complete from a button or photo alone.
12. **Exceptions and financial reconciliation:** Handle delays, failed handoffs, cancellation, refunds, and quote changes. Reconcile customer collections, per-leg platform fee, partner net payable, and settlement history.
13. **Partner workspace:** Give partners their own opportunities, bids, assignments, delivery actions, fee calculations, and settlement status while keeping other partners' data private.
14. **Gohezo fulfillment add-on:** Add owned-warehouse inventory, storage, processing, picking, packing, and dispatch after the transportation flow is reliable; quote and accept applicable fees separately.
15. **Expand by configuration:** Add corridors, service classes, partner capacity options, and parcel size/weight tiers without redesigning the core booking flow.

## Commercial rule

For an eligible leg with NGN 100,000 accepted and collected, Gohezo's fee is NGN 20,000 and partner net is NGN 80,000 before separately agreed adjustments. The partner sets a customer-facing bid knowing the fee will be withheld. The customer sees the accepted quote; there is no extra 20% customer fee. This is distinct from BDO/marketer referral commissions and warehouse fees. The prior `eligible direct cost / 0.75` price formula does not apply to driver transport under this policy.

## Release gates

- **P0:** Features 1–12; server-side coverage, bid selection, quote acceptance, fee ledger, hub/custody rules, OTP, and financial reconciliation must pass their acceptance tests.
- **P1:** Features 13–14; partner self-service and Gohezo-owned warehouse fulfillment.
- **P2:** Feature 15; coverage and service expansion after the configured launch corridors operate reliably.
