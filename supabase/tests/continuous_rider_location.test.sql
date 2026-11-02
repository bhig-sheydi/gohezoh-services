begin;
do $$
declare v_partner uuid:=gen_random_uuid();v_manager uuid;v_owned_partner uuid;
begin
  if has_table_privilege('authenticated','public.rider_location_latest','SELECT')
    or has_function_privilege('authenticated','public.report_native_off_duty_position(text,double precision,double precision,double precision,timestamptz)','EXECUTE')
    or has_function_privilege('authenticated','public.save_rider_location_latest(uuid,uuid,extensions.geography,double precision,timestamptz,boolean)','EXECUTE') then
    raise exception 'Rider location store or native token endpoint is exposed to signed-in clients';
  end if;
  if pg_get_functiondef('public.get_my_delivery_tracking(uuid)'::regprocedure) not like '%public.rider_location_latest rp%'
    or pg_get_functiondef('public.claim_my_rider_location_check(uuid)'::regprocedure) not like '%public.rider_location_latest rp%' then
    raise exception 'Customer active-job tracking does not use off-duty fixes';
  end if;
  perform set_config('request.jwt.claim.role','authenticated',true);
  begin
    perform * from public.list_company_rider_locations(v_partner);
    raise exception 'Unrelated company could read rider location';
  exception when insufficient_privilege then null; end;
  begin
    perform public.report_native_off_duty_position(repeat('0',64),4.88,7.01,20,clock_timestamp());
    raise exception 'Invalid phone token reported off-duty location';
  exception when insufficient_privilege then null; end;
  select pu.user_id,pu.partner_id into v_manager,v_owned_partner from public.partner_users pu
    join public.logistics_partners p on p.id=pu.partner_id and p.status='active'
    where pu.membership_role='manager' limit 1;
  if v_manager is not null then
    perform set_config('request.jwt.claim.sub',v_manager::text,true);
    perform * from public.list_company_rider_locations(v_owned_partner);
    perform set_config('request.jwt.claim.sub','',true);
  end if;
  if not exists(select 1 from pg_trigger where tgname='copy_on_duty_rider_location' and tgenabled='O') then
    raise exception 'On-duty GPS does not refresh the latest fix';
  end if;
end $$;
rollback;
