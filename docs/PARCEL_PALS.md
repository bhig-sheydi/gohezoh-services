# Parcel Pals

## User flow

1. Only a standalone customer account receives a stable, unique six-digit Parcel Pal number. Other roles do not receive the number or see the Parcel Pals interface.
2. A signed-in customer searches for another confirmed customer by its exact six-digit number and sends a request.
3. Search results and outgoing requests reveal only the six-digit number and request state. An incoming request shows the sender's display name and profile picture so the recipient can recognize who is asking; phone and address remain hidden.
4. The recipient can accept or decline. Only acceptance creates the connection and makes the two accounts' shared contact information available to each other.
5. Accepted contacts may see the other user's name and profile picture, primary phone, and up to three preferred delivery locations (Work, Home, Other). Each location can include an alternate phone number. These destinations remain hidden before acceptance; job-specific delivery details are still controlled by the job's permissions.
6. A customer chooses **Use this destination** on a connected Parcel Pal to prefill recipient name, primary phone, address, city, state and alternate number in Send items. The sender must explicitly confirm that the recipient agreed to the delivery location before submitting a request.
7. Customers can upload a JPEG, PNG or WebP profile photo up to 5 MB. Recommend a business logo or clear face photo. The private photo remains unreadable outside the customer owner, accepted contacts, and the recipient of an incoming request.
8. Customers without a photo are prompted on each app open. Dismissing the prompt hides it for that app session; it returns on the next open until a photo is saved.
9. When an account gains any non-customer role, its Parcel Pal number and profile-photo reference are cleared. Existing private Storage objects are not deleted by SQL; removal must use the Supabase Storage API.

## Database security

- Six-digit numbers are stored in a private table with unique constraints. Only accounts whose sole role is `customer` can receive or use a number. Clients cannot list or modify code records.
- Connection requests are stored by unordered user pair so duplicate and reverse-direction requests cannot create parallel relationships.
- Search, request, response, request-list, and accepted-contact operations use authenticated database functions. Raw connection rows and code mappings are not directly readable or writable by client roles.
- The search function returns only a code, found flag, status, and direction. The incoming-request function returns only the sender's name and profile path to the intended recipient. Accepted-contact results add contact details only for accepted pairs.
- Preferred destination reads are included only in the accepted-contact RPC. Customers can modify only their own three rows, protected by RLS and slot checks.
- Photos are held in a private Storage bucket. Storage row-level policies authorize standalone customer owners, a pending request recipient, or an accepted customer Parcel Pal. Each allowed image is delivered with a short-lived signed URL.
- Enforce daily search/request limits to reduce number enumeration and unwanted requests.
- Never use a Parcel Pal number as a password, authorization token, or delivery OTP.

## Acceptance checks

- New standalone customer accounts get exactly one six-digit number; the number remains stable and unique. Existing non-customer accounts do not have a number or Parcel Pal photo reference.
- A user cannot look up their own code or retrieve any other code record directly.
- Search of another code returns no personal fields before acceptance. No pending request does either.
- Only the recipient can accept or decline a pending request. Acceptance makes approved contact fields visible to both parties; decline does not.
- Direct profile and customer-address queries remain blocked by existing row-level security.
- A customer can save, update and remove only the Work, Home and Other destination slots; another user or non-customer role cannot read or write them.
- Choosing a saved destination prefills the send form and recipient confirmation is required before request submission.
- Duplicate requests, reverse-direction requests, self-requests, malformed codes, and daily-limit excess are handled safely.
