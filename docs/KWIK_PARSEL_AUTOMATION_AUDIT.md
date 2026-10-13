# Kwik-Parsel automation audit

Kwik-Parsel is the customer-facing logistics and fulfillment product by Gohezo Integrated Services. This audit tracks shipped workflows and remaining automation work.

## Architecture found

- React 19 and TypeScript frontend, built with Vite.
- Supabase Auth, Postgres, row-level security, security-definer RPCs, private Storage, and an Edge Function for delivery OTP/SMS integration.
- Database migrations and rollback-based SQL integration tests live under `supabase/`.
- The browser and future WebView GPS bridge is in `src/lib/proximity.ts`.
- No Paystack integration or external customer messaging provider is configured. Finance receipts and partner settlements are recorded manually; email confirmation and password reset use Supabase Auth. A private durable job queue currently handles quote-window expiry.

## Working flows already present

- Customer accounts, delivery requests, Operations review, partner quotes, customer quote approval, orders, jobs, partner assignment, delivery status, recipient OTP, private proof-of-delivery storage, and in-app notifications.
- Partner assignment and route controls, including the Port Harcourt hub handoff flow.
- Warehouse inventory intake, fulfillment orders, picking, and handoff to Operations.
- Finance job-cost, customer-receipt, and settlement records; these are manual ledger operations.
- Staff applications and Super Admin role approval/revocation; partners are scoped through partner-user membership.
- BDO lead and partner-prospect pipelines, captured partner GPS, lead conversion, and `customers.assigned_bdo_id` attribution for manually converted leads.

## Implemented in this change

- Customer-facing brand text, page metadata, and favicon now use **Kwik-Parsel**, with the Gohezo Integrated Services product credit visible in the app.
- Approved BDOs receive a stable referral code through a protected database function and see a personal referral link in their workspace.
- Customer signup captures and validates the referral once in a private database record at account creation, then links the customer to the referring BDO after email confirmation. Later auth-metadata edits cannot redirect or add attribution.
- New customer profiles are created from signup name, phone, email, and optional business name. Customers no longer need to re-enter those details on a separate profile form. Existing accounts without a phone are asked only for the missing phone and optional business name.
- Profile creation is retry-safe, preserves existing attribution, rejects self-referral for credit, and prevents customers from changing their BDO attribution directly.
- BDOs can create email-bound, 14-day, one-use marketer invitation links. Marketer registration requires the invitation, matching email, email confirmation, and Super Admin approval.
- Approved marketers receive a separate customer referral link. Customer signup attribution records both the marketer and supervising BDO; marketers see their aggregate referred-customer count and their own commission ledger, without customer data access.
- Super Admin revocation removes marketer access and disables further referral attribution and marketer commission viewing.
- Partner companies now have company-scoped team membership roles. The first Super Admin-approved portal member becomes company manager; managers can create email-bound invitations for staff, dispatchers, and riders, and can cancel unclaimed invitations. New partner applicants must still submit NIN/CAC documents and receive Super Admin approval before company membership is granted. Invitation tokens are stored hashed and may only be claimed by the matching confirmed email.
- Management/Admin can approve versioned marketer plans with signed-agreement references, rates, effective dates, and eligible services. Deployed migrations accrue a separate marketer entry for each eligible Finance-recorded NGN receipt on a completed accepted-quote delivery; receipt reversals create negative adjustment entries.
- Management and Admin can review existing BDO commission plans and approve a versioned plan with a signed-agreement reference, calculation basis, effective date, and eligible local/interstate delivery categories. This configuration does not create commissions or mark payouts as due.
- A deployed migration defines direct-BDO commission accrual once per Finance-recorded NGN receipt when its customer has a direct BDO attribution, the accepted-quote delivery is completed, and the BDO has an effective `collected_revenue` plan covering that service. Receipt reversals create an auditable negative adjustment. Lead opportunity estimates are never read by commission calculations.
- The supervising BDO's separate share of marketer-referred sales uses a separately approved signed rate against the accepted quote's recorded contribution, prorated across receipts. The BDO view and commission statement include this ledger.
- Management/Admin can approve or decline each calculated commission. Finance/Management/Admin can record completed transfer batches by actual bank reference; batches cannot mix recipients or commission types, and the approver cannot record the payout. BDOs and marketers can view their recorded payout history.
- Management/Admin can approve future-commission offsets only for reversals of previously paid commissions. Finance records gross earnings, the applied offset, and cash paid as separate auditable amounts; fully offset batches do not claim that a bank transfer occurred.
- Durable backend jobs now use private, idempotent queue records with bounded retries, exponential backoff, and dead-letter status. Quote-window expiry is enqueued transactionally when a window is published or reopened; stale expiry work is cancelled, and a one-minute `pg_cron` worker processes due jobs without requiring a browser session.
- Newly reported delivery exceptions now create auditable in-app alerts for Operations, Management, and Admin. Distinct exception events generate distinct alerts; customers do not receive internal escalation notices.
- Warehouse staff can print a per-order pick manifest with the fulfillment reference, customer and delivery details, warehouse, SKU, bin, required/picked quantities, and picker/checker sign-off fields.
- Each job parcel row receives a permanent `KWP-P-########` identifier. Customers and assigned partner staff can view its dependency-free Code 39 label; partner staff can type or barcode-scan the code into a lookup field, and labels can be printed from the shipment view. A parcel-row code identifies that parcel; `quantity` continues to mean items inside it.
- Partner managers and dispatchers can assign accepted jobs to a company rider before pickup. The database serializes capacity checks per rider and rejects a sixth active pickup; pickup capacity opens when a job moves into transit or is completed/cancelled. Only the assigned rider can update that rider's job progress.

## Remaining automation gaps, in implementation order

1. **Commission accrual and payout workflow:** Direct-BDO, marketer, and supervising-BDO share accrual, review, manual payout recording, and approved recovery offsets are deployed. Automated transfers, automated qualification rules, and additional calculation bases remain incomplete. There is no payment gateway. Lead opportunity estimates must never feed commission or profit calculations.
2. **Partner organizations:** Company-scoped manager and staff invitations are deployed. Invitation links are created in-app for managers to share; outbound invitation email, company-level performance reports, and delegated manager promotion remain future work. Super Admin continues to approve partner identity documents and controls access revocation.
3. **Durable jobs and external messaging:** The queue foundation and durable quote-window expiry are deployed. Reminder delivery, route discovery, automated billing/settlement jobs, and external email/SMS dispatch remain incomplete. No external message is marked sent by this queue; configure a provider and recipient consent before adding message handlers.
4. **Operational controls:** Exception escalation, printable picking manifests, Code 39 parcel labels with partner lookup, and five-active-pickup rider enforcement are implemented.
5. **Billing and policy workflows:** Paystack verification/refunds require provider credentials and approved refund rules. Automated fulfillment storage invoices require approved rates, billing cadence, and eligibility/exemption settings. Historical quote versioning across all change cases and document-consolidation rules remain incomplete. Commission receipt reversals and approved recovery offsets are already recorded as auditable negative commission entries; they do not automate bank reversals.

Human review remains appropriate for partner verification, BDO approval, exceptions, disputes, and changes that affect an agreed price or custody of goods. Customer-facing statuses should remain accurate while partner operations and commercial records stay scoped to authorized users.

## Verification and deployment state

- Linked database migrations `20261013270000` through `20261013290000` add parcel identifiers, rider capacity enforcement, and a correction that scopes the rider requirement to partner-accepted jobs. They are applied to project `yejiqfocqmdxjeajoexd`.
- Frontend suite passed (65 tests); lint and production build passed. The full linked SQL integration suite passed, including parcel tracking, rider capacity, partner assignment, hub handoff, and exception escalation tests. Integration test rows are rolled back.
- The two operational-control features are deployed to Supabase. Frontend hosting was not changed.
