# Corrective specification delivery status

Implemented: seven interstate corridors, including Umuahia to Port Harcourt, with controlled coverage; confidential two-hour partner quotes and exception review; customer quote acceptance; payment or approved credit before partner award; Port Harcourt hub custody and same-job last-mile leg; final-leg recipient OTP; warehouse standard fee references; BDO attribution and commission-plan foundations; browser and WebView-native GPS proximity checks without maps. Existing orders keep their previous workflow. A delivery request enters the quote workflow when Operations publishes its bidding window; after publication, conversion requires customer acceptance of the quote.

**Pricing policy update (2026-10-13):** The earlier corrective PDF and prior status text specified customer price as eligible direct cost divided by 0.75. The latest product instruction supersedes that formula for driver transportation: Gohezo retains 20% from the partner's accepted, collected transport charge and pays the partner the remaining 80%, before separately agreed adjustments. The customer quote does not receive a separate 20% add-on. The partner must see and accept the fee terms before bidding/award. This is a new policy direction; this status file does not claim the application/backend implementation has been changed or verified. See [RENOVATION_SPEC.md](RENOVATION_SPEC.md) and [CORE_FEATURES.md](CORE_FEATURES.md).

BDOs can capture partner-site GPS from the device at the premises, with the partner's permission. Coordinates, accuracy and capture time are stored on the partner prospect. Management and Admin reviewers can open the coordinates in Google Maps.

Management decisions required before enabling or extending these parts:

- Set the approved customer-price rounding increment in the Management pricing screen. Until then, a selected partner bid cannot be sent as a final priced quote.
- Specify any additional Umuahia routes. Only Umuahia to Port Harcourt is enabled; the reverse direction remains unchanged.
- Approve an urgent-bid deadline, if a window shorter than two hours is desired.
- Approve a five-item standard-processing cap, a returns fee, and a partial-month storage rule before charging them.
- Approve signed BDO rate and eligibility plans and attribution-conflict rules before automated commission accrual or payout.
- Update and test the existing transport pricing implementation to match the new 20% partner-side fee before using the updated policy for live partner awards. Do not combine it with the superseded `/ 0.75` customer-price formula.
- Decide whether recipient OTP should apply beyond the final Port Harcourt delivery leg.

The ₦1,000 standard-order and ₦2,000 standard-carton/month warehouse rates are stored as reference data; automated warehouse invoicing is not included. BDO plans and ledger records require explicit approval; automated commission calculation is not included. Proximity is an advisory distance check from a single device position, not proof of custody, and the future WebView container must implement the documented native position request/response bridge in `src/lib/proximity.ts`.
