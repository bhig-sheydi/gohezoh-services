# Business Development and Leads

Phase 6 provides an assigned prospect pipeline for Business Development Officers. Leads move through Lead, Qualified, Opportunity, Proposal, Won, or Lost. A lead can become a customer only through the conversion function, which creates the customer record and assigns it to the originating BDO. Every initial stage and subsequent stage change, including conversion, is recorded in an append-only history with the previous stage, new stage, actor, and time. BDOs can read only the histories of leads currently assigned to them.

BDOs can record calls, emails, meetings, site visits, proposals, follow-ups, and other interactions against assigned leads, customers, or partner prospects. Partner development remains separate from the operational logistics-partner directory. BDOs can mark a prospect ready for review; only Management or Admin can approve it into the operational partner directory, where it starts with Pending status.

The BDO dashboard shows assigned open leads, due follow-ups, meetings and activities this week, proposals, won opportunities/value, assigned customers, and partner prospects. Weekly reports snapshot lead creation, meetings, proposals, wins, and partner prospects for a chosen completed period.

RLS and database functions enforce assignment, stage transitions, conversion, activity ownership, and partner approval. The BDO role has no grants or policies for finance settlements. BDOs cannot change delivery execution, commit pricing, or activate an operational partner. See `20261002090000_add_bdo_role.sql`, `20261002100000_business_development.sql`, and `business_development.test.sql`.
