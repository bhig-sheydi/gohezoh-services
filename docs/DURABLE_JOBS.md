# Durable backend jobs

`public.durable_jobs` is a private Postgres-backed queue. It uses unique idempotency keys, `FOR UPDATE SKIP LOCKED` batch processing, bounded exponential retries, and a dead-letter state after eight attempts by default. Only the service role and trusted database scheduler can process jobs; application users cannot read or write queue records.

The first supported job is `quote_window_expiry`. Creating or reopening a quote window inserts its expiry job in the same transaction. Changing its deadline cancels the previous pending job and schedules a new one. Closing or cancelling the quote window cancels pending expiry work. Open windows that existed before queue deployment are backfilled. The `gohezoh-process-durable-jobs` `pg_cron` task runs every minute. Processing calls the existing Operations quote-closing workflow, preserving its bid ranking, tie review, and audit behavior.

Job failures retain a bounded error string and are retried with exponential backoff up to six hours. Exhausted jobs move to `dead`; inspect them through a trusted database connection or service-role tooling. Successful completion is recorded only after the handler returns successfully. A missing or already-closed quote window is treated as completed obsolete work. A daily maintenance task removes completed/cancelled rows after 90 days; dead-letter rows are retained for investigation.

This queue does not send email or SMS. The app currently has no external-notification provider configuration or notification-consent workflow. Add a provider-backed handler only when recipient consent and provider credentials are configured, and mark delivery complete only after the provider confirms acceptance. Reminders, route discovery, billing, and settlements are not yet queued.

Validate with `npm run test:db:linked`. The `durable_job_queue.test.sql` test checks private access, idempotency, deadline replacement/cancellation, delayed retry, and rejection of authenticated callers.
