-- Existing local requests without pickup coordinates retain their original bidding path.
create or replace function public.company_can_bid_nearby(p_request uuid,p_partner uuid) returns boolean
language sql stable security definer set search_path=pg_catalog,public as $$
  select exists(select 1 from public.service_requests r join public.services s on s.id=r.service_id
    where r.id=p_request and (s.code<>'SRV-0001' or r.pickup_location_source is null or exists (
      select 1 from public.company_bid_invitations i join public.delivery_quote_windows w on w.request_id=i.request_id
      where i.request_id=r.id and i.partner_id=p_partner and exists (
        select 1 from public.rider_presence rp
        join public.rider_credentials rc on rc.user_id=rp.user_id and rc.partner_id=rp.partner_id and rc.revoked_at is null and rc.password_revoked_at is null
        join public.company_riders cr on cr.id=rc.roster_id and cr.status='approved'
        join public.partner_users pu on pu.user_id=rp.user_id and pu.partner_id=rp.partner_id and pu.membership_role='rider'
        where rp.partner_id=p_partner and rp.received_at>now()-interval '2 minutes' and rp.captured_at>now()-interval '2 minutes'
        and extensions.st_dwithin(rp.position,extensions.st_setsrid(extensions.st_makepoint(r.pickup_longitude,r.pickup_latitude),4326)::extensions.geography,5000)
        and (select count(*) from public.jobs j where j.assigned_rider_id=rp.user_id and j.status in ('pickup_scheduled','picked_up','exception'))<5))));
$$;
create or replace function public.invite_nearby_dispatch_companies() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_local boolean; v_has_pickup boolean;
begin
  if new.status<>'open' then return new; end if;
  if tg_op='UPDATE' and old.status='open' and old.published_at=new.published_at then return new; end if;
  select s.code='SRV-0001',r.pickup_location_source is not null into v_local,v_has_pickup
    from public.service_requests r join public.services s on s.id=r.service_id where r.id=new.request_id;
  if not v_local or not v_has_pickup then return new; end if;
  delete from public.company_bid_invitations where request_id=new.request_id;
  insert into public.company_bid_invitations(request_id,partner_id,rider_id,distance_metres)
  select new.request_id,n.partner_id,n.rider_id,n.distance_metres from public.nearby_dispatch_companies(new.request_id,new.corridor_id) n
  order by n.distance_metres,n.partner_id limit 50;
  if not found then raise check_violation using message='No available company rider within 5 km. Confirm the pickup location and wait for a rider to go online.'; end if;
  return new;
end $$;
