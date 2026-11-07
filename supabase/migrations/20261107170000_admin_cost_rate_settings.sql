-- Admin-owned assumptions for a cost forecast. These are never treated as provider invoices.
create table public.admin_cost_rate_settings (
  id integer primary key default 1 check (id=1),
  supabase_plan text not null default 'free' check (supabase_plan in ('free','pro','team','enterprise')),
  supabase_monthly_usd numeric(12,2) not null default 0 check (supabase_monthly_usd>=0),
  google_route_sku text not null default 'essentials' check (google_route_sku in ('essentials','pro','enterprise')),
  google_free_monthly_elements integer not null default 10000 check (google_free_monthly_elements>=0),
  google_usd_per_1000 numeric(12,4) not null default 5 check (google_usd_per_1000>=0),
  usd_to_ngn numeric(12,4) check (usd_to_ngn>0),
  paystack_percent numeric(7,4) not null default 1.5 check (paystack_percent between 0 and 100),
  paystack_flat_ngn numeric(12,2) not null default 100 check (paystack_flat_ngn>=0),
  paystack_flat_waiver_below_ngn numeric(12,2) not null default 2500 check (paystack_flat_waiver_below_ngn>=0),
  paystack_fee_cap_ngn numeric(12,2) not null default 2000 check (paystack_fee_cap_ngn>=0),
  sms_ngn_per_message numeric(12,2) check (sms_ngn_per_message>=0),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);
insert into public.admin_cost_rate_settings(id) values(1);
alter table public.admin_cost_rate_settings enable row level security;
revoke all on public.admin_cost_rate_settings from public,anon,authenticated;

create function public.set_admin_cost_rate_settings(p_settings jsonb) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_plan text;v_sku text;v_monthly numeric;v_free integer;v_rate numeric;v_fx numeric;
  v_percent numeric;v_flat numeric;v_waiver numeric;v_cap numeric;v_sms numeric;v_result jsonb;
begin
  if not public.has_role(auth.uid(),'admin') then raise insufficient_privilege using message='Super Admin access is required'; end if;
  if p_settings is null or jsonb_typeof(p_settings)<>'object' then raise check_violation using message='Invalid cost settings'; end if;
  v_plan:=p_settings->>'supabase_plan';v_sku:=p_settings->>'google_route_sku';
  v_monthly:=(p_settings->>'supabase_monthly_usd')::numeric;
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

-- Keep the existing verified settlement arithmetic; add a separate forecast layer.
alter function public.admin_cost_monitor() rename to admin_cost_monitor_base;
revoke all on function public.admin_cost_monitor_base() from public,anon,authenticated;

create function public.admin_cost_monitor() returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_base jsonb;v_settings public.admin_cost_rate_settings%rowtype;
  v_today date:=(now() at time zone 'UTC')::date;v_month date;
  v_google_before bigint:=0;v_google_today bigint:=0;v_google_ngn numeric;
  v_paystack_ngn numeric:=0;v_supabase_ngn numeric;v_fx numeric;
  v_estimated numeric:=0;v_google_billable bigint;v_month_days integer;
begin
  if not public.has_role(auth.uid(),'admin') then raise insufficient_privilege using message='Super Admin access is required'; end if;
  v_base:=public.admin_cost_monitor_base();
  select * into v_settings from public.admin_cost_rate_settings where id=1;
  v_month:=date_trunc('month',v_today::timestamp)::date;
  v_month_days:=extract(day from (v_month+interval '1 month - 1 day'))::integer;
  select coalesce(sum(elements_reserved),0) into v_google_before
    from public.google_route_matrix_daily_budget where budget_day>=v_month and budget_day<v_today;
  select coalesce(elements_reserved,0) into v_google_today
    from public.google_route_matrix_daily_budget where budget_day=v_today;
  v_google_billable:=greatest(v_google_before+v_google_today-v_settings.google_free_monthly_elements,0)
    -greatest(v_google_before-v_settings.google_free_monthly_elements,0);
  v_fx:=v_settings.usd_to_ngn;
  if v_fx is not null then
    v_google_ngn:=round(v_google_billable*v_settings.google_usd_per_1000*v_fx/1000,2);
    v_supabase_ngn:=round(v_settings.supabase_monthly_usd*v_fx/v_month_days,2);
  end if;
  select coalesce(sum(least(h.amount_ngn*v_settings.paystack_percent/100
    +case when h.amount_ngn<v_settings.paystack_flat_waiver_below_ngn then 0 else v_settings.paystack_flat_ngn end,
    v_settings.paystack_fee_cap_ngn)),0) into v_paystack_ngn
    from public.customer_payment_holds h
    where h.provider='paystack' and h.status='paid'
      and h.updated_at>=v_today::timestamp at time zone 'UTC'
      and h.updated_at<(v_today+1)::timestamp at time zone 'UTC';
  v_paystack_ngn:=round(v_paystack_ngn,2);
  v_estimated:=v_paystack_ngn+coalesce(v_google_ngn,0)+coalesce(v_supabase_ngn,0);
  return v_base||jsonb_build_object(
    'cost_settings',to_jsonb(v_settings)-'updated_by',
    'estimated_tracked_cost_ngn',v_estimated,
    'estimate_is_complete',false,
    'google_billable_elements_today',v_google_billable,
    'modeled_costs',jsonb_build_object('google_route_matrix_ngn',v_google_ngn,
      'paystack_ngn',v_paystack_ngn,'supabase_ngn',v_supabase_ngn,'sms_ngn',null,
      'total_known_ngn',(v_base->>'recorded_costs_ngn')::numeric));
end $$;
revoke all on function public.admin_cost_monitor() from public,anon,authenticated;
grant execute on function public.admin_cost_monitor() to authenticated;
