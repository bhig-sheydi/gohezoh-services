-- Road-aware invitations are prepared before the one-minute bid window opens.
alter table public.delivery_quote_windows drop constraint delivery_quote_windows_status_check;
alter table public.delivery_quote_windows add constraint delivery_quote_windows_status_check
  check (status in ('matching','open','awaiting_customer_selection','quoted','tie_review','no_bids','cancelled'));
alter table public.service_requests drop constraint service_requests_dispatch_match_status_check;
alter table public.service_requests add constraint service_requests_dispatch_match_status_check
  check (dispatch_match_status in ('waiting','matching','bidding','no_nearby','no_bids','quote_ready'));
alter table public.route_planner_events drop constraint route_planner_events_event_kind_check;
alter table public.route_planner_events add constraint route_planner_events_event_kind_check
  check (event_kind in ('shadow_invitation','live_invitation','route_commit','replan'));

create or replace function public.enqueue_route_shadow_on_window() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.status='matching' and (tg_op='INSERT' or old.status is distinct from new.status
    or old.published_at is distinct from new.published_at) then
    insert into public.route_planner_events(request_id,event_kind,idempotency_key)
      values(new.request_id,'live_invitation',
        'live:'||new.request_id::text||':'||extract(epoch from new.published_at)::bigint::text)
      on conflict(idempotency_key) do nothing;
  end if;
  return new;
end $$;

create or replace function public.invite_nearby_dispatch_companies() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_local boolean; v_has_pickup boolean;
begin
  if new.status<>'open' then return new; end if;
  if tg_op='UPDATE' and old.status='open' and old.published_at=new.published_at then return new; end if;
  if exists(select 1 from public.company_bid_invitations where request_id=new.request_id) then return new; end if;
  select s.code='SRV-0001',r.pickup_location_source is not null into v_local,v_has_pickup
    from public.service_requests r join public.services s on s.id=r.service_id where r.id=new.request_id;
  if not v_local or not v_has_pickup then return new; end if;
  insert into public.company_bid_invitations(request_id,partner_id,rider_id,distance_metres)
  select new.request_id,n.partner_id,n.rider_id,n.distance_metres
    from public.nearby_dispatch_companies(new.request_id,new.corridor_id) n
    order by n.distance_metres,n.partner_id limit 50;
  if not found then raise check_violation using message='No available company rider for this pickup'; end if;
  return new;
end $$;

create or replace function public.try_dispatch_match(p_request uuid) returns boolean
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_corridor uuid; v_request public.service_requests%rowtype;
begin
  select * into v_request from public.service_requests where id=p_request for update;
  if not found or v_request.status not in ('submitted','under_review')
    or exists(select 1 from public.delivery_quote_windows where request_id=p_request and status<>'no_bids') then return true; end if;
  select c.id into v_corridor from public.coverage_corridors c
    join public.coverage_locations o on o.id=c.origin_id and o.is_enabled
    join public.coverage_locations d on d.id=c.destination_id and d.is_enabled
    where c.is_enabled and c.service_code='SRV-0001' and lower(btrim(o.name))=lower(btrim(v_request.pickup_city))
      and lower(btrim(d.name))=lower(btrim(v_request.delivery_city)) limit 1;
  if v_corridor is null then return false; end if;
  -- Candidate discovery is inexpensive; the worker checks actual road travel.
  if not exists(select 1 from public.nearby_dispatch_companies(p_request,v_corridor))
    and not exists(select 1 from public.rider_route_stops s
      join public.rider_presence rp on rp.user_id=s.rider_id
      join public.rider_credentials rc on rc.user_id=rp.user_id and rc.partner_id=rp.partner_id
      join public.logistics_partners lp on lp.id=rp.partner_id and lp.status='active'
      where s.sequence=1 and rc.revoked_at is null and rc.password_revoked_at is null and rc.load_state<>'full'
        and rp.received_at>now()-interval '2 minutes' and rp.captured_at>now()-interval '2 minutes'
        and rp.accuracy_metres<=100
        and extensions.st_dwithin(extensions.st_setsrid(extensions.st_makepoint(s.longitude,s.latitude),4326)::extensions.geography,
          extensions.st_setsrid(extensions.st_makepoint(v_request.pickup_longitude,v_request.pickup_latitude),4326)::extensions.geography,2000)) then return false; end if;
  delete from public.company_bid_invitations where request_id=p_request;
  delete from public.dispatch_route_proposals where request_id=p_request;
  insert into public.delivery_quote_windows(request_id,corridor_id,status,published_at,deadline_at)
    values(p_request,v_corridor,'matching',now(),now()+interval '2 minutes')
    on conflict(request_id) do update set status='matching',published_at=now(),deadline_at=now()+interval '2 minutes',closed_at=null;
  update public.service_requests set status='under_review',dispatch_match_status='matching' where id=p_request;
  return true;
end $$;

create or replace function public.sync_dispatch_window_status() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  update public.service_requests set dispatch_match_status=case new.status
    when 'matching' then 'matching' when 'open' then 'bidding' when 'no_bids' then 'no_bids' else 'quote_ready' end
    where id=new.request_id and pickup_location_source is not null;
  return new;
end $$;

create or replace function public.upsert_dispatch_route_proposal(p_request uuid,p_partner uuid,p_rider uuid,
  p_load_state text,p_algorithm_version text,p_score double precision,p_details jsonb,p_expires_at timestamptz)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if auth.role()<>'service_role' then raise insufficient_privilege using message='Routing worker access required'; end if;
  if coalesce(p_load_state,'') not in ('available','almost_full')
    or p_score is null or p_score not between -1000000000 and 1000000000
    or p_algorithm_version<>'road-v2-live' or p_details->>'estimate_source'<>'road'
    or (p_details->>'tier')::integer not between 1 and 4
    or p_expires_at is null or p_expires_at<=now() or p_expires_at>now()+interval '5 minutes'
    or not exists(select 1 from public.delivery_quote_windows w where w.request_id=p_request
      and w.status='matching' and w.deadline_at>now())
    or not exists(select 1 from public.rider_credentials rc join public.logistics_partners lp on lp.id=rc.partner_id
      where rc.user_id=p_rider and rc.partner_id=p_partner and rc.revoked_at is null
        and rc.password_revoked_at is null and rc.load_state<>'full' and lp.status='active') then
    raise check_violation using message='Invalid or expired route proposal';
  end if;
  insert into public.dispatch_route_proposals(request_id,partner_id,rider_id,load_state,
    algorithm_version,score,details,expires_at)
  values(p_request,p_partner,p_rider,p_load_state,p_algorithm_version,p_score,p_details,p_expires_at)
  on conflict(request_id,partner_id,rider_id) do update set load_state=excluded.load_state,
    algorithm_version=excluded.algorithm_version,score=excluded.score,details=excluded.details,
    expires_at=excluded.expires_at;
end $$;

create function public.finalize_live_route_match(p_request uuid) returns text
language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
declare v_window public.delivery_quote_windows%rowtype; v_tier integer; v_count integer;
begin
  if auth.role()<>'service_role' then raise insufficient_privilege using message='Routing worker access required'; end if;
  select * into v_window from public.delivery_quote_windows where request_id=p_request for update;
  if not found or v_window.status<>'matching' then return 'already_finished'; end if;
  select min((p.details->>'tier')::integer) into v_tier
    from public.dispatch_route_proposals p
    join public.rider_presence rp on rp.user_id=p.rider_id and rp.partner_id=p.partner_id
    join public.rider_credentials rc on rc.user_id=p.rider_id and rc.partner_id=p.partner_id
    join public.company_riders cr on cr.id=rc.roster_id and cr.status='approved'
    join public.partner_users pu on pu.user_id=p.rider_id and pu.partner_id=p.partner_id and pu.membership_role='rider'
    join public.logistics_partners lp on lp.id=p.partner_id and lp.status='active'
    join public.partner_corridor_coverage pc on pc.partner_id=p.partner_id and pc.corridor_id=v_window.corridor_id
      and pc.is_enabled and pc.capacity_available
    where p.request_id=p_request and p.algorithm_version='road-v2-live' and p.expires_at>now()
      and rp.received_at>now()-interval '2 minutes' and rp.captured_at>now()-interval '2 minutes'
      and rp.accuracy_metres<=100 and rc.revoked_at is null and rc.password_revoked_at is null and rc.load_state<>'full'
      and ((p.details->>'tier')::integer in (1,2,3)
        or exists(select 1 from public.service_requests r where r.id=p_request and extensions.st_dwithin(rp.position,
          extensions.st_setsrid(extensions.st_makepoint(r.pickup_longitude,r.pickup_latitude),4326)::extensions.geography,5000)));
  if v_tier is not null then
    insert into public.company_bid_invitations(request_id,partner_id,rider_id,distance_metres)
    select distinct on (p.partner_id) p_request,p.partner_id,p.rider_id,
      extensions.st_distance(rp.position,extensions.st_setsrid(extensions.st_makepoint(r.pickup_longitude,r.pickup_latitude),4326)::extensions.geography)
    from public.dispatch_route_proposals p
    join public.service_requests r on r.id=p.request_id
    join public.rider_presence rp on rp.user_id=p.rider_id and rp.partner_id=p.partner_id
    join public.rider_credentials rc on rc.user_id=p.rider_id and rc.partner_id=p.partner_id
    join public.company_riders cr on cr.id=rc.roster_id and cr.status='approved'
    join public.partner_users pu on pu.user_id=p.rider_id and pu.partner_id=p.partner_id and pu.membership_role='rider'
    join public.logistics_partners lp on lp.id=p.partner_id and lp.status='active'
    join public.partner_corridor_coverage pc on pc.partner_id=p.partner_id and pc.corridor_id=v_window.corridor_id
      and pc.is_enabled and pc.capacity_available
    where p.request_id=p_request and (p.details->>'tier')::integer=v_tier and p.expires_at>now()
      and rp.received_at>now()-interval '2 minutes' and rp.captured_at>now()-interval '2 minutes'
      and rp.accuracy_metres<=100 and rc.revoked_at is null and rc.password_revoked_at is null and rc.load_state<>'full'
      and (v_tier<4 or extensions.st_dwithin(rp.position,
        extensions.st_setsrid(extensions.st_makepoint(r.pickup_longitude,r.pickup_latitude),4326)::extensions.geography,5000))
    order by p.partner_id,p.score,p.rider_id limit 50;
    get diagnostics v_count=row_count;
  end if;
  if coalesce(v_count,0)=0 then
    -- Road API unavailable: retain the previous safe proximity behavior.
    insert into public.company_bid_invitations(request_id,partner_id,rider_id,distance_metres)
      select p_request,n.partner_id,n.rider_id,n.distance_metres
      from public.nearby_dispatch_companies(p_request,v_window.corridor_id) n
      order by n.distance_metres,n.partner_id limit 50;
    get diagnostics v_count=row_count;
  end if;
  if v_count=0 then
    update public.delivery_quote_windows set status='no_bids',closed_at=now() where request_id=p_request;
    return 'no_rider';
  end if;
  update public.delivery_quote_windows set status='open',published_at=now(),deadline_at=now()+interval '1 minute'
    where request_id=p_request;
  return case when v_tier is null then 'proximity_fallback' else 'tier_'||v_tier::text end;
end $$;
revoke all on function public.finalize_live_route_match(uuid) from public,anon,authenticated;
grant execute on function public.finalize_live_route_match(uuid) to service_role;

-- The invited rider must still be on duty. A distant invitation additionally
-- needs a live road proposal and a committed next stop near the pickup.
create or replace function public.company_can_bid_nearby(p_request uuid,p_partner uuid) returns boolean
language sql stable security definer set search_path=pg_catalog,public,extensions as $$
  select exists(select 1 from public.service_requests r join public.services s on s.id=r.service_id
    where r.id=p_request and (s.code<>'SRV-0001' or r.pickup_location_source is null or exists (
      select 1 from public.company_bid_invitations i
      join public.rider_presence rp on rp.user_id=i.rider_id and rp.partner_id=i.partner_id
      join public.rider_credentials rc on rc.user_id=i.rider_id and rc.partner_id=i.partner_id
        and rc.revoked_at is null and rc.password_revoked_at is null and rc.load_state<>'full'
      join public.company_riders cr on cr.id=rc.roster_id and cr.status='approved'
      join public.partner_users pu on pu.user_id=i.rider_id and pu.partner_id=i.partner_id and pu.membership_role='rider'
      where i.request_id=r.id and i.partner_id=p_partner
        and rp.received_at>now()-interval '2 minutes' and rp.captured_at>now()-interval '2 minutes'
        and rp.accuracy_metres<=100
        and (extensions.st_dwithin(rp.position,
          extensions.st_setsrid(extensions.st_makepoint(r.pickup_longitude,r.pickup_latitude),4326)::extensions.geography,5000)
          or exists(select 1 from public.dispatch_route_proposals p
            join public.rider_route_stops rs on rs.rider_id=p.rider_id and rs.sequence=1
            where p.request_id=i.request_id and p.partner_id=i.partner_id and p.rider_id=i.rider_id
              and p.algorithm_version='road-v2-live' and (p.details->>'tier')::integer in (1,2)
              and extensions.st_dwithin(
                extensions.st_setsrid(extensions.st_makepoint(rs.longitude,rs.latitude),4326)::extensions.geography,
                extensions.st_setsrid(extensions.st_makepoint(r.pickup_longitude,r.pickup_latitude),4326)::extensions.geography,2000)))
        )));
$$;

-- If the route worker fails, do not leave a customer waiting indefinitely.
create or replace function public.process_dispatch_matches() returns integer
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_row record; v_count integer:=0;
begin
  for v_row in select * from public.dispatch_match_queue where attempts<30 and next_attempt_at<=now()
    order by next_attempt_at limit 100 for update skip locked loop
    if public.try_dispatch_match(v_row.request_id) then delete from public.dispatch_match_queue where request_id=v_row.request_id;
    else
      update public.dispatch_match_queue set attempts=attempts+1,next_attempt_at=now()+interval '1 minute' where request_id=v_row.request_id;
      if v_row.attempts=29 then update public.service_requests set dispatch_match_status='no_nearby' where id=v_row.request_id; end if;
    end if;
    v_count:=v_count+1;
  end loop;
  for v_row in select request_id from public.delivery_quote_windows
    where status='matching' and published_at<now()-interval '45 seconds'
    order by published_at limit 100 loop
    -- This call is service-role-only, so use a narrow internal fallback here.
    insert into public.company_bid_invitations(request_id,partner_id,rider_id,distance_metres)
      select v_row.request_id,n.partner_id,n.rider_id,n.distance_metres
      from public.delivery_quote_windows w
      cross join lateral public.nearby_dispatch_companies(v_row.request_id,w.corridor_id) n
      where w.request_id=v_row.request_id and w.status='matching'
      on conflict(request_id,partner_id) do nothing;
    if exists(select 1 from public.company_bid_invitations where request_id=v_row.request_id) then
      update public.delivery_quote_windows set status='open',published_at=now(),deadline_at=now()+interval '1 minute'
        where request_id=v_row.request_id and status='matching';
    else
      update public.delivery_quote_windows set status='no_bids',closed_at=now()
        where request_id=v_row.request_id and status='matching';
    end if;
  end loop;
  delete from public.rider_presence where received_at<now()-interval '1 day';
  return v_count;
end $$;

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
      and (extensions.st_dwithin(rp.position,
        extensions.st_setsrid(extensions.st_makepoint(v_lon,v_lat),4326)::extensions.geography,5000)
        or (rp.user_id=v_invited and exists(select 1 from public.dispatch_route_proposals p
          join public.rider_route_stops s on s.rider_id=p.rider_id and s.sequence=1
          where p.request_id=v_request and p.partner_id=new.partner_id and p.rider_id=rp.user_id
            and p.algorithm_version='road-v2-live' and (p.details->>'tier')::integer in (1,2)
            and extensions.st_dwithin(
              extensions.st_setsrid(extensions.st_makepoint(s.longitude,s.latitude),4326)::extensions.geography,
              extensions.st_setsrid(extensions.st_makepoint(v_lon,v_lat),4326)::extensions.geography,2000))))
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
    exception when check_violation then null;
    end;
  end loop;
  if not v_assigned then
    update public.jobs set route_assignment_issue='No eligible rider in the selected company; resolve this paid booking before pickup'
      where id=new.job_id and assigned_rider_id is null;
  end if;
  return new;
end $$;
