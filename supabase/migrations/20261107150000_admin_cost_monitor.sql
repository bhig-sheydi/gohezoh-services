-- Add a spending view to the existing super-admin Service Health panel.
-- This ledger records only charges supplied by an admin. Provider invoices are
-- not connected, so it must never represent an incomplete day as profitable.
create table public.admin_operating_costs (
  id uuid primary key default gen_random_uuid(),
  source text not null check (source in
    ('google_route_matrix','paystack_payment','sms_delivery','supabase','other')),
  amount_ngn numeric(14,2) not null check (amount_ngn > 0),
  cost_day date not null,
  provider_reference text not null check (length(btrim(provider_reference)) between 1 and 160),
  note text check (note is null or length(note) <= 300),
  entered_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (source, provider_reference)
);
create index admin_operating_costs_day_idx on public.admin_operating_costs(cost_day);
alter table public.admin_operating_costs enable row level security;
revoke all on public.admin_operating_costs from public,anon,authenticated;

create table public.admin_cost_mode (
  id smallint primary key default 1 check (id=1),
  mode text not null default 'normal' check (mode in ('normal','economy')),
  changed_by uuid references auth.users(id) on delete set null,
  changed_at timestamptz not null default now()
);
insert into public.admin_cost_mode(id,mode) values (1,'normal');
alter table public.admin_cost_mode enable row level security;
revoke all on public.admin_cost_mode from public,anon,authenticated;

create table public.admin_cost_mode_history (
  id bigint generated always as identity primary key,
  previous_mode text not null,
  next_mode text not null,
  changed_by uuid not null references auth.users(id) on delete restrict,
  changed_at timestamptz not null default now()
);
alter table public.admin_cost_mode_history enable row level security;
revoke all on public.admin_cost_mode_history from public,anon,authenticated;

-- The worker can read the mode, but neither customers nor partners can.
create function public.get_routing_economy_mode() returns boolean
language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if auth.role() is distinct from 'service_role' then
    raise insufficient_privilege using message='Worker access is required';
  end if;
  return coalesce((select mode='economy' from public.admin_cost_mode where id=1),false);
end $$;
revoke all on function public.get_routing_economy_mode() from public,anon,authenticated;
grant execute on function public.get_routing_economy_mode() to service_role;

create function public.set_admin_cost_mode(p_mode text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_previous text;v_at timestamptz;
begin
  if not public.has_role(auth.uid(),'admin') then
    raise insufficient_privilege using message='Super Admin access is required';
  end if;
  if p_mode not in ('normal','economy') or p_mode is null then
    raise check_violation using message='Choose normal or economy mode';
  end if;
  select mode into v_previous from public.admin_cost_mode where id=1 for update;
  if v_previous is distinct from p_mode then
    update public.admin_cost_mode set mode=p_mode,changed_by=auth.uid(),changed_at=now()
      where id=1 returning changed_at into v_at;
    insert into public.admin_cost_mode_history(previous_mode,next_mode,changed_by,changed_at)
      values(v_previous,p_mode,auth.uid(),v_at);
  else
    select changed_at into v_at from public.admin_cost_mode where id=1;
  end if;
  return jsonb_build_object('mode',p_mode,'changed_at',v_at);
end $$;
revoke all on function public.set_admin_cost_mode(text) from public,anon,authenticated;
grant execute on function public.set_admin_cost_mode(text) to authenticated;

create function public.record_admin_operating_cost(
  p_source text,p_amount_ngn numeric,p_cost_day date,p_reference text,p_note text default null
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_id uuid;v_reference text:=btrim(p_reference);v_today date:=(now() at time zone 'UTC')::date;
begin
  if not public.has_role(auth.uid(),'admin') then
    raise insufficient_privilege using message='Super Admin access is required';
  end if;
  if p_source not in ('google_route_matrix','paystack_payment','sms_delivery','supabase','other')
     or p_source is null or p_amount_ngn is null or p_amount_ngn<=0 or p_amount_ngn>1000000000000
     or p_cost_day is null or p_cost_day>v_today or p_cost_day<v_today-interval '2 years'
     or v_reference is null or length(v_reference) not between 1 and 160
     or length(coalesce(p_note,''))>300 then
    raise check_violation using message='Enter a valid provider charge, date and reference';
  end if;
  insert into public.admin_operating_costs(source,amount_ngn,cost_day,provider_reference,note,entered_by)
    values(p_source,round(p_amount_ngn,2),p_cost_day,v_reference,nullif(btrim(p_note),''),auth.uid())
    returning id into v_id;
  return jsonb_build_object('id',v_id);
end $$;
revoke all on function public.record_admin_operating_cost(text,numeric,date,text,text) from public,anon,authenticated;
grant execute on function public.record_admin_operating_cost(text,numeric,date,text,text) to authenticated;

-- Completion-day scanning stays bounded by a partial time-first index. The
-- existing (job_id, changed_at) index cannot serve this daily report.
create index job_status_history_delivered_day_idx
  on public.job_status_history(changed_at,job_id) where new_status='delivered';
create index paid_booking_cancellations_processed_day_idx
  on public.paid_booking_cancellations(processed_at) where status='processed';

create function public.admin_cost_monitor() returns jsonb
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
  elsif v_recorded>=v_budget*0.8 then
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
