-- Published plan subscription prices are derived from the selected plan; Enterprise uses its contract.
create or replace function public.set_admin_cost_rate_settings(p_settings jsonb) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_plan text;v_sku text;v_monthly numeric;v_free integer;v_rate numeric;v_fx numeric;
  v_percent numeric;v_flat numeric;v_waiver numeric;v_cap numeric;v_sms numeric;v_result jsonb;
begin
  if not public.has_role(auth.uid(),'admin') then raise insufficient_privilege using message='Super Admin access is required'; end if;
  if p_settings is null or jsonb_typeof(p_settings)<>'object' then raise check_violation using message='Invalid cost settings'; end if;
  v_plan:=p_settings->>'supabase_plan';v_sku:=p_settings->>'google_route_sku';
  v_monthly:=case v_plan when 'free' then 0 when 'pro' then 25 when 'team' then 599 else (p_settings->>'supabase_monthly_usd')::numeric end;
  v_free:=(p_settings->>'google_free_monthly_elements')::integer;
  v_rate:=(p_settings->>'google_usd_per_1000')::numeric;
  v_fx:=nullif(p_settings->>'usd_to_ngn','')::numeric;
  v_percent:=(p_settings->>'paystack_percent')::numeric;
  v_flat:=(p_settings->>'paystack_flat_ngn')::numeric;
  v_waiver:=(p_settings->>'paystack_flat_waiver_below_ngn')::numeric;
  v_cap:=(p_settings->>'paystack_fee_cap_ngn')::numeric;
  v_sms:=nullif(p_settings->>'sms_ngn_per_message','')::numeric;
  if v_plan not in ('free','pro','team','enterprise') or v_sku not in ('essentials','pro','enterprise')
    or v_monthly is null or v_monthly<0 or v_monthly>1000000
    or v_free is null or v_free<0 or v_free>10000000
    or v_rate is null or v_rate<0 or v_rate>100000
    or (v_fx is not null and (v_fx<=0 or v_fx>1000000))
    or v_percent is null or v_percent<0 or v_percent>100
    or v_flat is null or v_flat<0 or v_flat>1000000
    or v_waiver is null or v_waiver<0 or v_waiver>1000000
    or v_cap is null or v_cap<0 or v_cap>1000000
    or (v_sms is not null and (v_sms<0 or v_sms>100000))
    or (v_plan='free' and v_monthly<>0) then
    raise check_violation using message='Cost settings are outside the allowed range';
  end if;
  update public.admin_cost_rate_settings set supabase_plan=v_plan,supabase_monthly_usd=v_monthly,
    google_route_sku=v_sku,google_free_monthly_elements=v_free,google_usd_per_1000=v_rate,
    usd_to_ngn=v_fx,paystack_percent=v_percent,paystack_flat_ngn=v_flat,
    paystack_flat_waiver_below_ngn=v_waiver,paystack_fee_cap_ngn=v_cap,
    sms_ngn_per_message=v_sms,updated_at=now(),updated_by=auth.uid() where id=1;
  select to_jsonb(s) - 'updated_by' into v_result from public.admin_cost_rate_settings s where id=1;
  return v_result;
end $$;
revoke all on function public.set_admin_cost_rate_settings(jsonb) from public,anon,authenticated;
grant execute on function public.set_admin_cost_rate_settings(jsonb) to authenticated;

create function public.admin_supabase_project_usage_snapshot() returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not public.has_role(auth.uid(),'admin') then
    raise insufficient_privilege using message='Super Admin access is required';
  end if;
  return jsonb_build_object('checked_at',now(),
    'database_bytes',pg_database_size(current_database()));
end $$;
revoke all on function public.admin_supabase_project_usage_snapshot() from public,anon,authenticated;
grant execute on function public.admin_supabase_project_usage_snapshot() to authenticated;

