-- Revalidate company closing time at invitation, after the road worker proposes a route.
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
    where p.request_id=p_request and p.algorithm_version='road-v2-live' and p.expires_at>now()
      and public.company_dispatch_route_fits(p.partner_id,
        case when p.details->>'total_route_minutes' ~ '^[0-9]+(\.[0-9]+)?$'
          then (p.details->>'total_route_minutes')::double precision else null end)
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
    where p.request_id=p_request and (p.details->>'tier')::integer=v_tier and p.expires_at>now()
      and public.company_dispatch_route_fits(p.partner_id,
        case when p.details->>'total_route_minutes' ~ '^[0-9]+(\.[0-9]+)?$'
          then (p.details->>'total_route_minutes')::double precision else null end)
      and rp.received_at>now()-interval '2 minutes' and rp.captured_at>now()-interval '2 minutes'
      and rp.accuracy_metres<=100 and rc.revoked_at is null and rc.password_revoked_at is null and rc.load_state<>'full'
      and (v_tier<4 or extensions.st_dwithin(rp.position,
        extensions.st_setsrid(extensions.st_makepoint(r.pickup_longitude,r.pickup_latitude),4326)::extensions.geography,5000))
    order by p.partner_id,p.score,p.rider_id limit 50;
    get diagnostics v_count=row_count;
  end if;
  -- Without a road estimate, closing-time safety cannot be checked. Keep searching.
  if coalesce(v_count,0)=0 then
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
    -- The road worker timed out. No estimated route can satisfy the closing buffer.
    update public.delivery_quote_windows set status='no_bids',closed_at=now()
      where request_id=v_row.request_id and status='matching';
    insert into public.dispatch_match_queue(request_id,next_attempt_at)
      values(v_row.request_id,now()+interval '2 minutes')
      on conflict(request_id) do update set next_attempt_at=excluded.next_attempt_at;
    update public.service_requests set dispatch_match_status='waiting' where id=v_row.request_id;
  end loop;
  delete from public.rider_presence where received_at<now()-interval '1 day';
  return v_count;
end $$;


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
        and exists(select 1 from public.dispatch_route_proposals clock_proposal
          where clock_proposal.request_id=i.request_id and clock_proposal.partner_id=i.partner_id
            and clock_proposal.rider_id=i.rider_id
            and public.company_dispatch_route_fits(i.partner_id,
              case when clock_proposal.details->>'total_route_minutes' ~ '^[0-9]+(\.[0-9]+)?$'
                then (clock_proposal.details->>'total_route_minutes')::double precision else null end))
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
