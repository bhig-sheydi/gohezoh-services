# Super Admin traffic monitor

The Super Admin page samples database activity once per minute and refreshes its
health panel every 30 seconds while the page is visible. It keeps seven days of
minute samples and 30 days of resolved alerts. Samples contain aggregate counts
only; no customer, rider, address, phone, or FCM token is shown in the panel.

The dashboard reports database transactions, rows fetched and rollbacks; overdue
quote, route, dispatch and matching work; Google route-matrix usage; and write
changes to rider location, booking, route event and shared-address tables. It
shows the affected component as a **likely cause**. Database-wide counts alone
cannot identify a precise API endpoint; use Supabase logs and query diagnostics
if the alert only says database traffic rose.

Warnings start at an absolute floor as well as three times the preceding
30-minute average. Critical alerts start at a larger floor or six times that
average. Queue alerts require work to be more than two minutes overdue. The
Google daily guard warns at 4,000 of 5,000 matrix elements and becomes critical
at 4,800. An alert resolves when its signal recovers; acknowledgement is per
admin, so one admin cannot silence another. Stale samples are visible after
three minutes. The in-page alarm requires a click on **Enable alarm** and only
sounds while the dashboard is open.

## Activate Android background alarms

Android uses Firebase Cloud Messaging, rather than keeping a WebView or polling
service running with the screen off. The database push queue and Edge Function
are installed but delivery stays disabled until these steps are complete:

1. In [Firebase Console](https://console.firebase.google.com/), create or select
   a project and add Android package `org.gohezohservices.kwikparsel`. Download
   its `google-services.json` into `android/app/`. The file is Git-ignored.
2. From Firebase Project settings > Service accounts, generate a service-account
   JSON file for the same project. Store its full JSON as Supabase Edge secret
   `FCM_SERVICE_ACCOUNT_JSON` in project `yejiqfocqmdxjeajoexd`. Never put the
   private key in the website environment or commit it.
3. Rebuild and install the signed APK. Verify on a real Android device that the
   Super Admin page can request notification permission, receive an FCM token,
   and register that phone. Test a warning and a critical push with the screen
   off. Only then set `public.admin_spike_push_config.enabled=true` in a
   migration. Until that switch is on, the app explicitly says setup is pending.

The existing `ADMIN_SPIKE_WORKER_SECRET` Edge secret and matching Vault secret
authenticate the scheduled push worker. The queue retries individual devices
with bounded backoff and drops invalid tokens. A high-importance Android
notification channel uses the phone's default notification sound. Phone mute,
Do Not Disturb, denied notification permission, no network, or Google Play
services issues can prevent an audible alert; Android does not let the app
override those controls.
