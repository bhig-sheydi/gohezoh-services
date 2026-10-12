# Port Harcourt hub handoff

Deliveries arriving from another city use one customer order and one billed job. Gohezoh staff record the parcel scan, condition, receiving warehouse and custody time. Operations then assigns a numbered last-mile leg to an active partner approved for Port Harcourt local delivery. The inbound partner assignment is completed, and the new assignment and handoff are audited. The recipient OTP is issued only after the last-mile partner accepts and the job reaches out-for-delivery; the same job is marked delivered once the final OTP is verified.

Before the customer quote is sent, Operations must ensure the last-mile partner cost is included in the original eligible partner bid or entered as a separate `other_direct_cost_ngn`. Do not count it twice. The customer price is calculated from total eligible direct cost using the approved pricing policy. If the last-mile cost is unknown, hold the quote for review; a later unpriced leg can erode the required 25% contribution margin.

The last-mile leg has a `PHL-` reference for internal custody tracking. It is not a second customer order, customer charge or independent delivery job.
