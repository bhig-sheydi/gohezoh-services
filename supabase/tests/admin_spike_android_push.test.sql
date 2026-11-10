begin;

-- The restored Firebase sender must remain scheduled for the tested Android alarm.
do $$
begin
  if not (select enabled from public.admin_spike_push_config where singleton) then
    raise exception 'Admin Firebase push is disabled';
  end if;
  if not exists(select 1 from cron.job where jobname='kwik-parsel-admin-spike-push' and active) then
    raise exception 'Admin Firebase sender is not scheduled';
  end if;
  if not exists(select 1 from pg_trigger where tgname='admin_spike_alert_enqueue_push'
      and not tgisinternal and tgenabled='O') then
    raise exception 'Admin Firebase enqueue trigger is not active';
  end if;
  if to_regprocedure('public.claim_admin_spike_push_deliveries(integer)') is null then
    raise exception 'Admin Firebase delivery claim is missing';
  end if;
end $$;

rollback;
