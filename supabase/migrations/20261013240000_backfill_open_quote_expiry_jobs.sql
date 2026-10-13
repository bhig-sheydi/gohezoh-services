-- Preserve expiry handling for quote windows that were already open when the
-- durable queue replaced the legacy cron sweep.
do $$
declare v_window public.delivery_quote_windows%rowtype;
begin
  for v_window in select * from public.delivery_quote_windows where status='open' loop
    perform public.enqueue_durable_job(
      'quote_window_expiry',
      jsonb_build_object('request_id',v_window.request_id,'deadline_at',v_window.deadline_at),
      'quote-window-expiry:'||v_window.request_id::text||':'||extract(epoch from v_window.deadline_at)::bigint::text,
      v_window.deadline_at
    );
  end loop;
end $$;
