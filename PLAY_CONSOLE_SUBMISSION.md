# Kwik-Parsel Google Play submission checklist

Use the actual production build and configuration when answering Play Console forms. Do not submit this document as a declaration without checking the live app.

## Links

- Privacy policy: `https://gohezoh-services.vercel.app/privacy-policy.html`
- External account deletion request: `https://gohezoh-services.vercel.app/delete-account`
- Rider location explanation: `https://gohezoh-services.vercel.app/rider-location-terms.html`

## Data Safety inventory to verify in Play Console

| Data | Purpose | Shared with |
| --- | --- | --- |
| Name, email, phone, role | Accounts, delivery coordination, identity checks | Supabase; assigned logistics company/rider when needed for a job |
| Pickup/delivery addresses and coordinates | Routing, pricing, dispatch, delivery | Assigned logistics company/rider; Google Maps or Geoapify for lookup and routing |
| Rider location, including background | Dispatch, active delivery tracking, company safety requests | Supabase; authorized company; active customer under app limits |
| Parcel descriptions/photos | Booking, handling, claims | Supabase; assigned logistics company/rider |
| NIN, face/ID photos, company and vehicle documents | Partner/rider review and fraud prevention | Supabase; Super Admin reviewers |
| Payment/payout details | Charge customers, pay partners and referrers | Paystack or Flutterwave according to transaction |
| Recipient phone number | Delivery coordination and delivery code | Assigned logistics company/rider and configured messaging provider |

Verify each Play form question for collection, sharing, encryption, deletion, optionality and purpose against the deployed build. In particular, do **not** claim background location is only used while the app is open.

## Background location declaration

The Android manifest requests `ACCESS_BACKGROUND_LOCATION`. The rider flow now has a separate native disclosure before location permission/settings. The Play Console submission still requires its sensitive permission form, a short video showing the disclosure and runtime permission flow, a privacy policy URL, and reviewer credentials for a rider account. Confirm that device tests match the description before submitting.

Suggested plain-language feature description: “Riders report location while on duty so nearby deliveries can reach their company and customers can follow paid active deliveries. Off duty, the app checks for authorized company or active-delivery location requests about hourly and sends a fresh fix only when requested.”

## Review and release evidence still needed

- Run the Android build on CI and test camera, foreground/background location, reboot behavior, account deletion link and privacy link on a physical Android device.
- Verify the external deletion URL works without the Android app installed; it requires signing in through the browser to identify the account.
- Provide valid customer, company and rider reviewer accounts and a route through any business-approval step.
- Check the Google Play listing, screenshots, app access instructions, content rating, Ads declaration, Data Safety answers and permissions declaration.
- Have Nigerian privacy counsel or a qualified DPO review the privacy policy, identity evidence retention, lawful basis, data subject request process and DPIA. The code cannot certify legal compliance by itself.
