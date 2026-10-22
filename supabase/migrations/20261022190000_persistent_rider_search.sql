-- Keep unmatched local requests searchable until fulfilled or cancelled.
create index if not exists dispatch_match_due_unbounded on public.dispatch_match_queue(next_attempt_at);
drop index if exists public.dispatch_match_due;


create or replace function public.finalize_live_route_match(p_request uuid) returns text
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
    insert into public.dispatch_match_queue(request_id,next_attempt_at)
      values(p_request,now()+interval '2 minutes')
      on conflict(request_id) do update set next_attempt_at=excluded.next_attempt_at;
    update public.service_requests set dispatch_match_status='waiting' where id=p_request;
    return 'no_rider';
  end if;
  update public.delivery_quote_windows set status='open',published_at=now(),deadline_at=now()+interval '1 minute'
    where request_id=p_request;
  return case when v_tier is null then 'proximity_fallback' else 'tier_'||v_tier::text end;
end $$;

create or replace function public.process_dispatch_matches() returns integer
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_row record; v_count integer:=0;
begin
  for v_row in select * from public.dispatch_match_queue where next_attempt_at<=now()
    order by next_attempt_at limit 100 for update skip locked loop
    if public.try_dispatch_match(v_row.request_id) then delete from public.dispatch_match_queue where request_id=v_row.request_id;
    else
      update public.dispatch_match_queue set attempts=attempts+1,next_attempt_at=now()+interval '2 minutes' where request_id=v_row.request_id;
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
      insert into public.dispatch_match_queue(request_id,next_attempt_at)
        values(v_row.request_id,now()+interval '2 minutes')
        on conflict(request_id) do update set next_attempt_at=excluded.next_attempt_at;
      update public.service_requests set dispatch_match_status='waiting' where id=v_row.request_id;
    end if;
  end loop;
  delete from public.rider_presence where received_at<now()-interval '1 day';
  return v_count;
end $$;

