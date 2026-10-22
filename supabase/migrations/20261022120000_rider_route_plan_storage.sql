-- Server-owned routing state. This does not change company bidding, payment,
-- rider assignment, or custody transitions.
create table public.rider_route_plans (
  rider_id uuid primary key references auth.users(id) on delete cascade,
  partner_id uuid not null references public.logistics_partners(id),
  version bigint not null default 0 check (version >= 0),
  estimate_source text not null default 'unplanned' check (estimate_source in ('unplanned','road','cached_road','idle_approximate')),
  estimated_at timestamptz,
  updated_at timestamptz not null default now()
);

create table public.rider_route_stops (
  rider_id uuid not null references public.rider_route_plans(rider_id) on delete cascade,
  sequence integer not null check (sequence > 0),
  job_id uuid not null references public.jobs(id),
  stop_kind text not null check (stop_kind in ('pickup','dropoff')),
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  eta_at timestamptz,
  primary key (rider_id, sequence),
  unique (rider_id, job_id, stop_kind)
);
create index rider_route_stops_job_idx on public.rider_route_stops(job_id);
create index rider_route_stops_point_gix on public.rider_route_stops using gist
  ((extensions.st_setsrid(extensions.st_makepoint(longitude,latitude),4326)::extensions.geography));

create table public.dispatch_route_proposals (
  request_id uuid not null references public.service_requests(id) on delete cascade,
  partner_id uuid not null references public.logistics_partners(id),
  rider_id uuid not null references auth.users(id),
  load_state text not null check (load_state in ('available','almost_full')),
  algorithm_version text not null,
  score double precision not null,
  details jsonb not null default '{}'::jsonb,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  primary key (request_id, partner_id, rider_id)
);
create index dispatch_route_proposals_expiry_idx on public.dispatch_route_proposals(expires_at);

create table public.route_planner_events (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete cascade,
  rider_id uuid references auth.users(id) on delete cascade,
  event_kind text not null check (event_kind in ('shadow_invitation','route_commit','replan')),
  idempotency_key text not null unique,
  status text not null default 'pending' check (status in ('pending','running','completed','dead')),
  attempts integer not null default 0 check (attempts between 0 and 5),
  available_at timestamptz not null default now(),
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index route_planner_events_due_idx on public.route_planner_events(available_at,created_at)
  where status='pending';

create function public.enqueue_route_shadow_on_window() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.status='open' and (tg_op='INSERT' or old.status is distinct from new.status
    or old.deadline_at is distinct from new.deadline_at) then
    insert into public.route_planner_events(request_id,event_kind,idempotency_key)
      values(new.request_id,'shadow_invitation',
        'shadow:'||new.request_id::text||':'||extract(epoch from new.deadline_at)::bigint::text)
      on conflict(idempotency_key) do nothing;
  end if;
  return new;
end $$;
create trigger delivery_quote_window_enqueue_route_shadow
  after insert or update of status,deadline_at on public.delivery_quote_windows
  for each row execute function public.enqueue_route_shadow_on_window();
revoke all on function public.enqueue_route_shadow_on_window() from public,anon,authenticated;

-- Only assignment or custody/status changes enqueue route work. Routine GPS
-- writes do not generate queue traffic.
create function public.enqueue_route_replan_on_job_change() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_request uuid;v_rider uuid;
begin
  if new.assigned_rider_id is not distinct from old.assigned_rider_id
    and new.status is not distinct from old.status then return new; end if;
  select o.service_request_id into v_request from public.orders o where o.id=new.order_id;
  if v_request is null then return new; end if;
  for v_rider in select distinct x.rider_id from (values(old.assigned_rider_id),(new.assigned_rider_id)) x(rider_id)
    where x.rider_id is not null
  loop
    insert into public.route_planner_events(request_id,rider_id,event_kind,idempotency_key)
      values(v_request,v_rider,'replan',
        'replan:'||new.id::text||':'||txid_current()::text||':'||new.status::text||':'||v_rider::text)
      on conflict(idempotency_key) do nothing;
  end loop;
  return new;
end $$;
create trigger jobs_enqueue_route_replan
  after update of assigned_rider_id,status on public.jobs
  for each row execute function public.enqueue_route_replan_on_job_change();
revoke all on function public.enqueue_route_replan_on_job_change() from public,anon,authenticated;

-- One comparison point per active rider, not a location trail. A routine
-- 15-second presence write cannot itself create a replan event.
create table public.route_replan_markers (
  rider_id uuid primary key references auth.users(id) on delete cascade,
  position extensions.geography(Point,4326) not null,
  enqueued_at timestamptz not null default now()
);
alter table public.route_replan_markers enable row level security;
revoke all on public.route_replan_markers from public,anon,authenticated;

create function public.enqueue_route_replan_on_material_movement() returns trigger
language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
declare v_request uuid;v_marker public.route_replan_markers%rowtype;
begin
  select o.service_request_id into v_request from public.jobs j
  join public.orders o on o.id=j.order_id
  where j.assigned_rider_id=new.user_id
    and j.status in ('pickup_scheduled','picked_up','in_transit','out_for_delivery','exception')
  order by j.created_at,j.id limit 1;
  if v_request is null then return new; end if;
  insert into public.route_replan_markers(rider_id,position)
    values(new.user_id,new.position) on conflict(rider_id) do nothing;
  select * into v_marker from public.route_replan_markers where rider_id=new.user_id for update;
  if v_marker.enqueued_at>now()-interval '5 minutes'
    or extensions.st_distance(v_marker.position,new.position)<500 then return new; end if;
  update public.route_replan_markers set position=new.position,enqueued_at=now()
    where rider_id=new.user_id;
  insert into public.route_planner_events(request_id,rider_id,event_kind,idempotency_key)
    values(v_request,new.user_id,'replan',
      'movement:'||new.user_id::text||':'||floor(extract(epoch from now())/300)::bigint::text)
    on conflict(idempotency_key) do nothing;
  return new;
end $$;
create trigger rider_presence_enqueue_material_replan
  after insert or update of position,captured_at on public.rider_presence
  for each row execute function public.enqueue_route_replan_on_material_movement();
revoke all on function public.enqueue_route_replan_on_material_movement() from public,anon,authenticated;

-- A hard application budget below Geoapify's published free daily allowance.
-- Reserve before each matrix request; unused credits are intentionally not
-- refunded on provider failures, so outages cannot create an overrun.
create table public.route_matrix_daily_budget (
  budget_day date primary key,
  credits_reserved integer not null default 0 check (credits_reserved between 0 and 1500),
  updated_at timestamptz not null default now()
);

alter table public.rider_route_plans enable row level security;
alter table public.rider_route_stops enable row level security;
alter table public.dispatch_route_proposals enable row level security;
alter table public.route_planner_events enable row level security;
alter table public.route_matrix_daily_budget enable row level security;
revoke all on public.rider_route_plans,public.rider_route_stops,public.dispatch_route_proposals,public.route_planner_events,public.route_matrix_daily_budget from anon,authenticated;
grant select,insert,update,delete on public.dispatch_route_proposals to service_role;
grant select,insert,update on public.route_planner_events to service_role;

create function public.claim_route_planner_events(p_limit integer default 5)
returns table(event_id uuid,request_id uuid,rider_id uuid,event_kind text,attempts integer)
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if auth.role()<>'service_role' then raise insufficient_privilege using message='Routing worker access required'; end if;
  if p_limit is null or p_limit<1 or p_limit>20 then raise check_violation using message='Invalid queue batch size'; end if;
  return query
    with claimed as (
      select e.id from public.route_planner_events e
      where (e.status='pending' and e.available_at<=now())
        or (e.status='running' and e.updated_at<now()-interval '2 minutes' and e.attempts<5)
      order by e.available_at,e.created_at for update skip locked limit p_limit
    )
    update public.route_planner_events e set status='running',attempts=e.attempts+1,updated_at=now()
    from claimed c where e.id=c.id
    returning e.id,e.request_id,e.rider_id,e.event_kind,e.attempts;
end $$;
revoke all on function public.claim_route_planner_events(integer) from public,anon,authenticated;
grant execute on function public.claim_route_planner_events(integer) to service_role;

create function public.finish_route_planner_event(p_event_id uuid,p_success boolean,p_error text default null)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_event public.route_planner_events%rowtype;
begin
  if auth.role()<>'service_role' then raise insufficient_privilege using message='Routing worker access required'; end if;
  select * into v_event from public.route_planner_events where id=p_event_id for update;
  if not found or v_event.status<>'running' then return; end if;
  update public.route_planner_events set
    status=case when p_success then 'completed' when attempts>=5 then 'dead' else 'pending' end,
    available_at=case when p_success then available_at else now()+make_interval(secs=>least(60,2^attempts)::integer) end,
    last_error=case when p_success then null else left(coalesce(p_error,'Routing worker error'),500) end,
    updated_at=now() where id=p_event_id;
end $$;
revoke all on function public.finish_route_planner_event(uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.finish_route_planner_event(uuid,boolean,text) to service_role;

create function public.upsert_dispatch_route_proposal(p_request uuid,p_partner uuid,p_rider uuid,
  p_load_state text,p_algorithm_version text,p_score double precision,p_details jsonb,p_expires_at timestamptz)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if auth.role()<>'service_role' then raise insufficient_privilege using message='Routing worker access required'; end if;
  if coalesce(p_load_state,'') not in ('available','almost_full')
    or p_score is null or p_score not between -1000000000 and 1000000000
    or length(coalesce(p_algorithm_version,'')) not between 1 and 80
    or p_expires_at is null or p_expires_at<=now() or p_expires_at>now()+interval '5 minutes'
    or not exists(select 1 from public.delivery_quote_windows w
      join public.company_bid_invitations i on i.request_id=w.request_id and i.partner_id=p_partner
      where w.request_id=p_request and w.status='open' and w.deadline_at>now()) then
    raise check_violation using message='Invalid or expired route proposal';
  end if;
  insert into public.dispatch_route_proposals(request_id,partner_id,rider_id,load_state,
    algorithm_version,score,details,expires_at)
  values(p_request,p_partner,p_rider,p_load_state,p_algorithm_version,p_score,
    coalesce(p_details,'{}'::jsonb),p_expires_at)
  on conflict(request_id,partner_id,rider_id) do update set load_state=excluded.load_state,
    algorithm_version=excluded.algorithm_version,score=excluded.score,details=excluded.details,
    expires_at=excluded.expires_at;
end $$;
revoke all on function public.upsert_dispatch_route_proposal(uuid,uuid,uuid,text,text,double precision,jsonb,timestamptz) from public,anon,authenticated;
grant execute on function public.upsert_dispatch_route_proposal(uuid,uuid,uuid,text,text,double precision,jsonb,timestamptz) to service_role;

create function public.reserve_route_matrix_credits(p_credits integer) returns boolean
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_day date:=(now() at time zone 'UTC')::date;
begin
  if auth.role()<>'service_role' then raise insufficient_privilege using message='Routing worker access required'; end if;
  if p_credits is null or p_credits<1 or p_credits>100 then
    raise check_violation using message='Invalid matrix credit reservation';
  end if;
  insert into public.route_matrix_daily_budget(budget_day,credits_reserved)
    values(v_day,p_credits) on conflict(budget_day) do update
    set credits_reserved=public.route_matrix_daily_budget.credits_reserved+excluded.credits_reserved,
        updated_at=now()
    where public.route_matrix_daily_budget.credits_reserved+excluded.credits_reserved<=1500;
  return found;
end $$;
revoke all on function public.reserve_route_matrix_credits(integer) from public,anon,authenticated;
grant execute on function public.reserve_route_matrix_credits(integer) to service_role;

-- Bound prefiltering by current GPS. Route-stop expansion can be enabled only
-- after road times, not proximity alone, prove an aligned pickup.
create function public.route_planner_candidates(p_request uuid)
returns table(partner_id uuid,rider_id uuid,latitude double precision,longitude double precision,
  accuracy_metres double precision,gps_captured_at timestamptz,load_state text,
  distance_metres double precision,active_pickups bigint,plan_version bigint,
  existing_stops jsonb,active_jobs jsonb,has_unroutable_jobs boolean)
language plpgsql stable security definer set search_path=pg_catalog,public,extensions as $$
begin
  if auth.role()<>'service_role' then raise insufficient_privilege using message='Routing worker access required'; end if;
  return query
    with nearby as (
      select rp.partner_id,rp.user_id as rider_id,
        extensions.st_y(rp.position::extensions.geometry) as latitude,
        extensions.st_x(rp.position::extensions.geometry) as longitude,
        rp.accuracy_metres,rp.captured_at as gps_captured_at,rc.load_state,
        extensions.st_distance(rp.position,
          extensions.st_setsrid(extensions.st_makepoint(r.pickup_longitude,r.pickup_latitude),4326)::extensions.geography) as distance_metres,
        (select count(*) from public.jobs j where j.assigned_rider_id=rp.user_id
          and j.status in ('pickup_scheduled','picked_up','exception')) as active_pickups
      from public.service_requests r
      join public.rider_presence rp on (
        extensions.st_dwithin(rp.position,
          extensions.st_setsrid(extensions.st_makepoint(r.pickup_longitude,r.pickup_latitude),4326)::extensions.geography,5000)
        or exists(select 1 from public.rider_route_stops s where s.rider_id=rp.user_id
          and s.sequence=(select min(s2.sequence) from public.rider_route_stops s2 where s2.rider_id=rp.user_id)
          and extensions.st_dwithin(
            extensions.st_setsrid(extensions.st_makepoint(s.longitude,s.latitude),4326)::extensions.geography,
            extensions.st_setsrid(extensions.st_makepoint(r.pickup_longitude,r.pickup_latitude),4326)::extensions.geography,2000)))
      join public.logistics_partners lp on lp.id=rp.partner_id and lp.status='active'
      join public.rider_credentials rc on rc.user_id=rp.user_id and rc.partner_id=rp.partner_id
        and rc.revoked_at is null and rc.password_revoked_at is null and rc.load_state<>'full'
      join public.company_riders cr on cr.id=rc.roster_id and cr.status='approved'
      join public.partner_users pu on pu.user_id=rp.user_id and pu.partner_id=rp.partner_id and pu.membership_role='rider'
      where r.id=p_request and r.pickup_latitude is not null
        and rp.received_at>now()-interval '2 minutes' and rp.captured_at>now()-interval '2 minutes'
        and rp.accuracy_metres<=100
        and (select count(*) from public.jobs j where j.assigned_rider_id=rp.user_id
          and j.status in ('pickup_scheduled','picked_up','exception'))<5
      order by 8,rp.user_id limit 100
    )
    select n.partner_id,n.rider_id,n.latitude,n.longitude,n.accuracy_metres,
      n.gps_captured_at,n.load_state,n.distance_metres,n.active_pickups,coalesce(p.version,0),
      coalesce((select jsonb_agg(jsonb_build_object('job_id',s.job_id,'kind',s.stop_kind,
        'latitude',s.latitude,'longitude',s.longitude,'eta_at',s.eta_at) order by s.sequence)
        from public.rider_route_stops s where s.rider_id=n.rider_id),'[]'::jsonb),
      coalesce((select jsonb_agg(jsonb_build_object('job_id',j.id,'status',j.status,
        'pickup_latitude',r.pickup_latitude,'pickup_longitude',r.pickup_longitude,
        'dropoff_latitude',j.delivery_latitude,'dropoff_longitude',j.delivery_longitude,
        'preferred_pickup_at',j.preferred_pickup_at) order by j.created_at,j.id)
        from public.jobs j join public.orders o on o.id=j.order_id
        join public.service_requests r on r.id=o.service_request_id
        where j.assigned_rider_id=n.rider_id and j.status in
          ('pickup_scheduled','picked_up','in_transit','out_for_delivery','exception')),'[]'::jsonb),
      exists(select 1 from public.jobs j join public.orders o on o.id=j.order_id
        join public.service_requests r on r.id=o.service_request_id
        where j.assigned_rider_id=n.rider_id and j.status in
          ('pickup_scheduled','picked_up','in_transit','out_for_delivery','exception')
          and (j.delivery_latitude is null or j.delivery_longitude is null
            or (j.status in ('pickup_scheduled','exception')
              and (r.pickup_latitude is null or r.pickup_longitude is null))))
    from nearby n left join public.rider_route_plans p on p.rider_id=n.rider_id;
end $$;
revoke all on function public.route_planner_candidates(uuid) from public,anon,authenticated;
grant execute on function public.route_planner_candidates(uuid) to service_role;

create function public.rider_route_context(p_rider uuid) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public,extensions as $$
declare v_context jsonb;
begin
  if auth.role()<>'service_role' then raise insufficient_privilege using message='Routing worker access required'; end if;
  select jsonb_build_object(
    'rider_id',rc.user_id,'partner_id',rc.partner_id,'load_state',rc.load_state,
    'latitude',extensions.st_y(rp.position::extensions.geometry),
    'longitude',extensions.st_x(rp.position::extensions.geometry),
    'accuracy_metres',rp.accuracy_metres,'gps_captured_at',rp.captured_at,
    'gps_received_at',rp.received_at,'plan_version',coalesce(p.version,0),
    'existing_stops',coalesce((select jsonb_agg(jsonb_build_object('job_id',s.job_id,
      'kind',s.stop_kind,'latitude',s.latitude,'longitude',s.longitude,'eta_at',s.eta_at)
      order by s.sequence) from public.rider_route_stops s where s.rider_id=p_rider),'[]'::jsonb),
    'active_jobs',coalesce((select jsonb_agg(jsonb_build_object('job_id',j.id,'status',j.status,
      'pickup_latitude',r.pickup_latitude,'pickup_longitude',r.pickup_longitude,
      'dropoff_latitude',j.delivery_latitude,'dropoff_longitude',j.delivery_longitude,
      'preferred_pickup_at',j.preferred_pickup_at) order by j.created_at,j.id)
      from public.jobs j join public.orders o on o.id=j.order_id
      join public.service_requests r on r.id=o.service_request_id
      where j.assigned_rider_id=p_rider and j.status in
        ('pickup_scheduled','picked_up','in_transit','out_for_delivery','exception')),'[]'::jsonb))
  into v_context from public.rider_credentials rc
  left join public.rider_presence rp on rp.user_id=rc.user_id and rp.partner_id=rc.partner_id
  left join public.rider_route_plans p on p.rider_id=rc.user_id
  where rc.user_id=p_rider and rc.revoked_at is null and rc.password_revoked_at is null;
  return v_context;
end $$;
revoke all on function public.rider_route_context(uuid) from public,anon,authenticated;
grant execute on function public.rider_route_context(uuid) to service_role;

-- A route is authoritative only after the existing payment and assignment flow
-- has completed. A stale planner result must fail rather than overwrite stops.
create function public.commit_rider_route_plan(
  p_rider uuid,p_expected_version bigint,p_stops jsonb,p_estimate_source text
) returns bigint
language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_partner uuid; v_version bigint; v_stop record; v_job record;
  v_count integer:=0; v_pickup_seen uuid[]:='{}'::uuid[];
begin
  if auth.role()<>'service_role' then
    raise insufficient_privilege using message='Routing worker access required';
  end if;
  if p_expected_version is null or p_expected_version<0 or coalesce(jsonb_typeof(p_stops),'null')<>'array'
    or (jsonb_typeof(p_stops)='array' and jsonb_array_length(p_stops)>10)
    or coalesce(p_estimate_source,'') not in ('road','cached_road','idle_approximate') then
    raise check_violation using message='Invalid route proposal';
  end if;
  select partner_id into v_partner from public.rider_credentials
    where user_id=p_rider and revoked_at is null and password_revoked_at is null;
  if v_partner is null then raise check_violation using message='Rider access is inactive'; end if;
  -- Serialize plans for the same rider, including a plan that does not exist yet.
  perform 1 from auth.users where id=p_rider for update;
  insert into public.rider_route_plans(rider_id,partner_id) values(p_rider,v_partner)
    on conflict (rider_id) do nothing;
  select version into v_version from public.rider_route_plans where rider_id=p_rider for update;
  if v_version is distinct from p_expected_version then
    raise serialization_failure using message='Route version changed; replan from the latest version';
  end if;
  create temporary table if not exists pg_temp.route_proposed_stops(
    sequence integer,job_id uuid,stop_kind text,latitude double precision,
    longitude double precision,eta_at timestamptz
  ) on commit drop;
  truncate pg_temp.route_proposed_stops;
  for v_stop in select * from jsonb_to_recordset(p_stops) as x(
    job_id uuid,kind text,latitude double precision,longitude double precision,eta_at timestamptz
  ) loop
    v_count:=v_count+1;
    if v_stop.job_id is null or coalesce(v_stop.kind,'') not in ('pickup','dropoff')
      or v_stop.latitude is null or v_stop.latitude not between -90 and 90
      or v_stop.longitude is null or v_stop.longitude not between -180 and 180 then
      raise check_violation using message='Invalid route stop';
    end if;
    select j.id,j.partner_id,j.assigned_rider_id,j.status,o.service_request_id,
      r.pickup_latitude,r.pickup_longitude,j.delivery_latitude,j.delivery_longitude
      into v_job from public.jobs j join public.orders o on o.id=j.order_id
      join public.service_requests r on r.id=o.service_request_id
      where j.id=v_stop.job_id;
    if not found or v_job.partner_id<>v_partner or v_job.assigned_rider_id<>p_rider
      or v_job.status in ('delivered','closed','cancelled')
      or not exists(select 1 from public.partner_assignments pa
        where pa.job_id=v_job.id and pa.partner_id=v_partner
          and pa.status in ('accepted','completed')) then
      raise check_violation using message='Stop must belong to an accepted active rider assignment';
    end if;
    if v_stop.kind='pickup' then
      if v_job.status not in ('pickup_scheduled','exception') or v_job.pickup_latitude is null
        or abs(v_stop.latitude-v_job.pickup_latitude)>0.000001
        or abs(v_stop.longitude-v_job.pickup_longitude)>0.000001 then
        raise check_violation using message='Pickup stop does not match the active job';
      end if;
      v_pickup_seen:=array_append(v_pickup_seen,v_stop.job_id);
    elsif v_job.delivery_latitude is null
      or abs(v_stop.latitude-v_job.delivery_latitude)>0.000001
      or abs(v_stop.longitude-v_job.delivery_longitude)>0.000001
      or (v_job.status in ('pickup_scheduled','exception') and not v_stop.job_id=any(v_pickup_seen)) then
      raise check_violation using message='Drop-off must follow pickup and match the active job';
    end if;
    insert into pg_temp.route_proposed_stops values(v_count,v_stop.job_id,v_stop.kind,
      v_stop.latitude,v_stop.longitude,v_stop.eta_at);
  end loop;
  if exists(select 1 from pg_temp.route_proposed_stops group by job_id,stop_kind having count(*)>1) then
    raise check_violation using message='Duplicate route stop';
  end if;
  -- The planner may not silently omit an assigned pickup or goods already in
  -- custody. Exceptions remain visible until a custody-safe resolution.
  if exists(select 1 from public.jobs j
    where j.assigned_rider_id=p_rider and j.status in ('pickup_scheduled','exception')
    and (not exists(select 1 from pg_temp.route_proposed_stops s
      where s.job_id=j.id and s.stop_kind='pickup')
      or not exists(select 1 from pg_temp.route_proposed_stops s
      where s.job_id=j.id and s.stop_kind='dropoff'))) then
    raise check_violation using message='Route omits an assigned pickup or drop-off';
  end if;
  if exists(select 1 from public.jobs j where j.assigned_rider_id=p_rider
    and j.status in ('picked_up','in_transit','out_for_delivery')
    and not exists(select 1 from pg_temp.route_proposed_stops s
      where s.job_id=j.id and s.stop_kind='dropoff')) then
    raise check_violation using message='Route omits a parcel already in custody';
  end if;
  delete from public.rider_route_stops where rider_id=p_rider;
  insert into public.rider_route_stops(rider_id,sequence,job_id,stop_kind,latitude,longitude,eta_at)
    select p_rider,sequence,job_id,stop_kind,latitude,longitude,eta_at
    from pg_temp.route_proposed_stops order by sequence;
  update public.rider_route_plans set version=version+1,estimate_source=p_estimate_source,
    estimated_at=clock_timestamp(),updated_at=clock_timestamp() where rider_id=p_rider
    returning version into v_version;
  return v_version;
end $$;
revoke all on function public.commit_rider_route_plan(uuid,bigint,jsonb,text) from public,anon,authenticated;
grant execute on function public.commit_rider_route_plan(uuid,bigint,jsonb,text) to service_role;

create function public.my_rider_next_stop()
returns table(plan_version bigint,job_id uuid,stop_kind text,latitude double precision,
  longitude double precision,eta_at timestamptz,estimate_source text)
language sql stable security definer set search_path=pg_catalog,public as $$
  select p.version,s.job_id,s.stop_kind,s.latitude,s.longitude,s.eta_at,p.estimate_source
  from public.rider_route_plans p join public.rider_route_stops s on s.rider_id=p.rider_id
  where p.rider_id=auth.uid() and public.rider_session_active()
  order by s.sequence limit 1;
$$;
revoke all on function public.my_rider_next_stop() from public,anon;
grant execute on function public.my_rider_next_stop() to authenticated;

-- The invited rider is a proposal, not a reservation. At the paid award's
-- company acceptance, use that rider if still eligible, then another eligible
-- rider of the same company. Never silently switch companies.
alter table public.jobs add column route_assignment_issue text;

create or replace function public.assign_selected_pickup_rider_on_acceptance()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
declare v_request uuid;v_lat double precision;v_lon double precision;v_invited uuid;
  v_candidate record;v_assigned boolean:=false;
begin
  if new.status<>'accepted' or (tg_op='UPDATE' and old.status='accepted') then return new; end if;
  select o.service_request_id,r.pickup_latitude,r.pickup_longitude,i.rider_id
    into v_request,v_lat,v_lon,v_invited
    from public.jobs j join public.orders o on o.id=j.order_id
    join public.service_requests r on r.id=o.service_request_id
    join public.customer_delivery_quotes cq on cq.request_id=r.id and cq.status='accepted'
    join public.partner_quotes q on q.id=cq.winning_bid_id and q.partner_id=new.partner_id
    left join public.company_bid_invitations i on i.request_id=r.id and i.partner_id=new.partner_id
    where j.id=new.job_id and j.partner_id=new.partner_id and j.assigned_rider_id is null
      and j.status in ('partner_assigned','pickup_scheduled');
  if v_request is null then return new; end if;
  for v_candidate in
    select rp.user_id from public.rider_presence rp
    join public.rider_credentials rc on rc.user_id=rp.user_id and rc.partner_id=new.partner_id
      and rc.revoked_at is null and rc.password_revoked_at is null and rc.load_state<>'full'
    join public.company_riders cr on cr.id=rc.roster_id and cr.status='approved'
    join public.partner_users pu on pu.user_id=rp.user_id and pu.partner_id=new.partner_id and pu.membership_role='rider'
    where rp.partner_id=new.partner_id and v_lat is not null and v_lon is not null
      and rp.received_at>now()-interval '2 minutes' and rp.captured_at>now()-interval '2 minutes'
      and rp.accuracy_metres<=100
      and extensions.st_dwithin(rp.position,
        extensions.st_setsrid(extensions.st_makepoint(v_lon,v_lat),4326)::extensions.geography,5000)
      and (select count(*) from public.jobs j where j.assigned_rider_id=rp.user_id
        and j.status in ('pickup_scheduled','picked_up','exception'))<5
    order by (rp.user_id is distinct from v_invited),
      (rc.load_state='almost_full'),
      extensions.st_distance(rp.position,
        extensions.st_setsrid(extensions.st_makepoint(v_lon,v_lat),4326)::extensions.geography),rp.user_id
    limit 10
  loop
    begin
      update public.jobs set assigned_rider_id=v_candidate.user_id,route_assignment_issue=null
        where id=new.job_id and assigned_rider_id is null;
      if found then v_assigned:=true;exit; end if;
    exception when check_violation then
      -- The assignment guard serializes concurrent awards on this rider.
      null;
    end;
  end loop;
  if not v_assigned then
    update public.jobs set route_assignment_issue='No eligible rider in the selected company; resolve this paid booking before pickup'
      where id=new.job_id and assigned_rider_id is null;
  end if;
  return new;
end $$;
