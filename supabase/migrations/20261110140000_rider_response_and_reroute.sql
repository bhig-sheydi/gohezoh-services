-- A paid rider assignment needs an explicit, short response window.
create table public.rider_assignment_responses (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs(id) on delete cascade,
  rider_id uuid not null references auth.users(id),
  partner_id uuid not null references public.logistics_partners(id),
  assigned_at timestamptz not null default now(),
  deadline_at timestamptz not null default (now()+interval '1 minute'),
  accepted_at timestamptz,
  timed_out_at timestamptz,
  unique(job_id,rider_id,assigned_at)
);
create unique index rider_response_one_open on public.rider_assignment_responses(job_id)
  where accepted_at is null and timed_out_at is null;
create index rider_response_due on public.rider_assignment_responses(deadline_at)
  where accepted_at is null and timed_out_at is null;
alter table public.rider_assignment_responses enable row level security;
revoke all on public.rider_assignment_responses from public,anon,authenticated;

create function public.track_rider_assignment_response() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.assigned_rider_id is not null and new.status in ('partner_assigned','pickup_scheduled')
    and (tg_op='INSERT' or new.assigned_rider_id is distinct from old.assigned_rider_id) then
    update public.rider_assignment_responses set timed_out_at=now()
      where job_id=new.id and accepted_at is null and timed_out_at is null;
    insert into public.rider_assignment_responses(job_id,rider_id,partner_id)
      values(new.id,new.assigned_rider_id,new.partner_id);
  end if;
  return new;
end $$;
create trigger track_rider_assignment_response after insert or update of assigned_rider_id on public.jobs
  for each row execute function public.track_rider_assignment_response();

create or replace function public.enqueue_rider_assignment_push() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.assigned_rider_id is null or new.status in ('delivered','closed','cancelled')
    or (tg_op='UPDATE' and new.assigned_rider_id is not distinct from old.assigned_rider_id) then return new; end if;
  insert into public.ride_push_deliveries(device_id,event_type,source_id,expires_at)
    select d.id,'rider_assignment',new.id,now()+interval '1 minute'
    from public.ride_push_devices d where d.user_id=new.assigned_rider_id and d.kind='rider'
      and d.last_seen_at>now()-interval '30 days'
    on conflict(device_id,event_type,source_id) do update set status='pending',
      next_attempt_at=now(),expires_at=excluded.expires_at;
  return new;
end $$;

create function public.accept_rider_assignment(p_job_id uuid) returns boolean
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_response public.rider_assignment_responses%rowtype;
begin
  if auth.uid() is null or not public.rider_session_active() then
    raise insufficient_privilege using message='Rider sign-in required';
  end if;
  select r.* into v_response from public.rider_assignment_responses r
    join public.jobs j on j.id=r.job_id and j.assigned_rider_id=r.rider_id
    where r.job_id=p_job_id and r.rider_id=auth.uid() and r.timed_out_at is null
      and j.status in ('partner_assigned','pickup_scheduled')
    order by r.assigned_at desc limit 1 for update of r;
  if not found then return false; end if;
  if v_response.accepted_at is not null then return true; end if;
  if v_response.deadline_at<=now() then return false; end if;
  update public.rider_assignment_responses set accepted_at=now() where id=v_response.id;
  return true;
end $$;
revoke all on function public.accept_rider_assignment(uuid) from public,anon;
grant execute on function public.accept_rider_assignment(uuid) to authenticated;

create function public.require_rider_response_before_pickup() returns trigger
language plpgsql set search_path=pg_catalog,public as $$
begin
  if new.status in ('picked_up','in_transit') and old.status in ('partner_assigned','pickup_scheduled')
    and exists(select 1 from public.rider_assignment_responses r where r.job_id=new.id
      and r.rider_id=new.assigned_rider_id and r.accepted_at is null) then
    raise check_violation using message='Rider must accept the ride before collecting the parcel';
  end if;
  return new;
end $$;
create trigger require_rider_response_before_pickup before update of status on public.jobs
  for each row execute function public.require_rider_response_before_pickup();

-- The current company remains liable for the paid order. Only its own eligible
-- rider may replace a non-responding rider; never silently change the quote.
create function public.resolve_missed_rider_assignments() returns integer
language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
declare v_response record; v_next uuid; v_request uuid; v_lat double precision; v_lon double precision;
  v_count integer:=0;
begin
  for v_response in select r.id,r.job_id,r.rider_id,r.partner_id,j.customer_id,j.job_number
    from public.rider_assignment_responses r join public.jobs j on j.id=r.job_id
    where r.accepted_at is null and r.timed_out_at is null and r.deadline_at<=now()
    order by r.deadline_at limit 50 for update of r skip locked
  loop
    update public.rider_assignment_responses set timed_out_at=now() where id=v_response.id;
    if not exists(select 1 from public.jobs j where j.id=v_response.job_id
      and j.assigned_rider_id=v_response.rider_id and j.status in ('partner_assigned','pickup_scheduled')) then continue; end if;
    select r.id,r.pickup_latitude,r.pickup_longitude into v_request,v_lat,v_lon
      from public.jobs j join public.orders o on o.id=j.order_id
      join public.service_requests r on r.id=o.service_request_id where j.id=v_response.job_id;
    select rp.user_id into v_next from public.rider_presence rp
      join public.rider_credentials rc on rc.user_id=rp.user_id and rc.partner_id=v_response.partner_id
        and rc.revoked_at is null and rc.password_revoked_at is null and rc.load_state<>'full'
      join public.company_riders cr on cr.id=rc.roster_id and cr.status='approved'
      join public.partner_users pu on pu.user_id=rp.user_id and pu.partner_id=rp.partner_id and pu.membership_role='rider'
      where rp.partner_id=v_response.partner_id and rp.user_id<>v_response.rider_id
        and rp.received_at>now()-interval '2 minutes' and rp.captured_at>now()-interval '2 minutes'
        and rp.accuracy_metres<=100 and v_lat is not null and v_lon is not null
        and extensions.st_dwithin(rp.position,
          extensions.st_setsrid(extensions.st_makepoint(v_lon,v_lat),4326)::extensions.geography,5000)
        and not exists(select 1 from public.rider_assignment_responses old
          where old.job_id=v_response.job_id and old.rider_id=rp.user_id)
      order by (rc.load_state='almost_full'),extensions.st_distance(rp.position,
        extensions.st_setsrid(extensions.st_makepoint(v_lon,v_lat),4326)::extensions.geography)
      limit 1;
    begin
      update public.jobs set assigned_rider_id=v_next,
        route_assignment_issue=case when v_next is null then 'Rider missed response; no eligible replacement in the selected company' else null end
        where id=v_response.job_id and assigned_rider_id=v_response.rider_id
          and status in ('partner_assigned','pickup_scheduled');
    exception when check_violation then
      v_next:=null;
      update public.jobs set assigned_rider_id=null,
        route_assignment_issue='Rider missed response; replacement requires company resolution'
        where id=v_response.job_id and assigned_rider_id=v_response.rider_id;
    end;
    -- Alert company management and bid-enabled operations staff on their phones.
    insert into public.ride_push_deliveries(device_id,event_type,source_id,expires_at)
      select d.id,'rider_missed',v_response.job_id,now()+interval '1 hour'
      from public.ride_push_devices d where d.kind='company' and d.last_seen_at>now()-interval '30 days'
        and (exists(select 1 from public.partner_users pu where pu.user_id=d.user_id
          and pu.partner_id=v_response.partner_id and pu.membership_role='manager')
        or exists(select 1 from public.company_operations_staff s where s.user_id=d.user_id
          and s.partner_id=v_response.partner_id and s.can_bid and s.revoked_at is null and s.password_revoked_at is null))
      on conflict(device_id,event_type,source_id) do nothing;
    insert into public.notifications(user_id,job_id,event_type,channel,title,body,payload,status,sent_at)
      select u.user_id,v_response.job_id,'rider_missed','in_app','Rider missed a new ride',
        case when v_next is null then 'No eligible replacement is available. The job is no longer counted in pending earnings; arrange a resolution.'
          else 'Another company rider has been assigned. Open the rider list to check the new rider.' end,
        jsonb_build_object('replacement_rider_id',v_next),'delivered',now()
      from (select pu.user_id from public.partner_users pu where pu.partner_id=v_response.partner_id and pu.membership_role='manager'
        union select s.user_id from public.company_operations_staff s where s.partner_id=v_response.partner_id
          and s.can_bid and s.revoked_at is null and s.password_revoked_at is null) u;
    perform public.notify_customer_users(v_response.customer_id,v_response.job_id,
      'rider_assignment_changed','Your rider has changed',
      case when v_next is null then 'Your assigned rider did not respond. The company is finding a replacement; do not hand over the parcel yet.'
        else 'Your assigned rider did not respond. Another rider from the same company is coming. Open tracking for the updated rider.' end,
      jsonb_build_object('replacement_rider_id',v_next));
    v_count:=v_count+1;
  end loop;
  return v_count;
end $$;
revoke all on function public.resolve_missed_rider_assignments() from public,anon,authenticated;
grant execute on function public.resolve_missed_rider_assignments() to service_role;
alter table public.ride_push_deliveries drop constraint ride_push_deliveries_event_type_check;
alter table public.ride_push_deliveries add constraint ride_push_deliveries_event_type_check
  check(event_type in ('company_invitation','rider_assignment','customer_match','rider_missed'));
select cron.schedule('kwik-parsel-rider-response','15 seconds',
  $$select public.resolve_missed_rider_assignments()$$);

-- Show only the currently assigned rider's response state in the existing snapshot.
create function public.my_rider_assignment_responses() returns jsonb
language sql stable security definer set search_path=pg_catalog,public as $$
  select coalesce(jsonb_agg(jsonb_build_object('job_id',r.job_id,'deadline_at',r.deadline_at,
    'accepted_at',r.accepted_at)),'[]'::jsonb)
  from public.rider_assignment_responses r join public.jobs j on j.id=r.job_id
  where r.rider_id=auth.uid() and j.assigned_rider_id=auth.uid()
    and r.timed_out_at is null and j.status in ('partner_assigned','pickup_scheduled')
    and public.rider_session_active();
$$;
revoke all on function public.my_rider_assignment_responses() from public,anon;
grant execute on function public.my_rider_assignment_responses() to authenticated;

create function public.my_company_rider_miss_alerts() returns table(job_number text,body text,created_at timestamptz)
language sql stable security definer set search_path=pg_catalog,public as $$
  select j.job_number,n.body,n.created_at from public.notifications n
    join public.jobs j on j.id=n.job_id
    where n.user_id=auth.uid() and n.event_type='rider_missed'
      and public.company_staff_allowed(j.partner_id,'bid')
    order by n.created_at desc limit 5;
$$;
revoke all on function public.my_company_rider_miss_alerts() from public,anon;
grant execute on function public.my_company_rider_miss_alerts() to authenticated;

create function public.my_current_delivery_rider(p_job_id uuid) returns jsonb
language sql stable security definer set search_path=pg_catalog,public as $$
  select jsonb_build_object('name',coalesce(cr.full_name,rc.rider_name),'phone',cr.phone,
    'status',case when j.assigned_rider_id is null then 'finding_replacement'
      when rr.id is not null and rr.accepted_at is null then 'awaiting_response' else 'on_the_way' end,
    'issue',j.route_assignment_issue)
  from public.jobs j join public.orders o on o.id=j.order_id
  left join public.rider_credentials rc on rc.user_id=j.assigned_rider_id
  left join public.company_riders cr on cr.id=rc.roster_id
  left join public.rider_assignment_responses rr on rr.job_id=j.id and rr.rider_id=j.assigned_rider_id
    and rr.timed_out_at is null
  where j.id=p_job_id and public.is_customer_user(j.customer_id)
    and (exists(select 1 from public.customer_payment_holds h where h.request_id=o.service_request_id and h.status='paid')
      or exists(select 1 from public.customer_payments cp where cp.job_id=j.id and cp.status='received'));
$$;
revoke all on function public.my_current_delivery_rider(uuid) from public,anon;
grant execute on function public.my_current_delivery_rider(uuid) to authenticated;

create or replace function public.my_rider_dashboard_snapshot() returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public,auth as $$
declare v_has_role boolean;v_active boolean;
begin
  if auth.role() is distinct from 'authenticated' or auth.uid() is null then
    raise insufficient_privilege using message='Rider sign-in required'; end if;
  v_has_role:=public.has_role(auth.uid(),'rider');
  v_active:=v_has_role and public.rider_session_active();
  if not v_active then return jsonb_build_object('has_role',v_has_role,'session_active',false,
    'jobs','[]'::jsonb,'profile','[]'::jsonb,'pickup_locations','[]'::jsonb,
    'delivery_locations','[]'::jsonb,'selected_pickups','[]'::jsonb,'next_stop','[]'::jsonb,
    'assignment_responses','[]'::jsonb); end if;
  return jsonb_build_object('has_role',true,'session_active',true,
    'jobs',(select coalesce(jsonb_agg(to_jsonb(t)-'ordinality' order by t.ordinality),'[]'::jsonb)
      from public.list_my_rider_jobs() with ordinality as t),
    'profile',(select coalesce(jsonb_agg(to_jsonb(t)-'ordinality' order by t.ordinality),'[]'::jsonb)
      from public.my_rider_profile() with ordinality as t),
    'pickup_locations',(select coalesce(jsonb_agg(to_jsonb(t)-'ordinality' order by t.ordinality),'[]'::jsonb)
      from public.list_my_rider_pickup_locations() with ordinality as t),
    'delivery_locations',(select coalesce(jsonb_agg(to_jsonb(t)-'ordinality' order by t.ordinality),'[]'::jsonb)
      from public.list_my_rider_delivery_locations() with ordinality as t),
    'selected_pickups',(select coalesce(jsonb_agg(to_jsonb(t)-'ordinality' order by t.ordinality),'[]'::jsonb)
      from public.list_my_selected_pickups() with ordinality as t),
    'next_stop',(select coalesce(jsonb_agg(to_jsonb(t)-'ordinality' order by t.ordinality),'[]'::jsonb)
      from public.my_rider_next_stop() with ordinality as t),
    'assignment_responses',public.my_rider_assignment_responses());
end $$;

create or replace function public.get_my_partner_payables()
returns table(partner_id uuid,currency text,available_ngn numeric,pending_delivery_ngn numeric,
  withdrawal_pending_ngn numeric,total_paid_ngn numeric)
language sql stable security definer set search_path=pg_catalog,public as $$
  with mine as (
    select p.id from public.logistics_partners p join public.partner_users pu on pu.partner_id=p.id
    where pu.user_id=auth.uid() and public.company_staff_allowed(p.id,'withdraw') and p.status='active'
  ), fees as (
    select j.id job_id,j.partner_id,j.status,j.assigned_rider_id,j.route_assignment_issue,f.partner_cost,
      coalesce((select sum(cp.amount) from public.customer_payments cp
        where cp.job_id=j.id and cp.status='received' and cp.currency='NGN'),0) received,
      f.customer_revenue
    from public.jobs j join mine m on m.id=j.partner_id
    join public.job_financials f on f.job_id=j.id and f.currency='NGN'
    where (j.status<>'cancelled' or exists(select 1 from public.paid_booking_cancellations pc
      where pc.job_id=j.id and pc.status='processed'))
  ), commitments as (
    select s.job_id,
      coalesce(sum(s.amount) filter (where s.status<>'cancelled'),0) committed,
      coalesce(sum(s.amount) filter (where s.status in ('pending','approved') and s.withdrawal_id is not null),0) withdrawal_pending,
      coalesce(sum(s.amount) filter (where s.status='paid'),0) paid
    from public.partner_settlements s join fees f on f.job_id=s.job_id group by s.job_id
  )
  select m.id,'NGN'::text,
    coalesce(sum(greatest(f.partner_cost-coalesce(c.committed,0),0)) filter
      (where f.status in ('delivered','closed','cancelled') and f.received>=f.customer_revenue),0)::numeric,
    coalesce(sum(f.partner_cost) filter
      (where f.status not in ('delivered','closed','cancelled') and f.received>=f.customer_revenue
        and (f.assigned_rider_id is not null or f.route_assignment_issue is null)),0)::numeric,
    coalesce(sum(c.withdrawal_pending),0)::numeric,
    coalesce(sum(c.paid),0)::numeric
  from mine m left join fees f on f.partner_id=m.id
  left join commitments c on c.job_id=f.job_id group by m.id;
$$;
