begin;

do $$
declare v_id uuid;v_admin uuid;v_snapshot jsonb;
begin
  if has_function_privilege('anon','public.admin_traffic_spike_snapshot()','EXECUTE')
     or has_function_privilege('authenticated','public.sample_admin_traffic_spikes()','EXECUTE')
     or has_function_privilege('authenticated','public.admin_traffic_spike_snapshot_core()','EXECUTE')
     or has_table_privilege('authenticated','public.admin_traffic_samples','SELECT')
     or has_table_privilege('authenticated','public.admin_traffic_alerts','SELECT') then
    raise exception 'Traffic data leaked outside the gated admin RPC';
  end if;
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
  begin
    perform public.admin_traffic_spike_snapshot();
    raise exception 'Non-admin read the traffic monitor';
  exception when insufficient_privilege then null; end;
  begin
    perform public.admin_acknowledge_traffic_spike(gen_random_uuid());
    raise exception 'Non-admin acknowledged a traffic alert';
  exception when insufficient_privilege then null; end;

  perform public.record_admin_traffic_signal('sql_test_spike','Test cause',70,3,20,60,now());
  select id into v_id from public.admin_traffic_alerts
    where source='sql_test_spike' and resolved_at is null;
  if v_id is null then raise exception 'Threshold did not create an alert'; end if;
  perform public.record_admin_traffic_signal('sql_test_spike','Test cause',80,3,20,60,now());
  if (select count(*) from public.admin_traffic_alerts
      where source='sql_test_spike' and resolved_at is null)<>1 then
    raise exception 'Repeated sample duplicated an active alert';
  end if;
  if (select severity from public.admin_traffic_alerts where id=v_id)<>'critical' then
    raise exception 'Critical severity was not recorded';
  end if;

  select u.id into v_admin from auth.users u where lower(u.email) in
    ('admin@gohezohservices.org','info@gohezohservices.org','vevakporgodsanointed@gmail.com')
    and public.has_role(u.id,'admin') limit 1;
  if v_admin is null then raise exception 'No configured super admin for RPC test'; end if;
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  v_snapshot:=public.admin_traffic_spike_snapshot();
  if jsonb_typeof(v_snapshot->'metrics')<>'array'
     or jsonb_typeof(v_snapshot->'alerts')<>'array' then
    raise exception 'Admin traffic snapshot has an invalid shape';
  end if;
  perform public.admin_acknowledge_traffic_spike(v_id);
  if not exists(select 1 from public.admin_traffic_acknowledgements
    where alert_id=v_id and user_id=v_admin) then
    raise exception 'Admin acknowledgement was not recorded';
  end if;

  perform public.record_admin_traffic_signal('sql_test_spike','Test cause',0,3,20,60,now());
  if (select resolved_at from public.admin_traffic_alerts where id=v_id) is null then
    raise exception 'Recovered signal did not resolve the alert';
  end if;
  perform public.record_admin_traffic_signal('sql_test_spike','Test cause',30,3,20,60,now());
  if (select count(*) from public.admin_traffic_alerts
      where source='sql_test_spike')<>2 then
    raise exception 'A later spike did not open a fresh alert';
  end if;

  insert into public.admin_traffic_samples(sampled_at,transactions_total,rows_fetched_total,rollbacks_total)
    values(date_trunc('minute',now())+interval '1 hour',0,0,0);
  if not exists(select 1 from public.admin_traffic_samples
    where sampled_at=date_trunc('minute',now())+interval '1 hour'
      and writes_per_minute ? 'rider_presence'
      and writes_per_minute ? 'shared_delivery_places') then
    raise exception 'Table write sampler did not identify app write sources';
  end if;
end $$;

rollback;
