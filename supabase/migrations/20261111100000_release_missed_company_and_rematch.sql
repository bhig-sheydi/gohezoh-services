-- A missed rider forfeits the company's uncollected paid booking immediately.
-- The paid job returns to network matching with no partner reservation or
-- pending company payout. The already-collected customer payment is unchanged.
create or replace function public.resolve_missed_rider_assignments() returns integer
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_response record; v_request uuid; v_count integer:=0;
begin
  for v_response in select r.id,r.job_id,r.rider_id,r.partner_id,j.customer_id,j.job_number
    from public.rider_assignment_responses r join public.jobs j on j.id=r.job_id
    where r.accepted_at is null and r.timed_out_at is null and r.deadline_at<=now()
    order by r.deadline_at limit 50 for update of r skip locked
  loop
    update public.rider_assignment_responses set timed_out_at=now() where id=v_response.id;
    if not exists(select 1 from public.jobs j where j.id=v_response.job_id
      and j.assigned_rider_id=v_response.rider_id and j.partner_id=v_response.partner_id
      and j.status in ('partner_assigned','pickup_scheduled')) then continue; end if;
    select o.service_request_id into v_request from public.jobs j
      join public.orders o on o.id=j.order_id where j.id=v_response.job_id;
    update public.partner_assignments set status='cancelled',responded_at=now(),
      response_note='Rider did not accept within one minute; company forfeited the paid pickup'
      where job_id=v_response.job_id and partner_id=v_response.partner_id and status='accepted';
    update public.jobs set
      status=case when status='pickup_scheduled' then 'partner_assigned'::public.job_state else status end,
      assigned_rider_id=null,partner_id=null,
      route_assignment_issue='Rider missed response; searching the network for another company'
      where id=v_response.job_id and assigned_rider_id=v_response.rider_id
        and partner_id=v_response.partner_id and status in ('partner_assigned','pickup_scheduled');
    if v_request is not null then
      insert into public.route_planner_events(request_id,event_kind,idempotency_key)
        values(v_request,'paid_reassignment','paid-reassign:'||v_response.id::text)
        on conflict(idempotency_key) do nothing;
    end if;
    insert into public.ride_push_deliveries(device_id,event_type,source_id,expires_at)
      select d.id,'rider_missed',v_response.job_id,now()+interval '1 hour'
      from public.ride_push_devices d where d.kind='company' and d.last_seen_at>now()-interval '30 days'
        and (exists(select 1 from public.partner_users pu where pu.user_id=d.user_id
          and pu.partner_id=v_response.partner_id and pu.membership_role='manager')
        or exists(select 1 from public.company_operations_staff s where s.user_id=d.user_id
          and s.partner_id=v_response.partner_id and s.can_bid and s.revoked_at is null and s.password_revoked_at is null))
      on conflict(device_id,event_type,source_id) do update set status='pending',
        next_attempt_at=now(),expires_at=excluded.expires_at;
    insert into public.notifications(user_id,job_id,event_type,channel,title,body,payload,status,sent_at)
      select u.user_id,v_response.job_id,'rider_missed','in_app','Paid pickup lost',
        'Your rider did not respond in time. This job was removed from your company and its pending payout was deducted.',
        jsonb_build_object('forfeited_partner_id',v_response.partner_id),'delivered',now()
      from (select pu.user_id from public.partner_users pu where pu.partner_id=v_response.partner_id and pu.membership_role='manager'
        union select s.user_id from public.company_operations_staff s where s.partner_id=v_response.partner_id
          and s.can_bid and s.revoked_at is null and s.password_revoked_at is null) u;
    perform public.notify_customer_users(v_response.customer_id,v_response.job_id,
      'rider_assignment_changed','Finding another company and rider',
      'Your rider did not respond. We are finding another company and rider; do not hand over the parcel yet.',
      jsonb_build_object('replacement_search',true));
    v_count:=v_count+1;
  end loop;
  return v_count;
end $$;

-- Existing jobs stranded by the older same-company search must also lose
-- their old company reservation, without touching collected parcels.
update public.partner_assignments a set status='cancelled',responded_at=now(),
  response_note='Rider missed response; company forfeited the paid pickup'
from public.jobs j where a.job_id=j.id and a.partner_id=j.partner_id and a.status='accepted'
  and j.assigned_rider_id is null and j.route_assignment_issue like 'Rider missed response%'
  and j.status='partner_assigned'
  and not exists(select 1 from public.pickup_handoff_codes h where h.job_id=j.id and h.verified_at is not null);
update public.jobs j set partner_id=null,
  route_assignment_issue='Rider missed response; searching the network for another company'
where j.partner_id is not null and j.assigned_rider_id is null
  and j.route_assignment_issue like 'Rider missed response%'
  and j.status='partner_assigned'
  and not exists(select 1 from public.pickup_handoff_codes h where h.job_id=j.id and h.verified_at is not null);

create or replace function public.paid_reassignment_context(p_request uuid) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_result jsonb;
begin
  if auth.role()<>'service_role' then raise insufficient_privilege using message='Routing worker access required'; end if;
  select jsonb_build_object('job_id',j.id,
    'pickup_latitude',r.pickup_latitude,'pickup_longitude',r.pickup_longitude,
    'dropoff_latitude',r.delivery_latitude,'dropoff_longitude',r.delivery_longitude)
    into v_result from public.jobs j join public.orders o on o.id=j.order_id
    join public.service_requests r on r.id=o.service_request_id
    join public.customer_payments cp on cp.job_id=j.id
    where r.id=p_request and j.status='partner_assigned' and j.partner_id is null
      and j.assigned_rider_id is null and cp.status='received' and cp.currency='NGN'
      and j.route_assignment_issue like 'Rider missed response%'
      and not exists(select 1 from public.partner_assignments a where a.job_id=j.id and a.status='accepted')
      and not exists(select 1 from public.pickup_handoff_codes h where h.job_id=j.id and h.verified_at is not null);
  return v_result;
end $$;

create or replace function public.my_company_rider_miss_alerts() returns table(job_number text,body text,created_at timestamptz)
language sql stable security definer set search_path=pg_catalog,public as $$
  select j.job_number,n.body,n.created_at from public.notifications n
    join public.jobs j on j.id=n.job_id
    where n.user_id=auth.uid() and n.event_type='rider_missed'
      and (exists(select 1 from public.partner_users pu where pu.user_id=auth.uid()
        and pu.partner_id=(n.payload->>'forfeited_partner_id')::uuid and pu.membership_role='manager')
      or exists(select 1 from public.company_operations_staff s where s.user_id=auth.uid()
        and s.partner_id=(n.payload->>'forfeited_partner_id')::uuid and s.can_bid
        and s.revoked_at is null and s.password_revoked_at is null))
    order by n.created_at desc limit 5;
$$;

-- Even a different rider from the forfeited company cannot receive this job.
do $$
declare v_definition text; v_revised text;
begin
  select pg_get_functiondef('public.offer_paid_reassignment(uuid,uuid,uuid,integer,double precision)'::regprocedure)
    into v_definition;
  v_revised:=replace(v_definition,
    'if exists(select 1 from public.rider_assignment_responses r where r.job_id=p_job and r.rider_id=p_rider) then return false; end if;',
    'if exists(select 1 from public.rider_assignment_responses r where r.job_id=p_job'
      ||' and (r.rider_id=p_rider or r.partner_id=p_partner)) then return false; end if;');
  if v_revised=v_definition then raise exception 'Paid offer exclusion guard was not found'; end if;
  execute v_revised;
end $$;

-- Company acceptance must recheck the same exclusion, not just the rider ID.
do $$
declare v_definition text; v_revised text;
begin
  select pg_get_functiondef('public.respond_paid_reassignment_offer(uuid,boolean)'::regprocedure)
    into v_definition;
  v_revised:=replace(v_definition,
    'where r.job_id=v_job.id and r.rider_id=v_offer.rider_id)',
    'where r.job_id=v_job.id and (r.rider_id=v_offer.rider_id or r.partner_id=v_offer.partner_id))');
  if v_revised=v_definition then raise exception 'Paid acceptance exclusion guard was not found'; end if;
  execute v_revised;
end $$;

-- A forfeiture push belongs to the company named on the timed-out rider
-- response, since the paid job itself has no partner during rematching.
create or replace function public.claim_ride_push_deliveries(p_limit integer default 30)
returns table(delivery_id uuid,event_id uuid,device_token text,event_type text,source_id uuid,expires_at timestamptz,user_id uuid)
language plpgsql security definer set search_path=pg_catalog,public,auth as $$
begin
  if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
  if p_limit not between 1 and 100 then raise check_violation; end if;
  update public.ride_push_deliveries x set status='dead' where x.status in ('pending','sending') and x.expires_at<=now();
  return query with due as (
    select x.id from public.ride_push_deliveries x join public.ride_push_devices d on d.id=x.device_id
      join auth.sessions sess on sess.id=d.session_id and sess.user_id=d.user_id
    where (x.status='pending' and x.next_attempt_at<=now() or x.status='sending' and x.leased_until<now())
      and x.expires_at>now() and d.last_seen_at>now()-interval '30 days'
      and (x.event_type<>'company_invitation' or exists(
        select 1 from public.company_bid_invitations i where i.request_id=x.source_id
          and i.starts_at<=now() and i.deadline_at>now()
          and public.company_staff_actor_allowed(i.partner_id,d.user_id,d.session_id,'bid')))
      and (x.event_type<>'rider_missed' or exists(
        select 1 from public.rider_assignment_responses ar
        where ar.job_id=x.source_id and ar.timed_out_at is not null and d.kind='company'
          and public.company_staff_actor_allowed(ar.partner_id,d.user_id,d.session_id,'bid')))
      and (x.event_type<>'company_reassignment_offer' or exists(
        select 1 from public.paid_reassignment_offers po where po.job_id=x.source_id
          and po.status='pending' and po.expires_at>now() and d.kind='company'
          and public.company_staff_actor_allowed(po.partner_id,d.user_id,d.session_id,'bid')))
      and (x.event_type<>'rider_assignment' or exists(select 1 from public.jobs j
        join public.rider_credentials rc on rc.user_id=j.assigned_rider_id and rc.revoked_at is null
          and rc.password_revoked_at is null
        where j.id=x.source_id and j.assigned_rider_id=d.user_id and j.status not in ('delivered','closed','cancelled')))
      and (x.event_type<>'customer_match' or exists(select 1 from public.service_requests r
        join public.customer_users cu on cu.customer_id=r.customer_id and cu.user_id=d.user_id
        join public.partner_quotes q on q.request_id=r.id and q.status='valid'
        where r.id=x.source_id))
    order by x.next_attempt_at,x.created_at limit p_limit for update of x skip locked
  ), claimed as (
    update public.ride_push_deliveries x set status='sending',attempts=x.attempts+1,
      leased_until=now()+interval '2 minutes' from due where x.id=due.id
    returning x.id,x.event_id,x.device_id,x.event_type,x.source_id,x.expires_at
  ) select c.id,c.event_id,d.fcm_token,c.event_type,c.source_id,c.expires_at,d.user_id
    from claimed c join public.ride_push_devices d on d.id=c.device_id;
end $$;
