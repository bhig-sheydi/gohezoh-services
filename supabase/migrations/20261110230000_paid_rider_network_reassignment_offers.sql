-- Another approved company may take a paid, uncollected job only after it
-- accepts the already-fixed payout. The customer is never charged again.
create table public.paid_reassignment_offers (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs(id) on delete cascade,
  partner_id uuid not null references public.logistics_partners(id),
  rider_id uuid not null references auth.users(id),
  tier integer not null check(tier between 1 and 4),
  score double precision not null,
  status text not null default 'pending' check(status in ('pending','accepted','declined','expired')),
  expires_at timestamptz not null default(now()+interval '1 minute'),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  unique(job_id,partner_id,rider_id)
);
create unique index paid_reassignment_one_pending_per_job on public.paid_reassignment_offers(job_id)
  where status='pending';
create index paid_reassignment_company_pending on public.paid_reassignment_offers(partner_id,expires_at)
  where status='pending';
alter table public.paid_reassignment_offers enable row level security;
revoke all on public.paid_reassignment_offers from public,anon,authenticated;

create function public.offer_paid_reassignment(p_job uuid,p_partner uuid,p_rider uuid,
  p_tier integer,p_score double precision) returns boolean
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_job public.jobs%rowtype; v_request uuid; v_corridor uuid; v_context jsonb;
begin
  if auth.role()<>'service_role' then raise insufficient_privilege using message='Routing worker access required'; end if;
  select * into v_job from public.jobs where id=p_job for update;
  if not found or v_job.assigned_rider_id is not null or v_job.partner_id=p_partner
    or v_job.status not in ('partner_assigned','pickup_scheduled') or p_tier not between 1 and 4 then return false; end if;
  select o.service_request_id into v_request from public.orders o where o.id=v_job.order_id;
  v_context:=public.paid_reassignment_context(v_request);
  if v_context is null then return false; end if;
  select w.corridor_id into v_corridor from public.delivery_quote_windows w where w.request_id=v_request;
  if not exists(select 1 from public.partner_corridor_coverage c
    where c.partner_id=p_partner and c.corridor_id=v_corridor and c.is_enabled and c.capacity_available) then return false; end if;
  if exists(select 1 from public.paid_reassignment_offers x where x.job_id=p_job
    and (x.status='pending' and x.expires_at>now() or x.partner_id=p_partner and x.rider_id=p_rider)) then return false; end if;
  if exists(select 1 from public.rider_assignment_responses r where r.job_id=p_job and r.rider_id=p_rider) then return false; end if;
  if not exists(select 1 from public.route_planner_candidates(v_request) c
    where c.rider_id=p_rider and c.partner_id=p_partner) then return false; end if;
  insert into public.paid_reassignment_offers(job_id,partner_id,rider_id,tier,score)
    values(p_job,p_partner,p_rider,p_tier,p_score);
  insert into public.ride_push_deliveries(device_id,event_type,source_id,expires_at)
    select d.id,'company_reassignment_offer',p_job,now()+interval '1 minute'
    from public.ride_push_devices d where d.kind='company' and d.last_seen_at>now()-interval '30 days'
      and public.company_staff_actor_allowed(p_partner,d.user_id,d.session_id,'bid')
    on conflict(device_id,event_type,source_id) do nothing;
  insert into public.notifications(user_id,job_id,event_type,channel,title,body,payload,status,sent_at)
    select u.user_id,p_job,'paid_reassignment_offer','in_app','Paid pickup available',
      'A paid pickup needs a replacement rider. Open your company dashboard to accept the fixed payout within one minute.',
      jsonb_build_object('rider_id',p_rider),'delivered',now()
    from (select pu.user_id from public.partner_users pu where pu.partner_id=p_partner and pu.membership_role='manager'
      union select s.user_id from public.company_operations_staff s where s.partner_id=p_partner
        and s.can_bid and s.revoked_at is null and s.password_revoked_at is null) u;
  return true;
exception when unique_violation then return false;
end $$;
revoke all on function public.offer_paid_reassignment(uuid,uuid,uuid,integer,double precision) from public,anon,authenticated;
grant execute on function public.offer_paid_reassignment(uuid,uuid,uuid,integer,double precision) to service_role;

create function public.my_paid_reassignment_offers() returns table(
  offer_id uuid,job_number text,partner_id uuid,rider_name text,pickup_address text,
  delivery_address text,company_share_ngn numeric,expires_at timestamptz)
language sql stable security definer set search_path=pg_catalog,public as $$
  select x.id,j.job_number,x.partner_id,rc.rider_name,j.pickup_address,j.delivery_address,
    f.partner_cost,x.expires_at
  from public.paid_reassignment_offers x join public.jobs j on j.id=x.job_id
  join public.job_financials f on f.job_id=j.id
  join public.rider_credentials rc on rc.user_id=x.rider_id
  where x.status='pending' and x.expires_at>now() and j.assigned_rider_id is null
    and public.company_staff_allowed(x.partner_id,'bid')
  order by x.expires_at limit 20;
$$;
revoke all on function public.my_paid_reassignment_offers() from public,anon;
grant execute on function public.my_paid_reassignment_offers() to authenticated;

create function public.respond_paid_reassignment_offer(p_offer uuid,p_accept boolean) returns boolean
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_offer public.paid_reassignment_offers%rowtype; v_job public.jobs%rowtype;
  v_request uuid; v_context jsonb; v_previous uuid;
begin
  select * into v_offer from public.paid_reassignment_offers where id=p_offer for update;
  if not found or not public.company_staff_allowed(v_offer.partner_id,'bid') then
    raise insufficient_privilege using message='Company bidding access required'; end if;
  if v_offer.status<>'pending' or v_offer.expires_at<=now() then return false; end if;
  select * into v_job from public.jobs where id=v_offer.job_id for update;
  if not found or v_job.assigned_rider_id is not null
    or v_job.status not in ('partner_assigned','pickup_scheduled') then return false; end if;
  if not p_accept then
    update public.paid_reassignment_offers set status='declined',responded_at=now() where id=p_offer;
    select o.service_request_id into v_request from public.orders o where o.id=v_job.order_id;
    insert into public.route_planner_events(request_id,event_kind,idempotency_key)
      values(v_request,'paid_reassignment','paid-declined:'||p_offer::text)
      on conflict(idempotency_key) do nothing;
    return true;
  end if;
  select o.service_request_id into v_request from public.orders o where o.id=v_job.order_id;
  v_context:=public.paid_reassignment_context(v_request);
  if v_context is null or not exists(select 1 from public.route_planner_candidates(v_request) c
    where c.rider_id=v_offer.rider_id and c.partner_id=v_offer.partner_id)
    or exists(select 1 from public.rider_assignment_responses r
      where r.job_id=v_job.id and r.rider_id=v_offer.rider_id) then return false; end if;
  if not exists(select 1 from public.partner_corridor_coverage c
    join public.delivery_quote_windows w on w.corridor_id=c.corridor_id
    where w.request_id=v_request and c.partner_id=v_offer.partner_id and c.is_enabled and c.capacity_available) then return false; end if;
  v_previous:=v_job.partner_id;
  update public.paid_reassignment_offers set status='accepted',responded_at=now() where id=p_offer;
  update public.partner_assignments set status='cancelled',response_note='Rider did not respond; paid job reoffered'
    where job_id=v_job.id and status='accepted';
  insert into public.partner_assignments(job_id,partner_id,status,responded_at,response_note)
    values(v_job.id,v_offer.partner_id,'accepted',now(),'Accepted paid replacement at fixed payout');
  update public.jobs set partner_id=v_offer.partner_id,assigned_rider_id=v_offer.rider_id,
    status='partner_assigned',route_assignment_issue=null where id=v_job.id;
  perform public.notify_customer_users(v_job.customer_id,v_job.id,
    'rider_assignment_changed','New company and rider assigned',
    'Another company accepted your paid pickup. Open tracking to see your new rider.',
    jsonb_build_object('replacement_rider_id',v_offer.rider_id,'partner_id',v_offer.partner_id));
  insert into public.notifications(user_id,job_id,event_type,channel,title,body,payload,status,sent_at)
    select pu.user_id,v_job.id,'rider_reassigned','in_app','Paid job moved to another company',
      'No rider responded in time. Another company accepted the same paid pickup; this job is no longer in your pending balance.',
      jsonb_build_object('new_partner_id',v_offer.partner_id),'delivered',now()
    from public.partner_users pu where pu.partner_id=v_previous and pu.membership_role='manager';
  return true;
end $$;
revoke all on function public.respond_paid_reassignment_offer(uuid,boolean) from public,anon;
grant execute on function public.respond_paid_reassignment_offer(uuid,boolean) to authenticated;

create function public.expire_paid_reassignment_offers() returns integer
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_row record; v_count integer:=0;
begin
  for v_row in update public.paid_reassignment_offers x set status='expired',responded_at=now()
    where x.status='pending' and x.expires_at<=now()
    returning x.id,x.job_id loop
    insert into public.route_planner_events(request_id,event_kind,idempotency_key)
      select o.service_request_id,'paid_reassignment','paid-expired:'||v_row.id::text
      from public.jobs j join public.orders o on o.id=j.order_id where j.id=v_row.job_id
        and j.assigned_rider_id is null and j.status in ('partner_assigned','pickup_scheduled')
      on conflict(idempotency_key) do nothing;
    v_count:=v_count+1;
  end loop;
  return v_count;
end $$;
revoke all on function public.expire_paid_reassignment_offers() from public,anon,authenticated;
grant execute on function public.expire_paid_reassignment_offers() to service_role;
select cron.schedule('kwik-parsel-paid-offer-expiry','15 seconds',
  $$select public.expire_paid_reassignment_offers()$$);

alter table public.ride_push_deliveries drop constraint ride_push_deliveries_event_type_check;
alter table public.ride_push_deliveries add constraint ride_push_deliveries_event_type_check
  check(event_type in ('company_invitation','rider_assignment','customer_match','rider_missed','company_reassignment_offer'));
do $$
declare v_definition text; v_revised text;
begin
  select pg_get_functiondef('public.claim_ride_push_deliveries(integer)'::regprocedure) into v_definition;
  v_revised:=replace(v_definition,
    'and (x.event_type<>''rider_assignment'' or exists',
    'and (x.event_type<>''company_reassignment_offer'' or exists('
      ||'select 1 from public.paid_reassignment_offers po where po.job_id=x.source_id'
      ||' and po.status=''pending'' and po.expires_at>now() and d.kind=''company'''
      ||' and public.company_staff_actor_allowed(po.partner_id,d.user_id,d.session_id,''bid'')))'
      ||E'\n      and (x.event_type<>''rider_assignment'' or exists');
  if v_revised=v_definition then raise exception 'Company push claim guard was not found'; end if;
  execute v_revised;
end $$;
