-- Keep the per-phone acknowledgement ledger bounded without per-poll cleanup.
create function public.prune_admin_alarm_history() returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  delete from public.admin_alarm_acknowledgements
    where acknowledged_at<now()-interval '90 days';
  delete from public.admin_alarm_margin_events
    where detected_at<now()-interval '90 days';
  delete from public.admin_alarm_margin_state
    where alarm_day<(now() at time zone 'UTC')::date-90;
  delete from public.admin_alarm_devices
    where revoked_at<now()-interval '90 days';
end $$;
revoke all on function public.prune_admin_alarm_history()
  from public,anon,authenticated,service_role;
select cron.schedule('kwik-parsel-prune-admin-alarm','25 3 * * *',
  'select public.prune_admin_alarm_history()');
