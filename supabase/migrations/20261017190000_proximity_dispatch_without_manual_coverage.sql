-- Local pickup invitations come from live rider proximity; legacy and interstate bids retain explicit corridor coverage.
create or replace function public.nearby_dispatch_companies(p_request uuid,p_corridor uuid)
returns table(partner_id uuid,rider_id uuid,distance_metres double precision)
language sql stable security definer set search_path=pg_catalog,public,extensions as $$
  select distinct on (rp.partner_id) rp.partner_id,rp.user_id,
    extensions.st_distance(rp.position,extensions.st_setsrid(extensions.st_makepoint(r.pickup_longitude,r.pickup_latitude),4326)::extensions.geography)
  from public.service_requests r
  join public.rider_presence rp on extensions.st_dwithin(rp.position,
    extensions.st_setsrid(extensions.st_makepoint(r.pickup_longitude,r.pickup_latitude),4326)::extensions.geography,5000)
  join public.logistics_partners p on p.id=rp.partner_id and p.status='active'
  join public.rider_credentials rc on rc.user_id=rp.user_id and rc.partner_id=rp.partner_id and rc.revoked_at is null and rc.password_revoked_at is null
  join public.company_riders cr on cr.id=rc.roster_id and cr.status='approved'
  join public.partner_users pu on pu.user_id=rp.user_id and pu.partner_id=rp.partner_id and pu.membership_role='rider'
  where r.id=p_request and rp.received_at>now()-interval '2 minutes' and rp.captured_at>now()-interval '2 minutes'
    and (select count(*) from public.jobs j where j.assigned_rider_id=rp.user_id and j.status in ('pickup_scheduled','picked_up','exception'))<5
  order by rp.partner_id,3,rp.user_id;
$$;

drop policy if exists windows_read on public.delivery_quote_windows;
create policy windows_read on public.delivery_quote_windows for select to authenticated using (
  exists(select 1 from public.service_requests r where r.id=request_id and public.is_customer_user(r.customer_id))
  or public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management')
  or exists(select 1 from public.company_bid_invitations i join public.logistics_partners lp on lp.id=i.partner_id and lp.status='active'
    where i.request_id=delivery_quote_windows.request_id and public.is_partner_user(i.partner_id)
      and public.company_can_bid_nearby(i.request_id,i.partner_id))
  or exists(select 1 from public.service_requests r join public.partner_corridor_coverage pc on pc.corridor_id=delivery_quote_windows.corridor_id
      join public.logistics_partners lp on lp.id=pc.partner_id and lp.status='active'
    where r.id=delivery_quote_windows.request_id and r.pickup_location_source is null
      and pc.is_enabled and pc.capacity_available and public.is_partner_user(pc.partner_id)));

create or replace function public.list_partner_bid_screen()
returns table(request_id uuid,request_number text,pickup_city text,delivery_city text,
  parcel_summary text,parcel_items jsonb,photo_path text,deadline_at timestamptz,
  own_bid_amount_ngn numeric,own_bid_status text)
language sql stable security definer set search_path=pg_catalog,public as $$
  select r.id,r.request_number,r.pickup_city,r.delivery_city,r.parcel_summary,r.parcel_items,
    coalesce(r.parcel_photo_path,(select sp.photo_path from public.customer_saved_parcels sp
      where sp.id::text=r.parcel_items->0->>'saved_parcel_id' and sp.user_id=r.created_by)),
    w.deadline_at,
    (select q.amount_ngn from public.partner_quotes q where q.request_id=r.id and q.partner_id=pc.partner_id order by q.version desc limit 1),
    (select q.status from public.partner_quotes q where q.request_id=r.id and q.partner_id=pc.partner_id order by q.version desc limit 1)
  from public.delivery_quote_windows w
  join public.service_requests r on r.id=w.request_id
  join lateral (
    select i.partner_id from public.company_bid_invitations i
      where i.request_id=r.id and r.pickup_location_source is not null
    union
    select pc.partner_id from public.partner_corridor_coverage pc
      where pc.corridor_id=w.corridor_id and pc.is_enabled and pc.capacity_available
        and r.pickup_location_source is null
  ) pc on true
  join public.logistics_partners p on p.id=pc.partner_id and p.status='active'
  where public.is_partner_user(pc.partner_id) and public.company_can_bid_nearby(r.id,pc.partner_id) and w.status='open' and now()<w.deadline_at;
$$;

create or replace function public.can_read_bid_parcel_photo(p_path text)
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
  select exists (
    select 1 from public.service_requests r
    join public.delivery_quote_windows w on w.request_id=r.id and w.status='open' and w.deadline_at>now()
    join lateral (
    select i.partner_id from public.company_bid_invitations i
      where i.request_id=r.id and r.pickup_location_source is not null
    union
    select pc.partner_id from public.partner_corridor_coverage pc
      where pc.corridor_id=w.corridor_id and pc.is_enabled and pc.capacity_available
        and r.pickup_location_source is null
  ) pc on true
    join public.logistics_partners p on p.id=pc.partner_id and p.status='active'
    where (r.parcel_photo_path=p_path or exists (select 1 from public.customer_saved_parcels sp
      where sp.id::text=r.parcel_items->0->>'saved_parcel_id' and sp.user_id=r.created_by and sp.photo_path=p_path))
      and public.is_partner_user(pc.partner_id) and public.company_can_bid_nearby(r.id,pc.partner_id)
  );
$$;

create or replace function public.list_eligible_delivery_requests()
returns table(request_id uuid,request_number text,pickup_city text,delivery_city text,parcel_summary text,
  preferred_pickup_at timestamptz,special_instructions text,published_at timestamptz,deadline_at timestamptz,
  own_bid_amount_ngn numeric,own_bid_status text)
language sql stable security definer set search_path=pg_catalog,public as $$
  select r.id,r.request_number,r.pickup_city,r.delivery_city,r.parcel_summary,r.preferred_pickup_at,
    r.special_instructions,w.published_at,w.deadline_at,
    (select q.amount_ngn from public.partner_quotes q where q.request_id=r.id and q.partner_id=pc.partner_id
      order by q.version desc limit 1),
    (select q.status from public.partner_quotes q where q.request_id=r.id and q.partner_id=pc.partner_id
      order by q.version desc limit 1)
  from public.delivery_quote_windows w
  join public.service_requests r on r.id=w.request_id
  join lateral (
    select i.partner_id from public.company_bid_invitations i
      where i.request_id=r.id and r.pickup_location_source is not null
    union
    select pc.partner_id from public.partner_corridor_coverage pc
      where pc.corridor_id=w.corridor_id and pc.is_enabled and pc.capacity_available
        and r.pickup_location_source is null
  ) pc on true
  join public.logistics_partners p on p.id=pc.partner_id and p.status='active'
  where public.is_partner_user(pc.partner_id) and public.company_can_bid_nearby(r.id,pc.partner_id) and w.status='open' and now()<w.deadline_at;
$$;

create or replace function public.submit_partner_quote(p_request_id uuid,p_amount_ngn numeric,p_eta_hours integer,
  p_inclusions text,p_exclusions text,p_availability_confirmed boolean,p_surcharge_conditions text)
returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_window public.delivery_quote_windows%rowtype;v_partner uuid;v_id uuid;
begin
  select * into v_window from public.delivery_quote_windows where request_id=p_request_id for update;
  if not found or v_window.status<>'open' or now()>=v_window.deadline_at then
    raise object_not_in_prerequisite_state using message='Quote window is closed'; end if;
  select candidate.partner_id into v_partner from (
    select i.partner_id from public.company_bid_invitations i join public.service_requests r on r.id=i.request_id
      where i.request_id=p_request_id and r.pickup_location_source is not null
    union
    select pc.partner_id from public.partner_corridor_coverage pc join public.service_requests r on r.id=p_request_id
      where pc.corridor_id=v_window.corridor_id and pc.is_enabled and pc.capacity_available
        and r.pickup_location_source is null
  ) candidate join public.logistics_partners p on p.id=candidate.partner_id
  where p.status='active' and public.is_partner_user(p.id) and public.company_can_bid_nearby(p_request_id,p.id)
  order by candidate.partner_id limit 1;
  if v_partner is null then raise insufficient_privilege using message='Partner is not eligible for this corridor'; end if;
  if p_amount_ngn is null or p_amount_ngn<=0 or p_eta_hours is null or p_eta_hours<=0
    or p_availability_confirmed is distinct from true
    or nullif(btrim(p_inclusions),'') is null or nullif(btrim(p_exclusions),'') is null
    or nullif(btrim(p_surcharge_conditions),'') is null then
    raise check_violation using message='Complete quote details are required'; end if;
  update public.partner_quotes set status='invalid',invalidation_reason='Superseded by a newer quote'
  where request_id=p_request_id and partner_id=v_partner and status='valid';
  insert into public.partner_quotes(request_id,partner_id,amount_ngn,eta_hours,availability_confirmed,
    inclusions,exclusions,surcharge_conditions,version)
  values(p_request_id,v_partner,p_amount_ngn,p_eta_hours,true,btrim(p_inclusions),btrim(p_exclusions),
    btrim(p_surcharge_conditions),
    coalesce((select max(version)+1 from public.partner_quotes where request_id=p_request_id and partner_id=v_partner),1))
  returning id into v_id;
  return v_id;
end $$;


-- Refresh the dispatch worker schedule after deployment. The old schedule was active but had never run.
do $$ begin
  if exists(select 1 from cron.job where jobname='kwik-parsel-dispatch-matches') then
    perform cron.unschedule('kwik-parsel-dispatch-matches');
  end if;
  perform cron.schedule('kwik-parsel-dispatch-matches','* * * * *','select public.process_dispatch_matches()');
end $$;
