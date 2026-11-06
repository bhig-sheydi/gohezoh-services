begin;

do $$
declare v_admin uuid;v_device uuid:=gen_random_uuid();v_alert uuid;v_delivery uuid;
begin
  if has_table_privilege('authenticated','public.admin_spike_push_devices','SELECT')
    or has_table_privilege('authenticated','public.admin_spike_push_deliveries','SELECT')
    or has_function_privilege('authenticated',
      'public.claim_admin_spike_push_deliveries(integer)','EXECUTE') then
    raise exception 'Push token or delivery queue leaked to a client';
  end if;
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
  begin
    perform public.admin_spike_push_configuration();
    raise exception 'Non-admin read phone push configuration';
  exception when insufficient_privilege then null; end;
  begin
    perform public.admin_register_spike_push_device(v_device,repeat('x',80));
    raise exception 'Non-admin registered an alert phone';
  exception when insufficient_privilege then null; end;

  select u.id into v_admin from auth.users u where lower(u.email) in
    ('admin@gohezohservices.org','info@gohezohservices.org','vevakporgodsanointed@gmail.com')
    and public.has_role(u.id,'admin') limit 1;
  if v_admin is null then raise exception 'No configured super admin for push RPC test'; end if;
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  perform public.admin_register_spike_push_device(v_device,repeat('x',80));
  if not exists(select 1 from public.admin_spike_push_devices
    where user_id=v_admin and device_id=v_device) then
    raise exception 'Super admin phone registration failed';
  end if;
  if (public.admin_spike_push_configuration()->>'enabled')::boolean then
    raise exception 'Unconfigured push was enabled';
  end if;
  update public.admin_spike_push_config set enabled=true where singleton;
  perform public.record_admin_traffic_signal('sql_test_push','Test cause',30,0,20,60,now());
  select id into v_alert from public.admin_traffic_alerts
    where source='sql_test_push' and resolved_at is null;
  select id into v_delivery from public.admin_spike_push_deliveries
    where alert_id=v_alert and severity='warning';
  if v_delivery is null then raise exception 'New spike did not queue a phone alert'; end if;
  perform public.record_admin_traffic_signal('sql_test_push','Test cause',70,0,20,60,now());
  if (select count(*) from public.admin_spike_push_deliveries
      where alert_id=v_alert)<>2 then
    raise exception 'Critical escalation did not queue exactly one new phone alert';
  end if;
  perform set_config('request.jwt.claim.role','service_role',true);
  if not exists(select 1 from public.claim_admin_spike_push_deliveries(20)
    where delivery_id=v_delivery and device_token=repeat('x',80)) then
    raise exception 'Trusted worker could not claim the queued alert';
  end if;
  perform public.finish_admin_spike_push_delivery(v_delivery,true);
  if (select status from public.admin_spike_push_deliveries where id=v_delivery)<>'sent' then
    raise exception 'Successful phone alert was not marked sent';
  end if;
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform public.admin_unregister_spike_push_device(v_device);
  if exists(select 1 from public.admin_spike_push_devices where device_id=v_device) then
    raise exception 'Unregister did not remove this phone';
  end if;
end $$;

rollback;
