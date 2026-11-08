-- Google's Essentials matrix allowance is per calendar month, not per day.
-- Beyond it, reserve only route elements that fit today's earned operating
-- allowance after settlements, the 5% profit target, and known other costs.
create or replace function public.reserve_google_route_matrix_elements_budgeted(p_elements integer)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_day date := (now() at time zone 'UTC')::date;
  v_month date := date_trunc('month',now() at time zone 'UTC')::date;
  v_used_month bigint; v_used_today bigint; v_new_paid bigint;
  v_settings public.admin_cost_rate_settings%rowtype;
  v_revenue numeric:=0; v_partner numeric:=0; v_direct numeric:=0;
  v_customer_ref numeric:=0; v_partner_ref numeric:=0;
  v_cancel numeric:=0; v_cancel_rider numeric:=0;
  v_other_cost numeric:=0; v_paystack numeric:=0; v_supabase numeric:=0;
  v_available numeric; v_rate numeric;
begin
  if auth.role() is distinct from 'service_role' then
    raise insufficient_privilege using message='Routing worker access required';
  end if;
  if p_elements is null or p_elements<1 or p_elements>100 then
    raise check_violation using message='Invalid Google matrix element reservation';
  end if;
  select * into v_settings from public.admin_cost_rate_settings where id=1;
  if v_settings.usd_to_ngn is null or v_settings.usd_to_ngn<=0 then
    -- Free allowance remains usable without a currency assumption.
    v_rate:=null;
  else
    v_rate:=v_settings.google_usd_per_1000*v_settings.usd_to_ngn/1000;
  end if;
  -- Serialize reservations across workers; the existing daily ledger remains
  -- the one source of truth and is also used by the cost monitor.
  insert into public.google_route_matrix_daily_budget(budget_day,elements_reserved)
    values(v_day,0) on conflict(budget_day) do nothing;
  select elements_reserved into v_used_today from public.google_route_matrix_daily_budget
    where budget_day=v_day for update;
  select coalesce(sum(elements_reserved),0) into v_used_month
    from public.google_route_matrix_daily_budget
    where budget_day>=v_month and budget_day<=v_day;
  v_new_paid:=greatest(v_used_month+p_elements-v_settings.google_free_monthly_elements,0)
    -greatest(v_used_month-v_settings.google_free_monthly_elements,0);
  if v_new_paid>0 then
    if v_rate is null or v_rate<=0 then
      if v_rate is null then return false; end if;
    end if;
    -- This is earned revenue: a paid but undelivered parcel is held for
    -- settlement and cannot finance optional routing spend.
    with delivered as (
      select distinct h.job_id from public.job_status_history h
      where h.new_status='delivered'
        and h.changed_at>=v_day::timestamp at time zone 'UTC'
        and h.changed_at<(v_day+1)::timestamp at time zone 'UTC'
    ), paid as (
      select d.job_id,f.customer_revenue,f.partner_cost,f.other_direct_cost
      from delivered d join public.jobs j on j.id=d.job_id and j.status in ('delivered','closed')
      join public.job_financials f on f.job_id=d.job_id and f.currency='NGN'
      where f.customer_revenue>0 and
        (select coalesce(sum(cp.amount),0) from public.customer_payments cp
          where cp.job_id=d.job_id and cp.status='received' and cp.currency='NGN')>=f.customer_revenue
    )
    select coalesce(sum(p.customer_revenue),0),coalesce(sum(p.partner_cost),0),
      coalesce(sum(p.other_direct_cost),0),
      coalesce(sum((select e.earned_ngn from public.customer_referral_earnings e
        where e.job_id=p.job_id and e.side='customer')),0),
      coalesce(sum((select e.earned_ngn from public.customer_referral_earnings e
        where e.job_id=p.job_id and e.side='partner')),0)
      into v_revenue,v_partner,v_direct,v_customer_ref,v_partner_ref from paid p;
    select coalesce(sum(retained_ngn),0),coalesce(sum(rider_compensation_ngn),0)
      into v_cancel,v_cancel_rider from public.paid_booking_cancellations
      where status='processed' and processed_at>=v_day::timestamp at time zone 'UTC'
        and processed_at<(v_day+1)::timestamp at time zone 'UTC';
    v_revenue:=v_revenue+v_cancel;
    v_partner:=v_partner+v_cancel_rider;
    select coalesce(sum(amount_ngn),0) into v_other_cost from public.admin_operating_costs
      where cost_day=v_day and source not in ('google_route_matrix','paystack_payment','supabase');
    -- Match the monitor's Paystack model and daily base subscription estimate.
    select coalesce(sum(least(h.amount_ngn*v_settings.paystack_percent/100
      +case when h.amount_ngn<v_settings.paystack_flat_waiver_below_ngn
        then 0 else v_settings.paystack_flat_ngn end,v_settings.paystack_fee_cap_ngn)),0)
      into v_paystack from public.customer_payment_holds h
      where h.provider='paystack' and h.status='paid'
        and h.updated_at>=v_day::timestamp at time zone 'UTC'
        and h.updated_at<(v_day+1)::timestamp at time zone 'UTC';
    v_supabase:=v_settings.supabase_monthly_usd*v_settings.usd_to_ngn /
      extract(day from (v_month+interval '1 month - 1 day'));
    v_available:=v_revenue-v_partner-v_direct-v_customer_ref-v_partner_ref
      -round((v_revenue-v_cancel)*0.025,2) -- conservative future rider-registration reserve
      -v_revenue*0.05 -greatest(v_paystack,
        coalesce((select sum(amount_ngn) from public.admin_operating_costs
          where cost_day=v_day and source='paystack_payment'),0))
      -greatest(v_supabase,coalesce((select sum(amount_ngn) from public.admin_operating_costs
        where cost_day=v_day and source='supabase'),0))-v_other_cost;
    -- Today's billable route usage has already consumed part of the budget.
    if (greatest(v_used_month-v_settings.google_free_monthly_elements,0)
        -greatest(v_used_month-v_used_today-v_settings.google_free_monthly_elements,0)
        +v_new_paid)*v_rate>v_available then return false; end if;
  end if;
  update public.google_route_matrix_daily_budget set
    elements_reserved=elements_reserved+p_elements,updated_at=now() where budget_day=v_day;
  return true;
end $$;
revoke all on function public.reserve_google_route_matrix_elements_budgeted(integer) from public,anon,authenticated;
grant execute on function public.reserve_google_route_matrix_elements_budgeted(integer) to service_role;

-- Replace the old dashboard's misleading fixed daily-ceiling message.
alter function public.admin_cost_monitor() rename to admin_cost_monitor_before_budgeted_routes;
revoke all on function public.admin_cost_monitor_before_budgeted_routes() from public,anon,authenticated;
create function public.admin_cost_monitor() returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_prior jsonb; v_warnings jsonb;
begin
  if not public.has_role(auth.uid(),'admin') then
    raise insufficient_privilege using message='Super Admin access is required';
  end if;
  v_prior:=public.admin_cost_monitor_before_budgeted_routes();
  select coalesce(jsonb_agg(value),'[]'::jsonb) into v_warnings
    from jsonb_array_elements(v_prior->'warnings')
    where value #>> '{}' not like 'Google route checks are approaching their separate%';
  return v_prior||jsonb_build_object('warnings',v_warnings,
    'google_elements_daily_limit',null,'google_route_budget_mode','monthly_free_then_daily_earned');
end $$;
revoke all on function public.admin_cost_monitor() from public,anon,authenticated;
grant execute on function public.admin_cost_monitor() to authenticated;
