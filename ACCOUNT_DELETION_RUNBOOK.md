# Handling Kwik-Parsel account deletion requests

Super Admin sees requests in **Access control → Account deletion requests**. The public web request path is `/delete-account`; the requester signs in to identify the account. Requests also create an in-app notification for Super Admin.

For each request:

1. Confirm the request belongs to the authenticated account in the queue. Do not act on a forwarded email alone.
2. Check for active deliveries, unpaid/refundable customer charges, unsettled partner withdrawals, disputes and legal holds. Resolve these first and tell the requester what is pending.
3. Export only transaction records that must be retained for a documented accounting, fraud or legal basis. Restrict access to those records and record the retention decision.
4. Remove personal details that are no longer needed, including profile/contact information, saved addresses and parcels, private photos/documents, rider tracking grants and last-known location. Check all storage buckets, not only database rows.
5. Delete the Supabase Auth user after dependent records are handled. A hard delete may be blocked by foreign keys to orders or financial ledgers: do not bypass those constraints by cascading through paid-job records. Anonymize or retain only what has an explicit documented basis.
6. Confirm that sign-in fails, private files cannot be read, and unrelated users' orders remain intact. Reply to the requester and record completion in an internal audit log. Do not leave a request in the queue indefinitely.

This is a manual process because deleting a user with paid deliveries or settlements must preserve transaction integrity. The request UI does **not** claim instant deletion. Before a public Play release, the company must assign an owner and response deadline for this procedure and test it with a real test account.
