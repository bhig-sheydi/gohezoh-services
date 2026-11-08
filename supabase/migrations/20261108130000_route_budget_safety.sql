-- Keep an admin's cost assumptions conservative when they authorize paid road
-- checks. A Google SKU's published free allowance is monthly, and the app
-- currently has no way to verify a separate Maps subscription allowance.
update public.admin_cost_rate_settings set
  supabase_monthly_usd=greatest(supabase_monthly_usd,
    case supabase_plan when 'pro' then 25 when 'team' then 599 else 0 end),
  google_free_monthly_elements=least(google_free_monthly_elements,
    case google_route_sku when 'essentials' then 10000
      when 'pro' then 5000 else 1000 end),
  google_usd_per_1000=greatest(google_usd_per_1000,
    case google_route_sku when 'essentials' then 5
      when 'pro' then 10 else 15 end)
where id=1;

alter table public.admin_cost_rate_settings
  add constraint admin_cost_google_allowance_and_rate_safe check (
    supabase_monthly_usd >= case supabase_plan
      when 'pro' then 25 when 'team' then 599 else 0 end
    and
    google_free_monthly_elements <= case google_route_sku
      when 'essentials' then 10000 when 'pro' then 5000 else 1000 end
    and google_usd_per_1000 >= case google_route_sku
      when 'essentials' then 5 when 'pro' then 10 else 15 end
  );

-- The prior guard treated a missing or stale Supabase overage sample as zero.
-- Serialize the precheck on the same ledger row as the reservation, including
-- when two workers race across the boundary of the monthly free allowance.
alter function public.reserve_google_route_matrix_elements_budgeted(integer)
  rename to reserve_google_route_matrix_elements_before_sample_safety;
revoke all on function public.reserve_google_route_matrix_elements_before_sample_safety(integer)
  from public,anon,authenticated,service_role;

create function public.reserve_google_route_matrix_elements_budgeted(p_elements integer)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_day date := (now() at time zone 'UTC')::date;
  v_month date := date_trunc('month',now() at time zone 'UTC')::date;
  v_used_month bigint;
  v_settings public.admin_cost_rate_settings%rowtype;
begin
  if auth.role() is distinct from 'service_role' then
    raise insufficient_privilege using message='Routing worker access required';
  end if;
  if p_elements is null or p_elements<1 or p_elements>100 then
    raise check_violation using message='Invalid Google matrix element reservation';
  end if;

  select * into v_settings from public.admin_cost_rate_settings where id=1;
  if not found then return false; end if;
  insert into public.google_route_matrix_daily_budget(budget_day,elements_reserved)
    values(v_day,0) on conflict(budget_day) do nothing;
  perform 1 from public.google_route_matrix_daily_budget
    where budget_day=v_day for update;
  select coalesce(sum(elements_reserved),0) into v_used_month
    from public.google_route_matrix_daily_budget
    where budget_day>=v_month and budget_day<=v_day;

  if v_used_month+p_elements>v_settings.google_free_monthly_elements then
    -- Pro/Team samples are only a lower-bound proxy for organization billing.
    -- Unknown or stale usage must not authorize optional pay-as-you-go calls.
    if v_settings.supabase_plan in ('pro','team','enterprise')
      and public.supabase_overage_daily_estimate_ngn() is null then
      return false;
    end if;
  end if;
  return public.reserve_google_route_matrix_elements_before_sample_safety(p_elements);
end $$;
revoke all on function public.reserve_google_route_matrix_elements_budgeted(integer)
  from public,anon,authenticated;
grant execute on function public.reserve_google_route_matrix_elements_budgeted(integer)
  to service_role;

-- A manual savings choice always wins. Otherwise use the same 10% margin
-- estimate as the Android alarm, cached for five minutes so route events do
-- not each rescan the day's payments and provider usage.
create or replace function public.get_routing_economy_mode() returns boolean
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_margin numeric;
begin
  if auth.role() is distinct from 'service_role' then
    raise insufficient_privilege using message='Worker access is required';
  end if;
  if exists(select 1 from public.admin_cost_mode where id=1 and mode='economy') then
    return true;
  end if;
  begin
    v_margin:=public.admin_alarm_current_margin();
  exception when others then
    -- If the cached cost reading fails, conserve optional road calls while
    -- the core proximity and assigned-job flows keep working.
    return true;
  end;
  return coalesce(v_margin<=10,false);
end $$;
revoke all on function public.get_routing_economy_mode()
  from public,anon,authenticated;
grant execute on function public.get_routing_economy_mode() to service_role;

-- The dashboard reports the effective state separately from the admin's
-- manual preference, so its toggle remains predictable during auto savings.
alter function public.admin_cost_monitor()
  rename to admin_cost_monitor_before_auto_economy;
revoke all on function public.admin_cost_monitor_before_auto_economy()
  from public,anon,authenticated;
create function public.admin_cost_monitor() returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_prior jsonb;v_manual text;v_margin numeric;v_auto boolean;
begin
  if not public.has_role(auth.uid(),'admin') then
    raise insufficient_privilege using message='Super Admin access is required';
  end if;
  v_prior:=public.admin_cost_monitor_before_auto_economy();
  v_manual:=coalesce(v_prior->>'mode','normal');
  v_margin:=(v_prior->>'estimated_margin_percent')::numeric;
  v_auto:=coalesce(v_margin<=10,false);
  return v_prior||jsonb_build_object(
    'automatic_economy',v_auto,
    'effective_mode',case when v_manual='economy' or v_auto
      then 'economy' else 'normal' end,
    'economy_reason',case when v_manual='economy' then 'manual'
      when v_auto then 'margin_threshold' else 'normal' end);
end $$;
revoke all on function public.admin_cost_monitor()
  from public,anon,authenticated;
grant execute on function public.admin_cost_monitor() to authenticated;
