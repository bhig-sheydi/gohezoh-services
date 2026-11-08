begin;

-- The previous Firebase queue is retired. Even an accidental config toggle
-- must not enqueue work or restart the old per-minute sender.
do $$
declare v_alert uuid;v_before bigint;
begin
  if (select enabled from public.admin_spike_push_config where singleton) then
    raise exception 'Retired Firebase sender is enabled';
  end if;
  if exists(select 1 from cron.job where jobname='kwik-parsel-admin-spike-push') then
    raise exception 'Retired Firebase cron still runs';
  end if;
  if exists(select 1 from pg_trigger where tgname='admin_spike_alert_enqueue_push'
      and not tgisinternal) then
    raise exception 'Retired Firebase enqueue trigger remains';
  end if;
  select count(*) into v_before from public.admin_spike_push_deliveries;
  update public.admin_spike_push_config set enabled=true where singleton;
  perform set_config('request.jwt.claim.role','service_role',true);
  perform public.record_admin_traffic_signal('sql_test_retired_push','Test cause',30,0,20,60,now());
  select id into v_alert from public.admin_traffic_alerts
    where source='sql_test_retired_push' and resolved_at is null;
  if v_alert is null or (select count(*) from public.admin_spike_push_deliveries)<>v_before then
    raise exception 'Retired Firebase queue received a new alert';
  end if;
end $$;

rollback;
