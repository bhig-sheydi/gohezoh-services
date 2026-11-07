-- A zero allowance with zero recorded charges is not an 80% spending alert.
create or replace function public.admin_cost_monitor() returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare
  v_at timestamptz:=now();
  v_start timestamptz:=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  v_end timestamptz;
  v_jobs bigint:=0;v_unpaid bigint:=0;
  v_completed numeric:=0;v_cancelled numeric:=0;v_cancel_company numeric:=0;
  v_partner numeric:=0;v_other_direct numeric:=0;v_customer_ref numeric:=0;v_partner_ref numeric:=0;
  v_recorded numeric:=0;v_registered numeric:=0;v_available numeric:=0;
  v_target numeric:=0;v_budget numeric:=0;v_google integer:=0;
  v_mode text;v_status text:='unknown';v_warnings text[]:='{}';v_gaps text[]:='{}';
begin
  if not public.has_role(auth.uid(),'admin') then
    raise insufficient_privilege using message='Super Admin access is required';
  end if;
  v_end:=v_start+interval '1 day';
  -- Count only fully collected, completed NGN jobs. A delivery made before
  -- payment is flagged, not treated as money available to fund operations.
  with delivered as (
    select distinct h.job_id from public.job_status_history h
    where h.new_status='delivered' and h.changed_at>=v_start and h.changed_at<v_end
  ), paid as (
    select d.job_id,f.customer_revenue,f.partner_cost,f.other_direct_cost,
      coalesce((select sum(cp.amount) from public.customer_payments cp
        where cp.job_id=d.job_id and cp.status='received' and cp.currency='NGN'),0) received
    from delivered d join public.jobs j on j.id=d.job_id and j.status in ('delivered','closed')
    join public.job_financials f on f.job_id=d.job_id and f.currency='NGN'
  )
  select count(*) filter(where p.received>=p.customer_revenue and p.customer_revenue>0),
    count(*) filter(where p.received<p.customer_revenue),
    coalesce(sum(p.customer_revenue) filter(where p.received>=p.customer_revenue and p.customer_revenue>0),0),
    coalesce(sum(p.partner_cost) filter(where p.received>=p.customer_revenue and p.customer_revenue>0),0),
    coalesce(sum(p.other_direct_cost) filter(where p.received>=p.customer_revenue and p.customer_revenue>0),0),
    coalesce(sum(coalesce((select e.earned_ngn from public.customer_referral_earnings e
      where e.job_id=p.job_id and e.side='customer'),0))
      filter(where p.received>=p.customer_revenue and p.customer_revenue>0),0),
    coalesce(sum(coalesce((select e.earned_ngn from public.customer_referral_earnings e
      where e.job_id=p.job_id and e.side='partner'),0))
      filter(where p.received>=p.customer_revenue and p.customer_revenue>0),0)
    into v_jobs,v_unpaid,v_completed,v_partner,v_other_direct,v_customer_ref,v_partner_ref
  from paid p;

  select coalesce(sum(c.retained_ngn),0),coalesce(sum(c.rider_compensation_ngn),0)
    into v_cancelled,v_cancel_company from public.paid_booking_cancellations c
    where c.status='processed' and c.processed_at>=v_start and c.processed_at<v_end;
  v_partner:=v_partner+v_cancel_company;
  v_registered:=round(v_completed*0.025,2); -- Future independent-biker registration: forecast only.
  v_available:=v_completed+v_cancelled-v_partner-v_other_direct-v_customer_ref-v_partner_ref-v_registered;
  v_target:=round((v_completed+v_cancelled)*0.05,2);
  v_budget:=round(v_available-v_target,2);
  select coalesce(sum(c.amount_ngn),0) into v_recorded from public.admin_operating_costs c
    where c.cost_day=(v_at at time zone 'UTC')::date;
  select coalesce(elements_reserved,0) into v_google from public.google_route_matrix_daily_budget
    where budget_day=(v_at at time zone 'UTC')::date;
  v_google:=coalesce(v_google,0);
  select mode into v_mode from public.admin_cost_mode where id=1;
  v_mode:=coalesce(v_mode,'normal');

  if v_unpaid>0 then
    v_warnings:=array_append(v_warnings,v_unpaid||' delivered job(s) are not fully collected and are excluded.');
  end if;
  if v_completed+v_cancelled>0 and v_budget<=0 then
    v_status:='over_budget';
    v_warnings:=array_append(v_warnings,'After settlement and the 5% profit target, no operating allowance remains for today.');
  elsif v_recorded>v_budget then
    v_status:='over_budget';
    v_warnings:=array_append(v_warnings,'Entered provider charges already exceed today''s operating allowance.');
  elsif v_budget>0 and v_recorded>=v_budget*0.8 then
    v_status:='attention';
    v_warnings:=array_append(v_warnings,'Entered provider charges have reached 80% of today''s operating allowance.');
  end if;
  if v_google>=4000 then
    v_warnings:=array_append(v_warnings,'Google route checks are approaching their separate 5,000-element daily safety limit.');
  end if;
  v_gaps:=array_append(v_gaps,'Provider bills are not connected automatically; entered charges may be incomplete.');
  if not exists(select 1 from public.admin_operating_costs c where c.cost_day=(v_at at time zone 'UTC')::date and c.source='supabase') then
    v_gaps:=array_append(v_gaps,'Supabase charges are not connected or recorded for this day.');
  end if;
  if not exists(select 1 from public.admin_operating_costs c where c.cost_day=(v_at at time zone 'UTC')::date and c.source='paystack_payment') then
    v_gaps:=array_append(v_gaps,'Paystack fees are not connected or recorded for this day.');
  end if;
  if not exists(select 1 from public.admin_operating_costs c where c.cost_day=(v_at at time zone 'UTC')::date and c.source='sms_delivery') then
    v_gaps:=array_append(v_gaps,'SMS fees are not connected or recorded for this day.');
  end if;
  if not exists(select 1 from public.admin_operating_costs c where c.cost_day=(v_at at time zone 'UTC')::date and c.source='google_route_matrix') then
    v_gaps:=array_append(v_gaps,'Google Routes charges are not connected or recorded for this day.');
  end if;
  v_gaps:=array_append(v_gaps,'Rider-referral attribution and independent-rider registration payouts are not implemented; the registration amount above is a conservative reserve only.');
  return jsonb_build_object(
    'checked_at',v_at,'period_start',v_start,'period_end',v_end,
    'completed_paid_jobs',v_jobs,'completed_revenue_ngn',v_completed,
    'cancelled_retained_revenue_ngn',v_cancelled,'collected_revenue_ngn',v_completed+v_cancelled,
    'partner_payable_ngn',v_partner,'other_direct_cost_ngn',v_other_direct,
    'customer_referral_ngn',v_customer_ref,
    'partner_referral_ngn',v_partner_ref,'registration_referral_reserve_ngn',v_registered,
    'available_for_operations_ngn',v_available,'target_profit_ngn',v_target,
    'operating_budget_ngn',v_budget,'recorded_costs_ngn',v_recorded,
    'known_cost_lower_bound_ngn',v_recorded,
    'estimated_operating_cost_ngn',null,'remaining_operating_budget_ngn',null,
    'google_elements_today',v_google,'google_elements_daily_limit',5000,
    'modeled_costs',jsonb_build_object('google_route_matrix_ngn',null,'sms_ngn',null,
      'paystack_ngn',null,'supabase_ngn',null,'total_known_ngn',0),
    'margin_status',v_status,'mode',v_mode,'warnings',to_jsonb(v_warnings),'data_gaps',to_jsonb(v_gaps));
end $$;
revoke all on function public.admin_cost_monitor() from public,anon,authenticated;
grant execute on function public.admin_cost_monitor() to authenticated;

