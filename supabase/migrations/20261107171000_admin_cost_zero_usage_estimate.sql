-- Zero usage and a free Supabase plan cost zero even before an FX rate is configured.
create or replace function public.admin_cost_monitor() returns jsonb
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
  if v_google_billable=0 then v_google_ngn:=0; end if;
  if v_settings.supabase_plan='free' then v_supabase_ngn:=0; end if;
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

