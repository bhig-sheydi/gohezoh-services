# Proof of delivery

After recipient OTP verification marks a job delivered, the completed partner can upload one clear delivery photo from the Partner portal. The private `proof-of-delivery` bucket accepts JPEG, PNG, or WebP images up to 5 MB. The app stores the object's path and basic evidence metadata in `proof_of_delivery`; it removes an uploaded object if saving that metadata fails.

Storage policies restrict uploads to Operations or the completed partner assigned to a delivered job. Customers, the assigned partner, Operations, and management can read proof metadata and objects through short-lived signed links. Unrelated users have no access.

The database regression test verifies customer/partner/Operations access, rejects an unrelated account, checks malformed object paths, and confirms the bucket is private. The UI tests cover partner upload and customer link display. See `docs/DELIVERY_OTP.md` for the preceding recipient-confirmation step and its SMS provider setup.
