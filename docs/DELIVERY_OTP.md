# Delivery confirmation codes

The partner portal requests a six-digit code through the `delivery-otp` Edge Function. The function authenticates the partner, stores only a bcrypt hash, and sends the code to the recipient through the configured provider. The database allows at most three sends and five verification attempts per job in a rolling hour. The code expires after ten minutes. Delivery status changes to `delivered` only after a valid code is verified.

For WhatsApp Cloud API, create a business sender number and an approved message template for delivery confirmation. The template must have exactly two text placeholders in its body: `{{1}}` for the job number and `{{2}}` for the six-digit code. Suggested body: `Kwik-Parsel delivery {{1}}: give code {{2}} to the rider only after receiving your parcel. Expires in 10 minutes.` Use the category Meta approves for this delivery-update use case. Set Supabase Edge Function secrets `DELIVERY_MESSAGE_PROVIDER=whatsapp_cloud`, `WHATSAPP_ACCESS_TOKEN` (a system-user token, not a short-lived test token), `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_TEMPLATE_NAME`, `WHATSAPP_TEMPLATE_LANGUAGE` (for example `en`), and `WHATSAPP_GRAPH_VERSION` (the current supported version, for example `v24.0`). The recipient must have WhatsApp and have agreed to receive this delivery message. A successful send API response is acceptance for processing, not proof of delivery to the recipient. The app does not yet receive WhatsApp delivery-status webhooks.

For Messaging.ng, set Supabase Edge Function secrets `DELIVERY_SMS_PROVIDER=messaging_ng`, `MESSAGING_NG_PUBLIC_KEY`, `MESSAGING_NG_SECRET_KEY`, and `MESSAGING_NG_SENDER_ID`. The sender ID must be approved in Messaging.ng. The function uses its transactional SMS route. Messaging.ng publishes ₦6 per billable message page; verify the live rate and test response in your account before enabling production sends. Keep the code message short enough to fit one SMS page where possible.

Configure one provider in Supabase Edge Function secrets before trying to send a code. Never add provider credentials to `.env.local`, browser code, or source control. `DELIVERY_MESSAGE_PROVIDER` takes precedence over the older `DELIVERY_SMS_PROVIDER` setting.

For Termii, set `DELIVERY_SMS_PROVIDER=termii`, `TERMII_API_KEY`, and `TERMII_SENDER_ID`. The function uses Termii's transactional DND route for recipient codes; the Termii account must have DND sending enabled.

For Twilio, set `DELIVERY_SMS_PROVIDER=twilio`, `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, and `TWILIO_FROM`. Nigerian local phone numbers are converted to E.164; international phone numbers should already include their country code.

After setting the provider secrets, apply the database migration and deploy the function with the Supabase CLI. The frontend and database regression suites are part of `npm run verify`; provider request tests run with the normal Vitest suite.
