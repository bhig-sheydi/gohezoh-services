# Activate independent-rider verification

The app sends an independent rider through one Dojah EasyOnboard flow. The flow must require **Nigeria NIN government lookup**, **live selfie with liveness and face match**, and **digital address verification**. Do not make any of these steps optional or accept a pending/manual-review result as passed. Publish the flow and copy its widget ID.

In Dojah, open [EasyOnboard](https://app.dojah.io/) and create the rider flow. Dojah's [hosted-flow guide](https://docs.dojah.io/api-reference/hosted-flows-easyonboard/how-hosted-flows-work) describes publishing and obtaining the widget ID. Find the app ID and public key in Developers/API credentials. Add these **public** Vercel variables to both Preview and Production:

```
VITE_DOJAH_APP_ID=<Dojah app ID>
VITE_DOJAH_PUBLIC_KEY=<Dojah public key>
VITE_DOJAH_RIDER_WIDGET_ID=<published rider widget ID>
```

Subscribe the `kyc_widget` service to this callback URL in [Dojah Webhooks](https://app.dojah.io/developers/webhooks):

```
https://yejiqfocqmdxjeajoexd.supabase.co/functions/v1/dojah-rider-webhook
```

Copy the **webhook subscription secret** shown there, then add these Supabase Edge Function secrets:

```
DOJAH_WEBHOOK_SECRET=<webhook subscription secret>
DOJAH_RIDER_WIDGET_ID=<the same published rider widget ID>
```

`DOJAH_WEBHOOK_SECRET` is distinct from the Dojah API secret. Never put either secret in a `VITE_` variable. The webhook validates the raw-body HMAC before it processes any result; a browser completion callback cannot approve a rider. See [Dojah webhook authentication](https://docs.dojah.io/api-reference/core-concepts/webhooks-signatures).

The current Dojah credentials are sandbox credentials. The deployed webhook acknowledges signed events but does not activate riders until `DOJAH_RIDER_LIVE_ENABLED=true` is set as a Supabase secret. Set that flag only after replacing the browser keys and widget ID with a live Dojah flow, updating the webhook subscription secret and widget ID in Supabase, and completing a live end-to-end verification test. Do not enable live activation for the sandbox flow.

Deploy migration `20261116120000_independent_rider_dojah_verification.sql` and Edge Function `dojah-rider-webhook` **after** the current earlier migrations. Redeploy the frontend after setting the Vercel variables. Test in Dojah sandbox first: a passed NIN, face and address opens the rider workspace; a failed or pending step does not.
