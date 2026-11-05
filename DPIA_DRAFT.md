# Draft data privacy impact assessment — Kwik-Parsel

**Status:** Working draft for Gohezoh Integrated Services Ltd and qualified Nigerian privacy counsel/DPO. It is not an approval or a filed assessment.

## Processing and necessity

Partner onboarding collects company papers, owner NIN and face image, vehicle/driver identity evidence. This aims to reduce impersonation and unsafe dispatch. Rider location supports proximity matching, active delivery tracking and authorized safety requests. Customer delivery data includes sender/recipient contact details, addresses and parcel photos. Payments and payouts use external processors. The least data needed for these tasks should be collected; a camera image is not a biometric liveness or NIMC verification result.

## People affected and access

Company owners, riders, customers, recipients, staff and referrers. Super Admin reviewers see identity evidence. Approved companies see their own rider and assigned-job data. Customers see limited rider data for paid active jobs. Payment, map, messaging and cloud providers receive only data needed for their service. Access policies must be tested after every schema change.

## Main risks and controls

| Risk | Current control | Further action |
| --- | --- | --- |
| NIN/face evidence exposed | Private storage, RLS, admin-only review | Review access logs; verify backup retention and file deletion |
| False owner identity | Live camera capture and manual Super Admin review | Do not describe NIN as verified; consider an authorized identity-verification provider if needed |
| Rider location used beyond delivery/safety | On-duty updates, off-duty on-demand checks, active-customer limits and native disclosure | Physical-device review, access audit and Play permission approval |
| Old evidence retained without purpose | Unlinked files older than 30 days can be removed by admin maintenance function | Schedule and monitor cleanup; define retention for approved applications |
| Account deletion incomplete | In-app/web request path and admin queue | Complete each request, remove data not legally required, document retained records and reply to requester |
| Third-party or cross-border transfer | Named providers in privacy policy | Review contracts, hosting regions, international transfer basis and provider subprocessors |

## Decisions required before public release

1. Confirm lawful bases and exact retention periods for identity, delivery, finance and location data.
2. Decide whether the organisation must register as a data controller/processor of major importance and appoint a DPO.
3. Approve a deletion procedure that handles live jobs, payouts, disputes and statutory records, including response time and audit trail.
4. Complete and sign the DPIA, record residual risks and any required consultation with the Nigeria Data Protection Commission.

Reference: [Nigeria Data Protection Act 2023](https://ndpc.gov.ng/wp-content/uploads/2024/03/Nigeria_Data_Protection_Act_2023.pdf) and [NDPC GAID 2025](https://ndpc.gov.ng/wp-content/uploads/2025/03/NDP-ACT-GAID-2025-MARCH-20TH.pdf).
