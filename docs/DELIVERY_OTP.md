# Delivery confirmation codes

The partner portal requests a six-digit code through the `delivery-otp` Edge Function. The function authenticates the partner, stores only a bcrypt hash, and sends the code to the recipient's phone through Termii or Twilio. The database allows at most three sends and five verification attempts per job in a rolling hour. The code expires after ten minutes. Delivery status changes to `delivered` only after a valid code is verified.

Configure one provider in Supabase Edge Function secrets before applying the migration and deploying the function. Never add provider credentials to `.env.local`, browser code, or source control.

For Termii, set `DELIVERY_SMS_PROVIDER=termii`, `TERMII_API_KEY`, and `TERMII_SENDER_ID`. The function uses Termii's transactional DND route for recipient codes; the Termii account must have DND sending enabled.

For Twilio, set `DELIVERY_SMS_PROVIDER=twilio`, `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, and `TWILIO_FROM`. Nigerian local phone numbers are converted to E.164; international phone numbers should already include their country code.

After setting the provider secrets, apply the database migration and deploy the function with the Supabase CLI. The frontend and database regression suites are part of `npm run verify`; provider request tests run with the normal Vitest suite.
