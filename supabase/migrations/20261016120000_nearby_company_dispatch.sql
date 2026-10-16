-- Latest on-duty position only. No GPS trail, map API calls or location broadcasts.
create extension if not exists postgis with schema extensions;
create table public.rider_presence (
  user_id uuid primary key references auth.users(id) on delete cascade,
  partner_id uuid not null references public.logistics_partners(id),
  position extensions.geography(Point,4326) not null,
  accuracy_metres double precision not null check(accuracy_metres between 0 and 100),
  captured_at timestamptz not null,
  received_at timestamptz not null default clock_timestamp()
);
create index rider_presence_geo on public.rider_presence using gist(position);
create index rider_presence_partner on public.rider_presence(partner_id,received_at);
alter table public.rider_presence enable row level security;
revoke all on public.rider_presence from public,anon,authenticated;

create function public.report_rider_position(p_latitude double precision,p_longitude double precision,
  p_accuracy_metres double precision,p_captured_at timestamptz)
returns boolean language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
declare v_partner uuid; v_previous public.rider_presence%rowtype;
begin
  if not public.rider_session_active() then raise insufficient_privilege using message='Active rider access required'; end if;
  select c.partner_id into v_partner from public.rider_credentials c
    join public.logistics_partners p on p.id=c.partner_id and p.status='active'
    join public.partner_users u on u.user_id=c.user_id and u.partner_id=c.partner_id and u.membership_role='rider'
    where c.user_id=auth.uid();
  if v_partner is null then raise insufficient_privilege using message='Active company rider required'; end if;
  if p_latitude is null or p_latitude not between -90 and 90 or p_longitude is null or p_longitude not between -180 and 180
    or p_accuracy_metres is null or p_accuracy_metres not between 0 and 100
    or p_captured_at is null or p_captured_at<clock_timestamp()-interval '60 seconds'
    or p_captured_at>clock_timestamp()+interval '5 seconds' then
    raise check_violation using message='A fresh GPS reading accurate to 100 metres or better is required'; end if;
  -- Serialize concurrent tabs and stop/update races for this identity.
  perform 1 from public.rider_credentials where user_id=auth.uid() for update;
  select * into v_previous from public.rider_presence where user_id=auth.uid();
  if found and (v_previous.received_at>clock_timestamp()-interval '15 seconds' or v_previous.captured_at>=p_captured_at) then return false; end if;
  insert into public.rider_presence(user_id,partner_id,position,accuracy_metres,captured_at)
  values(auth.uid(),v_partner,extensions.st_setsrid(extensions.st_makepoint(p_longitude,p_latitude),4326)::extensions.geography,p_accuracy_metres,p_captured_at)
  on conflict(user_id) do update set partner_id=excluded.partner_id,position=excluded.position,
    accuracy_metres=excluded.accuracy_metres,captured_at=excluded.captured_at,received_at=clock_timestamp();
  return true;
end $$;
create function public.stop_rider_availability() returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if auth.uid() is null then raise insufficient_privilege; end if;
  perform 1 from public.rider_credentials where user_id=auth.uid() for update;
  delete from public.rider_presence where user_id=auth.uid();
end $$;
revoke all on function public.report_rider_position(double precision,double precision,double precision,timestamptz),public.stop_rider_availability() from public,anon;
grant execute on function public.report_rider_position(double precision,double precision,double precision,timestamptz),public.stop_rider_availability() to authenticated;

alter table public.service_requests add column pickup_latitude double precision,
  add column pickup_longitude double precision,add column pickup_accuracy_metres double precision,
  add column pickup_captured_at timestamptz,add column pickup_location_source text,
  add column pickup_saved_slot smallint check(pickup_saved_slot between 1 and 3),
  add column dispatch_match_status text check(dispatch_match_status in ('waiting','bidding','no_nearby','no_bids','quote_ready'));
alter table public.service_requests add constraint pickup_fix_complete check (
  (pickup_latitude is null and pickup_longitude is null and pickup_accuracy_metres is null and pickup_captured_at is null and pickup_location_source is null)
  or (pickup_latitude is not null and pickup_latitude between -90 and 90 and pickup_longitude is not null and pickup_longitude between -180 and 180
    and pickup_captured_at is not null and pickup_location_source is not null and
    ((pickup_location_source in ('browser','native') and pickup_accuracy_metres is not null and pickup_accuracy_metres between 0 and 100)
     or (pickup_location_source in ('search','saved') and pickup_accuracy_metres is null))));

alter table public.customer_parcel_destinations add column latitude double precision,add column longitude double precision,
  add column location_source text,add column location_accuracy_metres double precision;
alter table public.customer_parcel_destinations add constraint saved_address_coordinates check (
  (latitude is null and longitude is null and location_source is null and location_accuracy_metres is null)
  or (latitude is not null and latitude between -90 and 90 and longitude is not null and longitude between -180 and 180 and location_source is not null
    and ((location_source in ('browser','native') and location_accuracy_metres is not null and location_accuracy_metres between 0 and 100)
      or (location_source in ('search','saved') and location_accuracy_metres is null))));

create function public.require_local_pickup_location() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.created_by=auth.uid() and public.has_role(auth.uid(),'customer')
    and exists(select 1 from public.services where id=new.service_id and code='SRV-0001') and new.pickup_latitude is null then
    raise check_violation using message='Choose or find the pickup address and confirm its location'; end if;
  return new;
end $$;
create trigger require_local_pickup_location before insert on public.service_requests for each row execute function public.require_local_pickup_location();
revoke all on function public.require_local_pickup_location() from public,anon,authenticated;

create function public.nearby_dispatch_companies(p_request uuid,p_corridor uuid)
returns table(partner_id uuid,rider_id uuid,distance_metres double precision)
language sql stable security definer set search_path=pg_catalog,public,extensions as $$
  select distinct on (rp.partner_id) rp.partner_id,rp.user_id,
    extensions.st_distance(rp.position,extensions.st_setsrid(extensions.st_makepoint(r.pickup_longitude,r.pickup_latitude),4326)::extensions.geography)
  from public.service_requests r
  join public.rider_presence rp on extensions.st_dwithin(rp.position,
    extensions.st_setsrid(extensions.st_makepoint(r.pickup_longitude,r.pickup_latitude),4326)::extensions.geography,5000)
  join public.partner_corridor_coverage pc on pc.partner_id=rp.partner_id and pc.corridor_id=p_corridor and pc.is_enabled and pc.capacity_available
  join public.logistics_partners p on p.id=rp.partner_id and p.status='active'
  join public.rider_credentials rc on rc.user_id=rp.user_id and rc.partner_id=rp.partner_id and rc.revoked_at is null and rc.password_revoked_at is null
  join public.company_riders cr on cr.id=rc.roster_id and cr.status='approved'
  join public.partner_users pu on pu.user_id=rp.user_id and pu.partner_id=rp.partner_id and pu.membership_role='rider'
  where r.id=p_request and rp.received_at>now()-interval '2 minutes' and rp.captured_at>now()-interval '2 minutes'
    and (select count(*) from public.jobs j where j.assigned_rider_id=rp.user_id and j.status in ('pickup_scheduled','picked_up','exception'))<5
  order by rp.partner_id,3,rp.user_id;
$$;
revoke all on function public.nearby_dispatch_companies(uuid,uuid) from public,anon,authenticated;

create table public.company_bid_invitations (
  request_id uuid not null references public.delivery_quote_windows(request_id) on delete cascade,
  partner_id uuid not null references public.logistics_partners(id),
  rider_id uuid not null references auth.users(id),
  distance_metres double precision not null,
  created_at timestamptz not null default now(),
  primary key(request_id,partner_id)
);
create index company_bid_invitations_inbox on public.company_bid_invitations(partner_id,created_at desc);
alter table public.company_bid_invitations enable row level security;
revoke all on public.company_bid_invitations from public,anon,authenticated;
grant select on public.company_bid_invitations to authenticated;
create policy company_invitations_read on public.company_bid_invitations for select to authenticated
using(public.is_partner_user(partner_id));
alter publication supabase_realtime add table public.company_bid_invitations;

create function public.company_can_bid_nearby(p_request uuid,p_partner uuid) returns boolean
language sql stable security definer set search_path=pg_catalog,public as $$
  select exists(select 1 from public.service_requests r join public.services s on s.id=r.service_id
    where r.id=p_request and (s.code<>'SRV-0001' or exists (
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
revoke all on function public.company_can_bid_nearby(uuid,uuid) from public,anon;
grant execute on function public.company_can_bid_nearby(uuid,uuid) to authenticated;

create function public.invite_nearby_dispatch_companies() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_local boolean;
begin
  if new.status<>'open' then return new; end if;
  if tg_op='UPDATE' and old.status='open' and old.published_at=new.published_at then return new; end if;
  select s.code='SRV-0001' into v_local from public.service_requests r join public.services s on s.id=r.service_id where r.id=new.request_id;
  if not v_local then return new; end if;
  delete from public.company_bid_invitations where request_id=new.request_id;
  insert into public.company_bid_invitations(request_id,partner_id,rider_id,distance_metres)
  select new.request_id,n.partner_id,n.rider_id,n.distance_metres from public.nearby_dispatch_companies(new.request_id,new.corridor_id) n
  order by n.distance_metres,n.partner_id limit 50;
  if not found then raise check_violation using message='No available company rider within 5 km. Confirm the pickup location and wait for a rider to go online.'; end if;
  return new;
end $$;
create trigger invite_nearby_companies after insert or update on public.delivery_quote_windows
for each row execute function public.invite_nearby_dispatch_companies();

create function public.guard_nearby_company_bid() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if not public.company_can_bid_nearby(new.request_id,new.partner_id) then
    raise insufficient_privilege using message='Your company needs an invitation and a nearby available rider to bid'; end if;
  return new;
end $$;
create trigger guard_nearby_company_bid before insert on public.partner_quotes for each row execute function public.guard_nearby_company_bid();

drop policy windows_read on public.delivery_quote_windows;
create policy windows_read on public.delivery_quote_windows for select to authenticated using (
  exists(select 1 from public.service_requests r where r.id=request_id and public.is_customer_user(r.customer_id))
  or public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management')
  or exists(select 1 from public.partner_corridor_coverage pc join public.logistics_partners lp on lp.id=pc.partner_id
    where pc.corridor_id=delivery_quote_windows.corridor_id and pc.is_enabled and pc.capacity_available
      and lp.status='active' and public.is_partner_user(lp.id) and public.company_can_bid_nearby(delivery_quote_windows.request_id,lp.id)));

-- Automatic initial matching. One minute retries, bounded workers, no GPS write fan-out.
create table public.dispatch_match_queue (
  request_id uuid primary key references public.service_requests(id) on delete cascade,
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now()
);
alter table public.dispatch_match_queue enable row level security;
revoke all on public.dispatch_match_queue from public,anon,authenticated;
create index dispatch_match_due on public.dispatch_match_queue(next_attempt_at) where attempts<30;
create function public.try_dispatch_match(p_request uuid) returns boolean
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_corridor uuid; v_request public.service_requests%rowtype;
begin
  select * into v_request from public.service_requests where id=p_request for update;
  if v_request.status not in ('submitted','under_review') or exists(select 1 from public.delivery_quote_windows where request_id=p_request and status<>'no_bids') then return true; end if;
  select c.id into v_corridor from public.coverage_corridors c
    join public.coverage_locations o on o.id=c.origin_id and o.is_enabled
    join public.coverage_locations d on d.id=c.destination_id and d.is_enabled
    where c.is_enabled and c.service_code='SRV-0001' and lower(btrim(o.name))=lower(btrim(v_request.pickup_city))
      and lower(btrim(d.name))=lower(btrim(v_request.delivery_city)) limit 1;
  if v_corridor is null or not exists(select 1 from public.nearby_dispatch_companies(p_request,v_corridor)) then return false; end if;
  insert into public.delivery_quote_windows(request_id,corridor_id,published_at,deadline_at)
    values(p_request,v_corridor,now(),now()+interval '1 minute')
    on conflict(request_id) do update set status='open',published_at=now(),deadline_at=now()+interval '1 minute',closed_at=null;
  update public.service_requests set status='under_review',dispatch_match_status='bidding' where id=p_request;
  return true;
end $$;
create function public.queue_customer_dispatch() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.pickup_saved_slot is not null and new.pickup_latitude is not null then
    update public.customer_parcel_destinations set latitude=new.pickup_latitude,longitude=new.pickup_longitude,
      location_source=case when new.pickup_location_source='saved' then location_source else new.pickup_location_source end,
      location_accuracy_metres=case when new.pickup_location_source='saved' then location_accuracy_metres else new.pickup_accuracy_metres end
    where user_id=new.created_by and slot=new.pickup_saved_slot and address=new.pickup_address
      and lower(btrim(city))=lower(btrim(new.pickup_city));
  end if;
  if new.pickup_latitude is not null and exists(select 1 from public.services where id=new.service_id and code='SRV-0001') then
    if not public.try_dispatch_match(new.id) then
      insert into public.dispatch_match_queue(request_id) values(new.id) on conflict do nothing;
      update public.service_requests set dispatch_match_status='waiting' where id=new.id;
    end if;
  end if;
  return new;
end $$;
create trigger queue_customer_dispatch after insert on public.service_requests for each row execute function public.queue_customer_dispatch();
create function public.process_dispatch_matches() returns integer
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
  delete from public.rider_presence where received_at<now()-interval '1 day';
  return v_count;
end $$;
revoke all on function public.invite_nearby_dispatch_companies(),public.guard_nearby_company_bid(),
 public.try_dispatch_match(uuid),public.queue_customer_dispatch(),public.process_dispatch_matches() from public,anon,authenticated;
select cron.schedule('kwik-parsel-dispatch-matches','* * * * *','select public.process_dispatch_matches()');

create function public.retry_my_dispatch(p_request uuid) returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.service_requests%rowtype;
begin
  select * into r from public.service_requests where id=p_request for update;
  if not found or not public.is_customer_user(r.customer_id) then raise insufficient_privilege; end if;
  if r.dispatch_match_status not in ('no_nearby','no_bids') then raise check_violation using message='This request is already being matched'; end if;
  insert into public.dispatch_match_queue(request_id) values(r.id)
    on conflict(request_id) do update set attempts=0,next_attempt_at=now();
  update public.service_requests set dispatch_match_status='waiting' where id=r.id;
end $$;
revoke all on function public.retry_my_dispatch(uuid) from public,anon;
grant execute on function public.retry_my_dispatch(uuid) to authenticated;
create function public.sync_dispatch_window_status() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  update public.service_requests set dispatch_match_status=case new.status when 'open' then 'bidding' when 'no_bids' then 'no_bids' else 'quote_ready' end
    where id=new.request_id and pickup_location_source is not null;
  return new;
end $$;
create trigger sync_dispatch_window_status after update of status on public.delivery_quote_windows for each row execute function public.sync_dispatch_window_status();
revoke all on function public.sync_dispatch_window_status() from public,anon,authenticated;

-- Pickup details belong to the customer, invited company, and assigned rider.
create function public.list_company_bid_pickups()
returns table(request_id uuid,pickup_address text,sender_name text,sender_phone text,
  latitude double precision,longitude double precision,location_source text,nearby_rider_name text,distance_metres double precision)
language sql stable security definer set search_path=pg_catalog,public as $$
  select r.id,r.pickup_address,r.sender_name,r.sender_phone,r.pickup_latitude,r.pickup_longitude,r.pickup_location_source,
    rc.rider_name,i.distance_metres
  from public.company_bid_invitations i join public.service_requests r on r.id=i.request_id
  join public.delivery_quote_windows w on w.request_id=r.id and w.status='open' and w.deadline_at>now()
  join public.rider_credentials rc on rc.user_id=i.rider_id
  where public.is_partner_user(i.partner_id) and public.company_can_bid_nearby(r.id,i.partner_id);
$$;
create function public.list_my_rider_pickup_locations()
returns table(job_id uuid,sender_name text,sender_phone text,latitude double precision,longitude double precision,location_source text)
language sql stable security definer set search_path=pg_catalog,public as $$
  select j.id,r.sender_name,r.sender_phone,r.pickup_latitude,r.pickup_longitude,r.pickup_location_source
  from public.jobs j join public.orders o on o.id=j.order_id join public.service_requests r on r.id=o.service_request_id
  join public.partner_assignments a on a.job_id=j.id and a.partner_id=j.partner_id and a.status in ('accepted','completed')
  join public.rider_credentials rc on rc.user_id=j.assigned_rider_id and rc.partner_id=j.partner_id
  where j.assigned_rider_id=auth.uid() and public.rider_session_active() and j.status not in ('delivered','closed','cancelled');
$$;
revoke all on function public.list_company_bid_pickups(),public.list_my_rider_pickup_locations() from public,anon;
grant execute on function public.list_company_bid_pickups(),public.list_my_rider_pickup_locations() to authenticated;
create policy automated_dispatch_not_operations on public.service_requests as restrictive for all to authenticated
using(pickup_location_source is null or not public.has_role(auth.uid(),'operations')
  or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management') or public.is_customer_user(customer_id))
with check(pickup_location_source is null or not public.has_role(auth.uid(),'operations')
  or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management') or public.is_customer_user(customer_id));
create function public.is_automated_dispatch_order(p_order uuid) returns boolean
language sql stable security definer set search_path=pg_catalog,public as $$
  select exists(select 1 from public.orders o join public.service_requests r on r.id=o.service_request_id
    where o.id=p_order and r.pickup_location_source is not null);
$$;
revoke all on function public.is_automated_dispatch_order(uuid) from public,anon;
grant execute on function public.is_automated_dispatch_order(uuid) to authenticated;
create policy automated_dispatch_jobs_not_operations on public.jobs as restrictive for all to authenticated
using(not public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management')
  or public.is_customer_user(customer_id)
  or not public.is_automated_dispatch_order(order_id))
with check(not public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management')
  or public.is_customer_user(customer_id)
  or not public.is_automated_dispatch_order(order_id));
create function public.block_operations_dispatch_changes() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if public.has_role(auth.uid(),'operations') and not public.has_role(auth.uid(),'admin') and not public.has_role(auth.uid(),'management')
    and (case when tg_op='DELETE' then old.pickup_location_source else new.pickup_location_source end) is not null then
    raise insufficient_privilege using message='Company-dispatched pickups are not an Operations task'; end if;
  return case when tg_op='DELETE' then old else new end;
end $$;
create trigger block_operations_dispatch_changes before update or delete on public.service_requests
for each row execute function public.block_operations_dispatch_changes();
revoke all on function public.block_operations_dispatch_changes() from public,anon,authenticated;

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
  join public.partner_corridor_coverage pc on pc.corridor_id=w.corridor_id and pc.is_enabled and pc.capacity_available
  join public.logistics_partners p on p.id=pc.partner_id and p.status='active'
  where public.is_partner_user(pc.partner_id) and public.company_can_bid_nearby(r.id,pc.partner_id) and w.status='open' and now()<w.deadline_at;
$$;

create or replace function public.can_read_bid_parcel_photo(p_path text)
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
  select exists (
    select 1 from public.service_requests r
    join public.delivery_quote_windows w on w.request_id=r.id and w.status='open' and w.deadline_at>now()
    join public.partner_corridor_coverage pc on pc.corridor_id=w.corridor_id and pc.is_enabled and pc.capacity_available
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
  join public.partner_corridor_coverage pc on pc.corridor_id=w.corridor_id and pc.is_enabled and pc.capacity_available
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
  select pc.partner_id into v_partner from public.partner_corridor_coverage pc
  join public.logistics_partners p on p.id=pc.partner_id
  where pc.corridor_id=v_window.corridor_id and pc.is_enabled and pc.capacity_available
    and p.status='active' and public.is_partner_user(p.id) and public.company_can_bid_nearby(p_request_id,p.id)
  order by pc.partner_id limit 1;
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

create or replace function public.notify_service_request_event()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if new.pickup_location_source is not null and new.status in ('submitted','under_review') then
    if tg_op='INSERT' or new.status is distinct from old.status then
      perform public.notify_customer_users(new.customer_id,null,'dispatch_matching','Delivery matching',
        'Your pickup will be offered to nearby available companies. Follow progress in Your deliveries.',jsonb_build_object('request_id',new.id));
    end if;
    return new;
  end if;
  if tg_op = 'INSERT' and new.status = 'submitted' then
    perform public.notify_customer_users(
      new.customer_id, null, 'service_request_received', 'Request received',
      format('Request %s was sent to Gohezoh Operations for review.', new.request_number),
      jsonb_build_object('request_id', new.id, 'request_number', new.request_number)
    );
  elsif (tg_op = 'INSERT' or new.status is distinct from old.status) and new.status = 'under_review' then
    perform public.notify_customer_users(
      new.customer_id, null, 'service_request_under_review', 'Request under review',
      format('Gohezoh Operations is reviewing request %s.', new.request_number),
      jsonb_build_object('request_id', new.id, 'request_number', new.request_number)
    );
  elsif (tg_op = 'INSERT' or new.status is distinct from old.status) and new.status = 'rejected' then
    perform public.notify_customer_users(
      new.customer_id, null, 'service_request_rejected', 'Request not accepted',
      format('Request %s could not be accepted. Sign in to review the request details.', new.request_number),
      jsonb_build_object('request_id', new.id, 'request_number', new.request_number)
    );
  elsif (tg_op = 'INSERT' or new.status is distinct from old.status) and new.status = 'cancelled' then
    perform public.notify_customer_users(
      new.customer_id, null, 'service_request_cancelled', 'Request cancelled',
      format('Request %s has been cancelled.', new.request_number),
      jsonb_build_object('request_id', new.id, 'request_number', new.request_number)
    );
  end if;
  return new;
end;
$$;
