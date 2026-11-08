-- Native super-admin alarms without Firebase. A phone holds a random credential;
-- only its SHA-256 digest is stored. Polling is best effort under Android Doze.
create table public.admin_alarm_devices (
  device_id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  secret_hash bytea,
  registered_at timestamptz not null default now(),
  last_poll_at timestamptz,
  revoked_at timestamptz
);
create index admin_alarm_devices_user_idx on public.admin_alarm_devices(user_id);
create table public.admin_alarm_margin_state (
  alarm_day date primary key,
  evaluated_at timestamptz not null default now(),
  below_threshold boolean not null default false,
  last_margin_percent numeric(10,2)
);
create table public.admin_alarm_margin_events (
  id uuid primary key default gen_random_uuid(),
  alarm_day date not null,
  margin_percent numeric(10,2) not null,
  detected_at timestamptz not null default now()
);
create index admin_alarm_margin_events_recent_idx
  on public.admin_alarm_margin_events(detected_at desc);
create table public.admin_alarm_acknowledgements (
  device_id uuid not null references public.admin_alarm_devices(device_id) on delete cascade,
  event_id uuid not null,
  acknowledged_at timestamptz not null default now(),
  primary key(device_id,event_id)
);
alter table public.admin_alarm_devices enable row level security;
alter table public.admin_alarm_margin_state enable row level security;
alter table public.admin_alarm_margin_events enable row level security;
alter table public.admin_alarm_acknowledgements enable row level security;
revoke all on public.admin_alarm_devices,public.admin_alarm_margin_state,
  public.admin_alarm_margin_events,public.admin_alarm_acknowledgements
  from public,anon,authenticated;

create function public.admin_register_alarm_device(p_device_id uuid,p_secret text)
returns void language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
begin
  if not public.has_role(auth.uid(),'admin') then
    raise insufficient_privilege using message='Super Admin access is required';
  end if;
  if p_device_id is null or p_secret is null or p_secret !~ '^[A-Za-z0-9_-]{43}$' then
    raise check_violation using message='Invalid phone alarm registration';
  end if;
  insert into public.admin_alarm_devices(device_id,user_id,secret_hash)
    values(p_device_id,auth.uid(),extensions.digest(p_secret,'sha256'))
  on conflict(device_id) do update set
    user_id=excluded.user_id,secret_hash=excluded.secret_hash,
    registered_at=now(),last_poll_at=null,revoked_at=null
    where public.admin_alarm_devices.user_id=auth.uid()
       or public.admin_alarm_devices.revoked_at is not null;
  if not found then
    raise insufficient_privilege using message='This phone belongs to another Super Admin';
  end if;
  delete from public.admin_alarm_acknowledgements where device_id=p_device_id;
end $$;
revoke all on function public.admin_register_alarm_device(uuid,text) from public,anon,authenticated;
grant execute on function public.admin_register_alarm_device(uuid,text) to authenticated;

create function public.admin_unregister_alarm_device(p_device_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if not public.has_role(auth.uid(),'admin') then
    raise insufficient_privilege using message='Super Admin access is required';
  end if;
  update public.admin_alarm_devices set revoked_at=now(),secret_hash=null
    where device_id=p_device_id and user_id=auth.uid();
end $$;
revoke all on function public.admin_unregister_alarm_device(uuid) from public,anon,authenticated;
grant execute on function public.admin_unregister_alarm_device(uuid) to authenticated;

-- Server-only estimate follows the dashboard's settlement and model rules.
-- It is not an invoice: untracked egress, Edge calls and Google failures can
-- lower the real margin. No client can submit a margin to this function.
create function public.admin_alarm_estimated_margin() returns numeric
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare
  v_day date:=(now() at time zone 'UTC')::date;
  v_month date:=date_trunc('month',now() at time zone 'UTC')::date;
  v_start timestamptz:=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  v_end timestamptz;
  v_settings public.admin_cost_rate_settings%rowtype;
  v_revenue numeric:=0;v_partner numeric:=0;v_direct numeric:=0;
  v_customer_ref numeric:=0;v_partner_ref numeric:=0;
  v_cancel numeric:=0;v_cancel_rider numeric:=0;v_available numeric:=0;
  v_google_matrix numeric:=0;v_google_other numeric:=0;
  v_google_recorded numeric:=0;v_paystack_model numeric:=0;v_paystack_recorded numeric:=0;
  v_supabase_model numeric:=0;v_supabase_recorded numeric:=0;v_other_recorded numeric:=0;
  v_matrix_before bigint:=0;v_matrix_today bigint:=0;v_billable bigint:=0;
  v_fx numeric;v_extra numeric;v_cost numeric;
begin
  if auth.role() is distinct from 'service_role' then
    raise insufficient_privilege using message='Alarm worker access required';
  end if;
  v_end:=v_start+interval '1 day';
  select * into v_settings from public.admin_cost_rate_settings where id=1;
  if not found then return null; end if;
  v_fx:=v_settings.usd_to_ngn;
  with delivered as (
    select distinct h.job_id from public.job_status_history h
    where h.new_status='delivered' and h.changed_at>=v_start and h.changed_at<v_end
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
    where status='processed' and processed_at>=v_start and processed_at<v_end;
  v_partner:=v_partner+v_cancel_rider;
  v_available:=v_revenue+v_cancel-v_partner-v_direct-v_customer_ref-v_partner_ref
    -round(v_revenue*0.025,2);
  v_revenue:=v_revenue+v_cancel;
  if v_revenue<=0 then return null; end if;

  select coalesce(sum(elements_reserved) filter(where budget_day<v_day),0),
    coalesce(sum(elements_reserved) filter(where budget_day=v_day),0)
    into v_matrix_before,v_matrix_today from public.google_route_matrix_daily_budget
    where budget_day>=v_month and budget_day<=v_day;
  v_billable:=greatest(v_matrix_before+v_matrix_today-v_settings.google_free_monthly_elements,0)
    -greatest(v_matrix_before-v_settings.google_free_monthly_elements,0);
  if v_fx is not null then
    v_google_matrix:=round(v_billable*v_settings.google_usd_per_1000*v_fx/1000,2);
    if v_settings.supabase_plan<>'free' then
      v_supabase_model:=round(v_settings.supabase_monthly_usd*v_fx/
        extract(day from (v_month+interval '1 month - 1 day')),2);
    end if;
  end if;
  with sku_rates(sku,free_monthly,usd_per_1000) as (values
    ('places_text',5000,32::numeric),('places_nearby',5000,32::numeric),
    ('geocoding',10000,5::numeric),('dynamic_maps',10000,7::numeric),
    ('autocomplete_requests',10000,2.83::numeric),('place_details',10000,5::numeric),
    ('routes_compute',10000,5::numeric)),
  all_usage as (
    select b.sku,coalesce(sum(b.request_count) filter(where b.usage_day<v_day),0) before_count,
      coalesce(sum(b.request_count) filter(where b.usage_day=v_day),0) today_count
      from public.google_browser_usage_daily b
      where b.usage_day>=v_month and b.usage_day<=v_day group by b.sku
    union all
    select 'routes_compute',
      (select count(*) from public.bike_route_prices p where p.created_at>=v_month::timestamp at time zone 'UTC'
         and p.created_at<v_start),
      (select count(*) from public.bike_route_prices p where p.created_at>=v_start
         and p.created_at<v_end)
  ), usage as (
    select sku,sum(before_count) before_count,sum(today_count) today_count
      from all_usage group by sku
  )
  select coalesce(sum((greatest(u.before_count+u.today_count-r.free_monthly,0)
      -greatest(u.before_count-r.free_monthly,0))*r.usd_per_1000/1000),0)
    into v_google_other from sku_rates r left join usage u on u.sku=r.sku;
  -- Unknown exchange rate must not turn billable USD usage into a false zero.
  if v_fx is null and (v_billable>0 or v_google_other>0
      or v_settings.supabase_plan<>'free') then return null; end if;
  v_google_other:=coalesce(round(v_google_other*v_fx,2),0);

  select coalesce(sum(least(h.amount_ngn*v_settings.paystack_percent/100
    +case when h.amount_ngn<v_settings.paystack_flat_waiver_below_ngn then 0
      else v_settings.paystack_flat_ngn end,v_settings.paystack_fee_cap_ngn)),0)
    into v_paystack_model from public.customer_payment_holds h
    where h.provider='paystack' and h.status='paid'
      and h.updated_at>=v_start and h.updated_at<v_end;
  v_paystack_model:=round(v_paystack_model,2);
  select coalesce(sum(amount_ngn) filter(where source='google_route_matrix'),0),
    coalesce(sum(amount_ngn) filter(where source='paystack_payment'),0),
    coalesce(sum(amount_ngn) filter(where source='supabase'),0),
    coalesce(sum(amount_ngn) filter(where source in ('sms_delivery','other')),0)
    into v_google_recorded,v_paystack_recorded,v_supabase_recorded,v_other_recorded
    from public.admin_operating_costs where cost_day=v_day;
  v_extra:=public.supabase_overage_daily_estimate_ngn();
  v_supabase_model:=v_supabase_model+coalesce(v_extra,0);
  v_cost:=greatest(v_google_recorded,v_google_matrix+v_google_other)
    +greatest(v_paystack_recorded,v_paystack_model)
    +greatest(v_supabase_recorded,v_supabase_model)+v_other_recorded;
  return round((v_available-v_cost)*100/v_revenue,2);
end $$;
revoke all on function public.admin_alarm_estimated_margin() from public,anon,authenticated;
grant execute on function public.admin_alarm_estimated_margin() to service_role;

create function public.admin_alarm_transition_margin(p_day date,p_margin numeric)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_state public.admin_alarm_margin_state%rowtype;
begin
  if auth.role() is distinct from 'service_role' then
    raise insufficient_privilege using message='Alarm worker access required';
  end if;
  if p_day is null or p_day<>(now() at time zone 'UTC')::date
      or (p_margin is not null and abs(p_margin)>100000) then
    raise check_violation using message='Invalid alarm margin sample';
  end if;
  insert into public.admin_alarm_margin_state(alarm_day,evaluated_at)
    values(p_day,'epoch'::timestamptz) on conflict(alarm_day) do nothing;
  select * into v_state from public.admin_alarm_margin_state
    where alarm_day=p_day for update;
  if p_margin is not null and p_margin<=10 and not v_state.below_threshold then
    insert into public.admin_alarm_margin_events(alarm_day,margin_percent)
      values(p_day,round(p_margin,2));
  end if;
  update public.admin_alarm_margin_state set evaluated_at=now(),
    below_threshold=(p_margin is not null and p_margin<=10),
    last_margin_percent=round(p_margin,2) where alarm_day=p_day;
end $$;
revoke all on function public.admin_alarm_transition_margin(date,numeric)
  from public,anon,authenticated,service_role;

-- Called only by the server poll. A 5-minute shared cache prevents one cost
-- scan per phone and emits a new event only when the estimate crosses <=10%.
create function public.admin_alarm_refresh_margin() returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_day date:=(now() at time zone 'UTC')::date;
  v_state public.admin_alarm_margin_state%rowtype;v_margin numeric;
begin
  if auth.role() is distinct from 'service_role' then
    raise insufficient_privilege using message='Alarm worker access required';
  end if;
  insert into public.admin_alarm_margin_state(alarm_day,evaluated_at)
    values(v_day,'epoch'::timestamptz) on conflict(alarm_day) do nothing;
  select * into v_state from public.admin_alarm_margin_state
    where alarm_day=v_day for update;
  if v_state.evaluated_at>now()-interval '5 minutes' then return; end if;
  v_margin:=public.admin_alarm_estimated_margin();
  perform public.admin_alarm_transition_margin(v_day,v_margin);
end $$;
revoke all on function public.admin_alarm_refresh_margin() from public,anon,authenticated;
grant execute on function public.admin_alarm_refresh_margin() to service_role;

create function public.admin_alarm_current_margin() returns numeric
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_day date:=(now() at time zone 'UTC')::date;
  v_evaluated timestamptz;v_margin numeric;
begin
  if auth.role() is distinct from 'service_role' then
    raise insufficient_privilege using message='Alarm worker access required';
  end if;
  select evaluated_at,last_margin_percent into v_evaluated,v_margin
    from public.admin_alarm_margin_state where alarm_day=v_day;
  if v_evaluated is not null and v_evaluated>now()-interval '5 minutes' then
    return v_margin;
  end if;
  perform public.admin_alarm_refresh_margin();
  select last_margin_percent into v_margin from public.admin_alarm_margin_state
    where alarm_day=v_day;
  return v_margin;
end $$;
revoke all on function public.admin_alarm_current_margin() from public,anon,authenticated;
grant execute on function public.admin_alarm_current_margin() to service_role;

create function public.admin_poll_alarm_device(p_device_id uuid,p_secret text,
  p_ack_ids uuid[] default '{}'::uuid[]) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
declare v_device public.admin_alarm_devices%rowtype;v_alerts jsonb;v_now timestamptz:=now();
begin
  if auth.role() is distinct from 'service_role' then
    raise insufficient_privilege using message='Alarm worker access required';
  end if;
  if p_device_id is null or p_secret is null or p_secret !~ '^[A-Za-z0-9_-]{43}$'
      or p_ack_ids is null or array_length(p_ack_ids,1)>20 then
    return jsonb_build_object('error','unauthorized');
  end if;
  select * into v_device from public.admin_alarm_devices
    where device_id=p_device_id for update;
  if not found or v_device.revoked_at is not null or v_device.secret_hash is null
    or v_device.secret_hash<>extensions.digest(p_secret,'sha256') then
    return jsonb_build_object('error','unauthorized');
  end if;
  if not public.has_role(v_device.user_id,'admin') then
    update public.admin_alarm_devices set revoked_at=v_now,secret_hash=null
      where device_id=p_device_id;
    return jsonb_build_object('error','revoked');
  end if;
  if v_device.last_poll_at is not null and v_device.last_poll_at>v_now-interval '30 seconds' then
    return jsonb_build_object('error','rate_limited');
  end if;
  update public.admin_alarm_devices set last_poll_at=v_now where device_id=p_device_id;
  insert into public.admin_alarm_acknowledgements(device_id,event_id)
    select p_device_id,x.event_id from unnest(p_ack_ids) as x(event_id)
    where exists(select 1 from public.admin_alarm_margin_events m where m.id=x.event_id)
      or exists(select 1 from public.admin_traffic_alerts a
        where md5(a.id::text||':'||a.severity)::uuid=x.event_id)
    on conflict do nothing;
  perform public.admin_alarm_current_margin();
  with pending as (
    select md5(a.id::text||':'||a.severity)::uuid as id,
      'spike'::text as type,a.severity,
      'Kwik-Parsel service spike'::text as title,
      left(a.source||': '||a.cause,220) as body,a.detected_at
    from public.admin_traffic_alerts a
    where a.resolved_at is null
      and not exists(select 1 from public.admin_alarm_acknowledgements ack
        where ack.device_id=p_device_id
          and ack.event_id=md5(a.id::text||':'||a.severity)::uuid)
      and not exists(select 1 from public.admin_traffic_acknowledgements ack
        where ack.user_id=v_device.user_id and ack.alert_id=a.id)
    union all
    select m.id,'margin'::text,'critical'::text,
      'Kwik-Parsel spending warning'::text,
      'Estimated profit margin is '||m.margin_percent||'%, at or below the 10% warning level.',
      m.detected_at
    from public.admin_alarm_margin_events m
    where exists(select 1 from public.admin_alarm_margin_state s
      where s.alarm_day=m.alarm_day and s.below_threshold)
      and m.id=(select latest.id from public.admin_alarm_margin_events latest
        where latest.alarm_day=m.alarm_day order by latest.detected_at desc limit 1)
      and m.detected_at>=v_now-interval '24 hours'
      and not exists(select 1 from public.admin_alarm_acknowledgements ack
        where ack.device_id=p_device_id and ack.event_id=m.id)
  )
  select coalesce(jsonb_agg(to_jsonb(q) order by q.detected_at desc),'[]'::jsonb)
    into v_alerts from (select * from pending order by detected_at desc,id desc limit 20) q;
  return jsonb_build_object('alerts',v_alerts,'checked_at',v_now);
end $$;
revoke all on function public.admin_poll_alarm_device(uuid,text,uuid[]) from public,anon,authenticated;
grant execute on function public.admin_poll_alarm_device(uuid,text,uuid[]) to service_role;

-- The old FCM worker is disabled, so no Firebase request is made after rollout.
update public.admin_spike_push_config set enabled=false,updated_at=now() where singleton;
drop trigger if exists admin_spike_alert_enqueue_push on public.admin_traffic_alerts;
do $$ begin
  if exists(select 1 from cron.job where jobname='kwik-parsel-admin-spike-push') then
    perform cron.unschedule('kwik-parsel-admin-spike-push');
  end if;
end $$;
