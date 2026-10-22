-- Each company gets one live local-delivery invitation at a time. A request
-- waits until the last invited company's one-minute slot has finished.
alter table public.company_bid_invitations
  add column starts_at timestamptz,
  add column deadline_at timestamptz,
  add constraint company_bid_invitation_slot_check
    check ((starts_at is null and deadline_at is null)
      or (starts_at is not null and deadline_at is not null and deadline_at>starts_at));
update public.company_bid_invitations i set starts_at=w.published_at,deadline_at=w.deadline_at
  from public.delivery_quote_windows w where w.request_id=i.request_id and w.status='open';
create index company_bid_invitations_schedule on public.company_bid_invitations(partner_id,deadline_at)
  where deadline_at is not null;

create function public.schedule_company_bid_invitations(p_request uuid)
returns timestamptz language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_inv record;v_tail timestamptz;v_start timestamptz;v_finish timestamptz;
  v_minutes double precision;
begin
  if auth.role()<>'service_role' then raise insufficient_privilege using message='Routing worker access required'; end if;
  for v_inv in select i.partner_id from public.company_bid_invitations i
    where i.request_id=p_request order by i.partner_id loop
    -- Serialize scheduling for this company across simultaneous rider matches.
    perform pg_catalog.pg_advisory_xact_lock(612793,pg_catalog.hashtext(v_inv.partner_id::text));
    select max(i.deadline_at) into v_tail from public.company_bid_invitations i
      join public.delivery_quote_windows w on w.request_id=i.request_id and w.status='open'
      where i.partner_id=v_inv.partner_id and i.request_id<>p_request and i.deadline_at>clock_timestamp();
    v_start:=greatest(clock_timestamp(),coalesce(v_tail,clock_timestamp()));
    select max(case when p.details->>'total_route_minutes' ~ '^[0-9]+(\.[0-9]+)?$'
      then (p.details->>'total_route_minutes')::double precision else null end)
      into v_minutes from public.dispatch_route_proposals p
      where p.request_id=p_request and p.partner_id=v_inv.partner_id;
    -- Include one minute to bid and two minutes for customer payment before
    -- testing the full route plus its existing 20-minute close buffer.
    if v_start>=public.company_dispatch_close_at(v_inv.partner_id,clock_timestamp())
      or not public.company_dispatch_route_fits(v_inv.partner_id,v_minutes,v_start+interval '3 minutes') then
      delete from public.company_bid_invitations i where i.request_id=p_request and i.partner_id=v_inv.partner_id;
      continue;
    end if;
    update public.company_bid_invitations i set starts_at=v_start,deadline_at=v_start+interval '1 minute'
      where i.request_id=p_request and i.partner_id=v_inv.partner_id;
  end loop;
  select max(i.deadline_at) into v_finish from public.company_bid_invitations i where i.request_id=p_request;
  return v_finish;
end $$;
revoke all on function public.schedule_company_bid_invitations(uuid) from public,anon,authenticated;
grant execute on function public.schedule_company_bid_invitations(uuid) to service_role;

create function public.guard_local_bid_slot() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if exists(select 1 from public.service_requests r join public.services s on s.id=r.service_id
    where r.id=new.request_id and s.code='SRV-0001' and r.pickup_location_source is not null)
    and not exists(select 1 from public.company_bid_invitations i
      where i.request_id=new.request_id and i.partner_id=new.partner_id
        and i.starts_at<=clock_timestamp() and i.deadline_at>clock_timestamp()) then
    raise object_not_in_prerequisite_state using message='Your company bidding turn is not open';
  end if;
  return new;
end $$;
create trigger guard_local_bid_slot before insert on public.partner_quotes
  for each row execute function public.guard_local_bid_slot();
revoke all on function public.guard_local_bid_slot() from public,anon,authenticated;

drop policy company_invitations_read on public.company_bid_invitations;
create policy company_invitations_read on public.company_bid_invitations for select to authenticated
using(public.company_staff_allowed(partner_id,'bid') and starts_at<=clock_timestamp() and deadline_at>clock_timestamp());

create or replace function public.finalize_live_route_match(p_request uuid) returns text
language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
declare v_window public.delivery_quote_windows%rowtype; v_tier integer; v_count integer;v_finish timestamptz;
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
  if coalesce(v_count,0)>0 then
    v_finish:=public.schedule_company_bid_invitations(p_request);
    select count(*) into v_count from public.company_bid_invitations where request_id=p_request;
  end if;
  -- A company whose queue would push delivery past closing is skipped.
  if coalesce(v_count,0)=0 then
    update public.delivery_quote_windows set status='no_bids',closed_at=now() where request_id=p_request;
    insert into public.dispatch_match_queue(request_id,next_attempt_at)
      values(p_request,now()+interval '2 minutes')
      on conflict(request_id) do update set next_attempt_at=excluded.next_attempt_at;
    update public.service_requests set dispatch_match_status='waiting' where id=p_request;
    return 'no_rider';
  end if;
  update public.delivery_quote_windows set status='open',published_at=now(),deadline_at=v_finish
    where request_id=p_request;
  return case when v_tier is null then 'proximity_fallback' else 'tier_'||v_tier::text end;
end $$;



create or replace function public.company_can_bid_nearby(p_request uuid,p_partner uuid) returns boolean
language sql volatile security definer set search_path=pg_catalog,public,extensions as $$
  select exists(select 1 from public.service_requests r join public.services s on s.id=r.service_id
    where r.id=p_request and (s.code<>'SRV-0001' or r.pickup_location_source is null or exists (
      select 1 from public.company_bid_invitations i
      join public.rider_presence rp on rp.user_id=i.rider_id and rp.partner_id=i.partner_id
      join public.rider_credentials rc on rc.user_id=i.rider_id and rc.partner_id=i.partner_id
        and rc.revoked_at is null and rc.password_revoked_at is null and rc.load_state<>'full'
      join public.company_riders cr on cr.id=rc.roster_id and cr.status='approved'
      join public.partner_users pu on pu.user_id=i.rider_id and pu.partner_id=i.partner_id and pu.membership_role='rider'
      where i.request_id=r.id and i.partner_id=p_partner
        and i.starts_at<=clock_timestamp() and i.deadline_at>clock_timestamp()
        and exists(select 1 from public.dispatch_route_proposals clock_proposal
          where clock_proposal.request_id=i.request_id and clock_proposal.partner_id=i.partner_id
            and (clock_proposal.rider_id=i.rider_id or not exists(
              select 1 from public.jobs assigned where assigned.assigned_rider_id=i.rider_id
                and assigned.status in ('pickup_scheduled','picked_up','in_transit','out_for_delivery','exception')))
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

create or replace function public.list_partner_bid_screen()
returns table(request_id uuid,request_number text,pickup_city text,delivery_city text,
  parcel_summary text,parcel_items jsonb,photo_path text,deadline_at timestamptz,
  own_bid_amount_ngn numeric,own_bid_status text)
language sql stable security definer set search_path=pg_catalog,public as $$
  select r.id,r.request_number,r.pickup_city,r.delivery_city,r.parcel_summary,r.parcel_items,
    coalesce(r.parcel_photo_path,(select sp.photo_path from public.customer_saved_parcels sp
      where sp.id::text=r.parcel_items->0->>'saved_parcel_id' and sp.user_id=r.created_by)),
    coalesce(pc.deadline_at,w.deadline_at),
    (select q.amount_ngn from public.partner_quotes q where q.request_id=r.id and q.partner_id=pc.partner_id order by q.version desc limit 1),
    (select q.status from public.partner_quotes q where q.request_id=r.id and q.partner_id=pc.partner_id order by q.version desc limit 1)
  from public.delivery_quote_windows w
  join public.service_requests r on r.id=w.request_id
  join lateral (
    select i.partner_id,i.deadline_at from public.company_bid_invitations i
      where i.request_id=r.id and r.pickup_location_source is not null
    union
    select pc.partner_id,null::timestamptz from public.partner_corridor_coverage pc
      where pc.corridor_id=w.corridor_id and pc.is_enabled and pc.capacity_available
        and r.pickup_location_source is null
  ) pc on true
  join public.logistics_partners p on p.id=pc.partner_id and p.status='active'
  where public.company_staff_allowed(pc.partner_id,'bid') and public.company_can_bid_nearby(r.id,pc.partner_id) and w.status='open' and now()<w.deadline_at;
$$;


create or replace function public.list_eligible_delivery_requests()
returns table(request_id uuid,request_number text,pickup_city text,delivery_city text,parcel_summary text,
  preferred_pickup_at timestamptz,special_instructions text,published_at timestamptz,deadline_at timestamptz,
  own_bid_amount_ngn numeric,own_bid_status text)
language sql stable security definer set search_path=pg_catalog,public as $$
  select r.id,r.request_number,r.pickup_city,r.delivery_city,r.parcel_summary,r.preferred_pickup_at,
    r.special_instructions,coalesce(pc.starts_at,w.published_at),coalesce(pc.deadline_at,w.deadline_at),
    (select q.amount_ngn from public.partner_quotes q where q.request_id=r.id and q.partner_id=pc.partner_id
      order by q.version desc limit 1),
    (select q.status from public.partner_quotes q where q.request_id=r.id and q.partner_id=pc.partner_id
      order by q.version desc limit 1)
  from public.delivery_quote_windows w
  join public.service_requests r on r.id=w.request_id
  join lateral (
    select i.partner_id,i.starts_at,i.deadline_at from public.company_bid_invitations i
      where i.request_id=r.id and r.pickup_location_source is not null
    union
    select pc.partner_id,null::timestamptz,null::timestamptz from public.partner_corridor_coverage pc
      where pc.corridor_id=w.corridor_id and pc.is_enabled and pc.capacity_available
        and r.pickup_location_source is null
  ) pc on true
  join public.logistics_partners p on p.id=pc.partner_id and p.status='active'
  where public.is_partner_user(pc.partner_id) and public.company_can_bid_nearby(r.id,pc.partner_id) and w.status='open' and now()<w.deadline_at;
$$;

