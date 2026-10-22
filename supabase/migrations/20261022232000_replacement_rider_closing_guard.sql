-- A nearby idle replacement may inherit its company invitation when the original
-- road estimate still fits the company closing time.
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
