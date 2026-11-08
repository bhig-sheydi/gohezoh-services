begin;

do $$
declare
  v_admin uuid;v_nonadmin uuid;v_device uuid:=gen_random_uuid();
  v_other_device uuid:=gen_random_uuid();v_secret text:=repeat('A',43);
  v_day date:=(now() at time zone 'UTC')::date;
  v_count bigint;v_margin numeric;v_dashboard_margin numeric;
  v_spike uuid;v_resolved uuid;v_margin_event uuid;
  v_response jsonb;
begin
  if not exists(select 1 from cron.job where jobname='kwik-parsel-prune-admin-alarm') then
    raise exception 'Alarm history has no retention job';
  end if;
  if has_table_privilege('authenticated','public.admin_alarm_devices','SELECT')
    or has_table_privilege('authenticated','public.admin_alarm_margin_events','SELECT')
    or has_function_privilege('authenticated',
      'public.admin_poll_alarm_device(uuid,text,uuid[])','EXECUTE')
    or has_function_privilege('authenticated',
      'public.admin_alarm_estimated_margin()','EXECUTE') then
    raise exception 'Private alarm credentials or financial data leaked to clients';
  end if;
  select u.id into v_admin from auth.users u where public.has_role(u.id,'admin') limit 1;
  if v_admin is null then raise exception 'No Super Admin exists for alarm test'; end if;
  select u.id into v_nonadmin from auth.users u
    where not public.has_role(u.id,'admin') limit 1;

  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
  begin
    perform public.admin_register_alarm_device(v_device,v_secret);
    raise exception 'Non-admin registered alarm device';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  begin
    perform public.admin_register_alarm_device(v_device,'short');
    raise exception 'Weak alarm secret was accepted';
  exception when check_violation then null; end;
  perform public.admin_register_alarm_device(v_device,v_secret);
  if not exists(select 1 from public.admin_alarm_devices
      where device_id=v_device and user_id=v_admin and secret_hash=extensions.digest(v_secret,'sha256')) then
    raise exception 'Phone credential was not hashed';
  end if;
  v_dashboard_margin:=(public.admin_cost_monitor()->>'estimated_margin_percent')::numeric;

  perform set_config('request.jwt.claim.role','service_role',true);
  v_margin:=public.admin_alarm_estimated_margin();
  if v_dashboard_margin is distinct from v_margin then
    raise exception 'Phone alarm margin %% differs from dashboard: % vs %',v_margin,v_dashboard_margin;
  end if;
  if v_dashboard_margin is null and v_margin is not null then
    raise exception 'Alarm calculated a margin without dashboard revenue';
  end if;
  if (public.admin_poll_alarm_device(v_device,repeat('B',43))->>'error')<>'unauthorized' then
    raise exception 'Wrong device secret was accepted';
  end if;

  select count(*) into v_count from public.admin_alarm_margin_events where alarm_day=v_day;
  perform public.admin_alarm_transition_margin(v_day,null);
  perform public.admin_alarm_transition_margin(v_day,11);
  if (select count(*) from public.admin_alarm_margin_events where alarm_day=v_day)<>v_count then
    raise exception 'Null or healthy margin raised an alarm';
  end if;
  perform public.admin_alarm_transition_margin(v_day,10);
  if (select count(*) from public.admin_alarm_margin_events where alarm_day=v_day)<>v_count+1 then
    raise exception '10%% threshold did not create exactly one event';
  end if;
  perform public.admin_alarm_transition_margin(v_day,9);
  if (select count(*) from public.admin_alarm_margin_events where alarm_day=v_day)<>v_count+1 then
    raise exception 'Repeated low-margin sample created a duplicate event';
  end if;
  perform public.admin_alarm_transition_margin(v_day,11);
  perform public.admin_alarm_transition_margin(v_day,9.5);
  if (select count(*) from public.admin_alarm_margin_events where alarm_day=v_day)<>v_count+2 then
    raise exception 'Fresh crossing did not raise a new event';
  end if;
  select id into v_margin_event from public.admin_alarm_margin_events
    where alarm_day=v_day order by detected_at desc,id desc limit 1;

  perform public.record_admin_traffic_signal('sql_alarm_active','SQL test active incident',
    30,0,20,60,now()+interval '1 second');
  select md5(id::text||':'||severity)::uuid into v_spike
    from public.admin_traffic_alerts where source='sql_alarm_active' and resolved_at is null;
  perform public.record_admin_traffic_signal('sql_alarm_resolved','SQL test resolved incident',
    30,0,20,60,now());
  select md5(id::text||':'||severity)::uuid into v_resolved
    from public.admin_traffic_alerts where source='sql_alarm_resolved' and resolved_at is null;
  perform public.record_admin_traffic_signal('sql_alarm_resolved','SQL test resolved incident',
    0,0,20,60,now());
  v_response:=public.admin_poll_alarm_device(v_device,v_secret);
  if not (v_response->'alerts') @> jsonb_build_array(jsonb_build_object('id',v_spike))
    or not (v_response->'alerts') @> jsonb_build_array(jsonb_build_object('id',v_margin_event)) then
    raise exception 'Phone did not receive active spike % and current margin % alarms: %',v_spike,v_margin_event,v_response;
  end if;
  if (v_response->'alerts') @> jsonb_build_array(jsonb_build_object('id',v_resolved)) then
    raise exception 'Resolved incident caused a phone alarm';
  end if;
  if (public.admin_poll_alarm_device(v_device,v_secret)->>'error')<>'rate_limited' then
    raise exception 'Rapid phone polling was not throttled';
  end if;
  update public.admin_alarm_devices set last_poll_at=now()-interval '1 minute'
    where device_id=v_device;
  v_response:=public.admin_poll_alarm_device(v_device,v_secret);
  if not (v_response->'alerts') @> jsonb_build_array(jsonb_build_object('id',v_spike)) then
    raise exception 'Unacknowledged alarm was lost before phone ACK';
  end if;
  update public.admin_alarm_devices set last_poll_at=now()-interval '1 minute'
    where device_id=v_device;
  v_response:=public.admin_poll_alarm_device(v_device,v_secret,array[v_spike,v_margin_event]);
  if (v_response->'alerts') @> jsonb_build_array(jsonb_build_object('id',v_spike))
    or (v_response->'alerts') @> jsonb_build_array(jsonb_build_object('id',v_margin_event)) then
    raise exception 'Acknowledged phone alarm repeated';
  end if;

  if v_nonadmin is not null then
    perform set_config('request.jwt.claim.role','authenticated',true);
    perform public.admin_register_alarm_device(v_other_device,v_secret);
    update public.admin_alarm_devices set user_id=v_nonadmin
      where device_id=v_other_device;
    perform set_config('request.jwt.claim.role','service_role',true);
    v_response:=public.admin_poll_alarm_device(v_other_device,v_secret);
    if (v_response->>'error')<>'revoked'
      or exists(select 1 from public.admin_alarm_devices
        where device_id=v_other_device and secret_hash is not null) then
      raise exception 'Revoked Super Admin could still poll alarms: response %, role %, hash %',
        v_response,public.has_role(v_nonadmin,'admin'),
        (select secret_hash is not null from public.admin_alarm_devices where device_id=v_other_device);
    end if;
  end if;
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform public.admin_unregister_alarm_device(v_device);
  perform set_config('request.jwt.claim.role','service_role',true);
  if (public.admin_poll_alarm_device(v_device,v_secret)->>'error')<>'unauthorized' then
    raise exception 'Disabled phone could still poll alarms';
  end if;
end $$;

rollback;
