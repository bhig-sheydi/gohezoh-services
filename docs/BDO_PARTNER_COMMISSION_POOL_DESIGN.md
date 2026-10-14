# BDO and Marketer Customer/Partner Commission Design

## Policy captured from the latest instruction

The 25% figure is Gohezo's modeled contribution/margin, not a commission rate.
Commission is calculated from actual reconciled job contribution after eligible
direct costs and qualifying customer funds are recorded. It is earned only for
completed work with collected funds, consistent with the corrective
specification. No commission is calculated from an estimate or an uncollected
quote.

- If only BDOs are eligible on a job, the pool is 10% of positive, reconciled
  contribution, split equally among unique eligible BDOs.
- If a marketer is involved, release at most 15% of contribution across two
  role budgets: 10% shared equally among unique eligible marketers and 5%
  shared equally among unique eligible BDOs. Eligible BDOs include direct
  customer/partner referrers and the sponsoring BDOs of involved marketers.
- If a marketer is involved but no eligible BDO can be verified, do not
  release the unallocated BDO budget; hold it for Management review.
- Count a person once within their role even if they sourced the customer and
  multiple partners. If a person qualifies as both a marketer and BDO, preserve
  both roles only when each role is independently approved; otherwise hold for
  review. Allocate any remaining kobo deterministically so each role budget
  reconciles exactly.
- Pricing remains a separate decision. “No caps on pricing” does not increase
  commission beyond the defined share of reconciled positive contribution.

The owner confirmed the role-specific split: marketer 10%, sponsoring/direct
BDOs 5% when marketers are involved. “Equal split” therefore means equal shares
among eligible people inside each role budget; it does not replace the 10/5
role split. Without marketers, the BDOs divide the 10% BDO-only budget.

## Current implementation findings

- Customer signup attribution is captured in `customer_referral_intents` and
  copied to `customers.assigned_bdo_id` and, for marketer links,
  `customers.referred_by_marketer_id`.
- The BDO workspace lists customers assigned to that BDO, but rows do not show
  per-customer earned commission. `BdoTransparencyPanel` shows transaction
  ledger rows without customer identity.
- Direct BDO commissions, marketer commissions, and the supervising BDO's
  marketer share are separate ledgers. Their idempotency keys are local to
  each ledger, so they do not enforce one shared job-level maximum.
- Current direct BDO and marketer accruals use different bases; the BDO
  marketer share uses accepted-quote contribution. They do not consistently
  use final reconciled actual contribution, and partner acquisition is not
  wired into their accrual.
- BDOs can create partner prospects and invite partner applicants. Marketers
  currently have customer referral links but no partner-recruitment flow.
- `partner_attributions` supports Management-approved BDO ownership, but
  partner signup approval does not automatically create that record, and the
  accrual functions do not consume it.
- A job has one `partner_id`; `partner_assignments` permits one open assignment
  per job. The schema cannot reliably represent an interstate carrier and a
  last-mile rider as separately attributed, costed legs of the same job.
- In the linked database checked on 2026-10-13, commission plans, partner
  attributions, converted partner prospects, and commission ledger rows were
  empty. No existing payout rows need conversion in this project at present.

## Scenario rules

Let `P` be the final positive contribution for a fully collected, completed
job after refunds and eligible direct costs are reconciled. Let `M` be unique
eligible marketers who sourced the customer or a performing partner. Let `B`
be unique eligible direct BDO referrers plus the supervising BDOs for marketers
in `M`. If `M` is empty, divide `10% * P` equally among `B`. Otherwise divide
`10% * P` equally among `M` and `5% * P` equally among `B`. Never create a
separate pool for each customer, partner, or transport leg.

| Scenario | Recipients | Pool and allocation |
|---|---|---|
| No verified referral source | None | No referral pool |
| Customer referred by one BDO; no sourced performing partner | Customer BDO | 10% of P |
| Customer referred by two people due to conflicting links | Hold disputed role share | No payout until Management resolves attribution |
| Customer BDO and one partner BDO are different; no marketer | Both BDOs | 10% of P split equally |
| Same BDO sourced customer and performing partner | That BDO once | 10% of P |
| Customer referred by marketer; no other sourced partner | Marketer and sponsoring BDO | Marketer gets 10% of P; BDO gets 5% |
| Customer marketer plus partner sourced by a different BDO | Customer marketer, its sponsor BDO, partner BDO | 10% of P to marketer; 5% split equally across the two BDOs |
| Customer BDO plus partner marketer | Customer BDO, partner marketer, marketer's sponsor BDO | 10% of P to marketer; 5% split equally across the two BDOs |
| Customer and partner sourced by different marketers | Each marketer and each distinct sponsor BDO | 10% split among marketers; 5% split among unique BDOs |
| One marketer sourced customer and multiple partner legs | Marketer and sponsor BDO once each | 10% to marketer; 5% to BDO, one job-level allocation |
| Same BDO sponsored two involved marketers | Two marketers and that BDO once | 10% split equally among marketers; 5% to BDO |
| One person is both a direct referrer and a marketer's sponsor | That BDO once in BDO budget | One 15% total; role budgets remain 10% marketer / 5% BDO |
| Partner was referred but did not perform a leg | Exclude that partner's referrer | Only customer and actual performing-partner sources qualify |
| Partner is unapproved, job incomplete, or customer charge unpaid | No payout yet | Pending or zero until all eligibility conditions pass |
| Completed job is refunded or cost adjustment changes contribution | Existing recipients receive proportional negative/positive adjustments | Preserve original rows and link adjustments; do not silently rewrite |
| Multiple legs, reassignment, or partial payment | Unique sources across final performing legs | One job-level pool based on reconciled job economics, not one pool per leg/payment callback |

Any additional number of partner legs follows the same rule: each final
performing partner contributes its approved source to `R`; repeated people are
deduplicated. Disputed, missing, self-referred, or changed attribution is
flagged for Management rather than guessed. If final contribution is zero or
negative, no positive commission is available; recovery of a previously paid
commission follows the approved agreement and ledger adjustment process.

## Likely confusion and loss cases to prevent

- Confusing 25% margin with a commission rate or applying 10%/5% to customer
  charges instead of contribution.
- Using quote-based contribution when final costs, refunds, discounts, or
  payment fees change the actual result.
- Paying the old direct-BDO, marketer, and supervisor-share ledgers in
  addition to a new unified pool for the same job.
- Treating role budgets as per-person rates, or applying 10%/5% once per
  marketer/partner instead of once per job and splitting within each role.
- Including a marketer's supervisor without a clear policy, or failing to
  deduplicate a person who appears in multiple roles.
- Creating multiple full pools for an interstate carrier, local rider,
  warehouse, and customer referrer on one order.
- Paying a partner's referrer when that partner was merely registered but did
  not perform the relevant leg.
- Paying on a quote, assignment, incomplete/canceled delivery, unapproved
  partner, unpaid balance, duplicate callback, or refunded transaction.
- Rebinding referral ownership, self-referrals, duplicate accounts, or
  competing BDO/marketer claims without Management review and an audit reason.
- Losing money through omitted/double-counted leg costs, inconsistent charge
  components, multi-currency totals, rounding, or paying before reconciliation.
- Exposing one BDO's customers or earnings to another BDO or to a partner.

## Implementation sequence

1. Record the confirmed marketer/BDO split in a versioned policy with
   its contribution definition, eligibility events, participant rules,
   rounding, reversals, and effective date.
2. Add immutable partner referral links/attributions for BDOs and marketers;
   finalize only after Super Admin partner approval. Preserve old attribution
   history and require Management approval for corrections.
3. Represent each operational job leg with its selected partner, service role,
   accepted quote, and actual cost. Backfill old single-partner jobs as one
   leg; do not invent historical legs.
4. Add one idempotent job-level pool and allocation ledger. Reconcile collected
   payments and final costs, support reversals, deduplicate recipients, and
   ensure allocations sum to exactly the approved pool.
5. Stop future accrual from the old independent ledgers for the effective
   policy period. Keep prior entries read-only; do not delete or recalculate
   historical payout rows.
6. Add narrow server-side BDO/marketer views showing each authorized customer
   or sourced partner, completed qualifying work, collected amount, their own
   commission, and pending/approved/paid/adjusted status. Do not disclose other
   referrers' earnings or partners' confidential data.
7. Add compact portal summaries and downloadable statements that show the
   basis, split, policy version, job status, and adjustment history.

## Acceptance tests

Cover every row in the scenario table, including arbitrary partner-leg counts;
same person in multiple roles; marketer/supervisor combinations; distinct
BDOs and marketers; disputed attribution; unapproved or non-performing
partners; and cent remainders. Also test partial collections, concurrent and
duplicate callbacks, cancellation, refund before/after payout, post-completion
cost adjustments, policy version boundaries, and cross-BDO privacy. Assert
that there is at most one pool per job/policy and that allocations plus
adjustments reconcile exactly to it. Assert no legacy ledger also accrues for
that job after cutover.

## Corrective specification alignment

This design follows the BDO visibility, approved partner attribution,
transaction-linked ledger, privacy, collected-funds, reversal, and
versioned-policy requirements in pages 6-8 of the corrective developer
specification. This newer explicit commission direction should be recorded as
a Management-approved policy version before deployment; historical examples
in the specification do not silently override it.
