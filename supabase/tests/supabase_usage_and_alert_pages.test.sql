begin;
do $$
declare v_admin uuid;v_value jsonb;v_estimate numeric;
begin
  if has_table_privilege('authenticated','public.admin_supabase_usage_sample','SELECT')
     or has_function_privilege('anon','public.admin_traffic_spike_snapshot_page(integer,integer)','EXECUTE') then
    raise exception 'Private monitoring data is exposed';
  end if;
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
  begin
    perform public.admin_traffic_spike_snapshot_page(1,8);
    raise exception 'Non-admin viewed alert page';
  exception when insufficient_privilege then null; end;
  select u.id into v_admin from auth.users u where lower(u.email) in
    ('admin@gohezohservices.org','info@gohezohservices.org','vevakporgodsanointed@gmail.com')
    and public.has_role(u.id,'admin') limit 1;
  if v_admin is null then raise exception 'No super admin for integration test'; end if;
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  v_value:=public.admin_traffic_spike_snapshot_page(1,8);
  if jsonb_array_length(v_value->'alerts')>8 or (v_value->>'alerts_total')::bigint<0 then
    raise exception 'Alert paging returned invalid bounds'; end if;
  v_value:=public.admin_supabase_project_usage_snapshot();
  if (v_value->>'database_bytes')::bigint<=0 or v_value->>'plan' is null then
    raise exception 'Supabase usage sample missing'; end if;
  update public.admin_cost_rate_settings set supabase_plan='pro',supabase_monthly_usd=25 where id=1;
  update public.admin_supabase_usage_sample set sampled_at=now(),
    database_bytes=9000000000,storage_bytes=101000000000,
    signed_in_users_this_utc_month=100001 where id=1;
  v_estimate:=public.supabase_overage_daily_estimate_ngn();
  if v_estimate is null or v_estimate<=0 then
    raise exception 'Paid plan usage above allowances produced no estimate'; end if;
  if (public.admin_cost_monitor()->>'supabase_overage_daily_estimate_ngn')::numeric<>v_estimate then
    raise exception 'Cost monitor missed Supabase overage estimate'; end if;
end $$;
rollback;
