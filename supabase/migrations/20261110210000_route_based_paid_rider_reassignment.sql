-- A missed paid pickup must use the same road-based rider planner as initial matching.
-- Keep the accepted company and customer price; only its rider changes.
alter table public.route_planner_events drop constraint route_planner_events_event_kind_check;
alter table public.route_planner_events add constraint route_planner_events_event_kind_check
  check (event_kind in ('shadow_invitation','route_commit','replan','live_invitation','paid_reassignment'));

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
      and j.assigned_rider_id=v_response.rider_id and j.status in ('partner_assigned','pickup_scheduled')) then continue; end if;
    select o.service_request_id into v_request from public.jobs j
      join public.orders o on o.id=j.order_id where j.id=v_response.job_id;
    update public.jobs set assigned_rider_id=null,
      route_assignment_issue='Rider missed response; searching for a route-matched replacement'
      where id=v_response.job_id and assigned_rider_id=v_response.rider_id
        and status in ('partner_assigned','pickup_scheduled');
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
      on conflict(device_id,event_type,source_id) do nothing;
    insert into public.notifications(user_id,job_id,event_type,channel,title,body,payload,status,sent_at)
      select u.user_id,v_response.job_id,'rider_missed','in_app','Rider missed a new ride',
        'The rider did not respond. Route-based replacement search is running; the job is not counted in pending earnings while unassigned.',
        jsonb_build_object('replacement_search',true),'delivered',now()
      from (select pu.user_id from public.partner_users pu where pu.partner_id=v_response.partner_id and pu.membership_role='manager'
        union select s.user_id from public.company_operations_staff s where s.partner_id=v_response.partner_id
          and s.can_bid and s.revoked_at is null and s.password_revoked_at is null) u;
    perform public.notify_customer_users(v_response.customer_id,v_response.job_id,
      'rider_assignment_changed','Finding another rider',
      'Your rider did not respond. We are finding another rider; do not hand over the parcel yet.',
      jsonb_build_object('replacement_search',true));
    v_count:=v_count+1;
  end loop;
  return v_count;
end $$;

create function public.paid_reassignment_context(p_request uuid) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_result jsonb;
begin
  if auth.role()<>'service_role' then raise insufficient_privilege using message='Routing worker access required'; end if;
  select jsonb_build_object('job_id',j.id,'partner_id',j.partner_id,
    'pickup_latitude',r.pickup_latitude,'pickup_longitude',r.pickup_longitude,
    'dropoff_latitude',r.delivery_latitude,'dropoff_longitude',r.delivery_longitude)
    into v_result from public.jobs j join public.orders o on o.id=j.order_id
    join public.service_requests r on r.id=o.service_request_id
    join public.customer_payments cp on cp.job_id=j.id
    where r.id=p_request and j.status in ('partner_assigned','pickup_scheduled')
      and j.assigned_rider_id is null and cp.status='received' and cp.currency='NGN'
      and not exists(select 1 from public.pickup_handoff_codes h where h.job_id=j.id and h.verified_at is not null);
  return v_result;
end $$;
revoke all on function public.paid_reassignment_context(uuid) from public,anon,authenticated;
grant execute on function public.paid_reassignment_context(uuid) to service_role;

create function public.assign_paid_replacement_rider(p_job uuid,p_rider uuid,p_partner uuid) returns boolean
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_job public.jobs%rowtype; v_request uuid; v_context jsonb;
begin
  if auth.role()<>'service_role' then raise insufficient_privilege using message='Routing worker access required'; end if;
  select * into v_job from public.jobs where id=p_job for update;
  if not found or v_job.partner_id is distinct from p_partner or v_job.assigned_rider_id is not null
    or v_job.status not in ('partner_assigned','pickup_scheduled') then return false; end if;
  select o.service_request_id into v_request from public.orders o where o.id=v_job.order_id;
  v_context:=public.paid_reassignment_context(v_request);
  if v_context is null or (v_context->>'job_id')::uuid<>p_job then return false; end if;
  if exists(select 1 from public.rider_assignment_responses r where r.job_id=p_job and r.rider_id=p_rider) then return false; end if;
  if not exists(select 1 from public.route_planner_candidates(v_request) c
    where c.rider_id=p_rider and c.partner_id=p_partner) then return false; end if;
  begin
    update public.jobs set assigned_rider_id=p_rider,route_assignment_issue=null where id=p_job;
  exception when check_violation or unique_violation then return false;
  end;
  perform public.notify_customer_users(v_job.customer_id,p_job,
    'rider_assignment_changed','New rider assigned',
    'Another rider is coming for your parcel. Open tracking to see their details.',
    jsonb_build_object('replacement_rider_id',p_rider));
  return true;
end $$;
revoke all on function public.assign_paid_replacement_rider(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.assign_paid_replacement_rider(uuid,uuid,uuid) to service_role;

-- Recheck only paid, uncollected jobs without a rider. A fresh rider may come
-- online after the first search; no database or Maps work runs for other jobs.
create function public.enqueue_unassigned_paid_replacements() returns integer
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_count integer;
begin
  insert into public.route_planner_events(request_id,event_kind,idempotency_key)
    select o.service_request_id,'paid_reassignment',
      'paid-retry:'||j.id::text||':'||floor(extract(epoch from now())/60)::bigint::text
    from public.jobs j join public.orders o on o.id=j.order_id
    where j.assigned_rider_id is null and j.route_assignment_issue like 'Rider missed response%'
      and j.status in ('partner_assigned','pickup_scheduled')
      and exists(select 1 from public.customer_payments cp where cp.job_id=j.id
        and cp.status='received' and cp.currency='NGN')
      and not exists(select 1 from public.pickup_handoff_codes h where h.job_id=j.id and h.verified_at is not null)
    order by j.updated_at limit 50
    on conflict(idempotency_key) do nothing;
  get diagnostics v_count=row_count;
  return v_count;
end $$;
revoke all on function public.enqueue_unassigned_paid_replacements() from public,anon,authenticated;
grant execute on function public.enqueue_unassigned_paid_replacements() to service_role;
select cron.schedule('kwik-parsel-paid-rider-retry','* * * * *',
  $$select public.enqueue_unassigned_paid_replacements()$$);
