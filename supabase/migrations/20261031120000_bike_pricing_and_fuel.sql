-- Bike-only automatic prices and an estimated fuel ledger. No tank sensor is implied.
create table public.bike_price_policy (
  id boolean primary key default true check (id),
  benchmark_distance_metres integer not null default 13019 check (benchmark_distance_metres > 0),
  benchmark_charge_ngn numeric(12,2) not null default 4000 check (benchmark_charge_ngn >= 1000),
  benchmark_fuel_price_ngn numeric(12,2) not null default 1400 check (benchmark_fuel_price_ngn > 0),
  fuel_price_ngn numeric(12,2) not null default 1400 check (fuel_price_ngn > 0),
  litres_per_km numeric(8,5) not null default 0.025 check (litres_per_km > 0),
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);
insert into public.bike_price_policy(id) values(true);
alter table public.bike_price_policy enable row level security;
grant select on public.bike_price_policy to authenticated;
create policy bike_price_read on public.bike_price_policy for select to authenticated using (true);

create function public.set_bike_fuel_price(p_price_ngn numeric) returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if not public.has_role(auth.uid(),'admin') then raise insufficient_privilege; end if;
  if p_price_ngn is null or p_price_ngn < 100 or p_price_ngn > 10000 then
    raise check_violation using message='Enter a fuel price between NGN 100 and NGN 10,000 per litre';
  end if;
  update public.bike_price_policy set fuel_price_ngn=round(p_price_ngn,2),updated_by=auth.uid(),updated_at=now() where id=true;
end $$;
revoke all on function public.set_bike_fuel_price(numeric) from public,anon;
grant execute on function public.set_bike_fuel_price(numeric) to authenticated;

create function public.bike_customer_price(p_distance_metres integer,p_fuel_price_ngn numeric,
  p_benchmark_distance_metres integer,p_benchmark_charge_ngn numeric,p_benchmark_fuel_price_ngn numeric,
  p_litres_per_km numeric) returns integer
language sql immutable set search_path=pg_catalog as $$
  select greatest(1000,ceil((p_benchmark_charge_ngn * p_distance_metres / p_benchmark_distance_metres
    + p_distance_metres / 1000.0 * p_litres_per_km * (p_fuel_price_ngn-p_benchmark_fuel_price_ngn))/100.0)*100)::integer;
$$;
revoke all on function public.bike_customer_price(integer,numeric,integer,numeric,numeric,numeric) from public,anon;
grant execute on function public.bike_customer_price(integer,numeric,integer,numeric,numeric,numeric) to authenticated;

create table public.bike_route_prices (
  request_id uuid primary key references public.service_requests(id) on delete cascade,
  distance_metres integer not null check(distance_metres > 0),
  duration_seconds integer not null check(duration_seconds > 0),
  customer_price_ngn integer not null check(customer_price_ngn >= 1000),
  company_share_ngn numeric(12,2) generated always as (customer_price_ngn*0.75) stored,
  platform_share_ngn numeric(12,2) generated always as (customer_price_ngn*0.25) stored,
  estimated_fuel_litres numeric(10,3) not null check(estimated_fuel_litres > 0),
  fuel_price_ngn_per_litre numeric(12,2) not null,
  source text not null check(source='google_routes_drive'),
  created_at timestamptz not null default now()
);
alter table public.bike_route_prices enable row level security;
grant select on public.bike_route_prices to authenticated;
create policy bike_route_price_read on public.bike_route_prices for select to authenticated using (
  exists(select 1 from public.service_requests r where r.id=request_id and public.is_customer_user(r.customer_id))
  or exists(select 1 from public.company_bid_invitations i where i.request_id=request_id and public.company_staff_allowed(i.partner_id,'bid'))
  or public.has_role(auth.uid(),'admin'));

create function public.record_bike_route_price(p_request_id uuid,p_distance_metres integer,p_duration_seconds integer)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_policy public.bike_price_policy%rowtype;v_request public.service_requests%rowtype;v_price integer;
begin
  if auth.role()<>'service_role' then raise insufficient_privilege; end if;
  select * into v_request from public.service_requests where id=p_request_id;
  if not found or v_request.pickup_city<>v_request.delivery_city or v_request.pickup_latitude is null
    or v_request.pickup_longitude is null or v_request.delivery_latitude is null or v_request.delivery_longitude is null then
    raise check_violation using message='Only geocoded local requests can use automatic bike pricing'; end if;
  if p_distance_metres not between 100 and 200000 or p_duration_seconds not between 30 and 86400 then
    raise check_violation using message='Invalid route distance or duration'; end if;
  select * into v_policy from public.bike_price_policy where id=true;
  v_price:=public.bike_customer_price(p_distance_metres,v_policy.fuel_price_ngn,v_policy.benchmark_distance_metres,
    v_policy.benchmark_charge_ngn,v_policy.benchmark_fuel_price_ngn,v_policy.litres_per_km);
  insert into public.bike_route_prices(request_id,distance_metres,duration_seconds,customer_price_ngn,
    estimated_fuel_litres,fuel_price_ngn_per_litre,source)
  values(p_request_id,p_distance_metres,p_duration_seconds,v_price,
    round(p_distance_metres/1000.0*v_policy.litres_per_km,3),v_policy.fuel_price_ngn,'google_routes_drive')
  on conflict(request_id) do nothing;
end $$;
revoke all on function public.record_bike_route_price(uuid,integer,integer) from public,anon,authenticated;
grant execute on function public.record_bike_route_price(uuid,integer,integer) to service_role;

create table public.bike_fuel_purchases (
  id uuid primary key default gen_random_uuid(),
  rider_id uuid not null references public.company_riders(id),
  litres numeric(8,2) not null check(litres > 0 and litres <= 100),
  amount_ngn numeric(12,2) not null check(amount_ngn > 0),
  recorded_by uuid not null references auth.users(id),
  purchased_at timestamptz not null default now()
);
create index bike_fuel_purchases_rider_time on public.bike_fuel_purchases(rider_id,purchased_at desc);
alter table public.bike_fuel_purchases enable row level security;
grant select on public.bike_fuel_purchases to authenticated;
create policy bike_fuel_purchase_read on public.bike_fuel_purchases for select to authenticated using (
  exists(select 1 from public.company_riders r where r.id=rider_id and public.company_staff_allowed(r.partner_id,'riders')));

create function public.record_bike_fuel_purchase(p_rider_id uuid,p_litres numeric,p_amount_ngn numeric)
returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_id uuid;
begin
  if p_litres is null or p_litres<=0 or p_litres>100 or p_amount_ngn is null or p_amount_ngn<=0 then
    raise check_violation using message='Enter valid litres and amount'; end if;
  if not exists(select 1 from public.company_riders r join public.partner_application_vehicles v on v.id=r.source_vehicle_id
    where r.id=p_rider_id and r.status='approved' and v.vehicle_type='motorcycle'
      and public.company_staff_allowed(r.partner_id,'riders')) then
    raise insufficient_privilege using message='Choose an approved motorcycle rider in your company'; end if;
  insert into public.bike_fuel_purchases(rider_id,litres,amount_ngn,recorded_by)
  values(p_rider_id,p_litres,p_amount_ngn,auth.uid()) returning id into v_id;
  return v_id;
end $$;
revoke all on function public.record_bike_fuel_purchase(uuid,numeric,numeric) from public,anon;
grant execute on function public.record_bike_fuel_purchase(uuid,numeric,numeric) to authenticated;

create function public.list_my_bike_fuel_gauges()
returns table(rider_id uuid,rider_name text,registration_number text,purchased_litres numeric,
  purchased_amount_ngn numeric,estimated_used_litres numeric,estimated_remaining_litres numeric)
language sql stable security definer set search_path=pg_catalog,public as $$
  select r.id,r.full_name,v.registration_number,
    coalesce((select sum(f.litres) from public.bike_fuel_purchases f where f.rider_id=r.id),0),
    coalesce((select sum(f.amount_ngn) from public.bike_fuel_purchases f where f.rider_id=r.id),0),
    coalesce((select sum(bp.estimated_fuel_litres) from public.jobs j
      join public.orders o on o.id=j.order_id
      join public.bike_route_prices bp on bp.request_id=o.service_request_id
      where j.assigned_rider_id=rc.user_id and j.status in ('delivered','closed')),0),
    greatest(0,coalesce((select sum(f.litres) from public.bike_fuel_purchases f where f.rider_id=r.id),0)
      - coalesce((select sum(bp.estimated_fuel_litres) from public.jobs j
        join public.orders o on o.id=j.order_id
        join public.bike_route_prices bp on bp.request_id=o.service_request_id
        where j.assigned_rider_id=rc.user_id and j.status in ('delivered','closed')),0))
  from public.company_riders r
  join public.partner_application_vehicles v on v.id=r.source_vehicle_id and v.vehicle_type='motorcycle'
  left join public.rider_credentials rc on rc.roster_id=r.id and rc.revoked_at is null
  where r.status='approved' and public.company_staff_allowed(r.partner_id,'riders')
  order by r.full_name;
$$;
revoke all on function public.list_my_bike_fuel_gauges() from public,anon;
grant execute on function public.list_my_bike_fuel_gauges() to authenticated;

-- Existing partner quote and payment tables remain the settlement source of truth.
create table public.declined_bike_offers (
  request_id uuid not null references public.service_requests(id) on delete cascade,
  partner_id uuid not null references public.logistics_partners(id),
  declined_by uuid not null references auth.users(id),
  declined_at timestamptz not null default now(),
  primary key(request_id,partner_id)
);
alter table public.declined_bike_offers enable row level security;
revoke all on public.declined_bike_offers from anon,authenticated;

create function public.decline_bike_price(p_request_id uuid) returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_partner uuid;
begin
  select i.partner_id into v_partner from public.company_bid_invitations i
    join public.delivery_quote_windows w on w.request_id=i.request_id and w.status='open'
    join public.bike_route_prices bp on bp.request_id=i.request_id
    join public.rider_credentials rc on rc.user_id=i.rider_id and rc.partner_id=i.partner_id
    join public.company_riders r on r.id=rc.roster_id
    join public.partner_application_vehicles v on v.id=r.source_vehicle_id and v.vehicle_type='motorcycle'
  where i.request_id=p_request_id and i.starts_at<=clock_timestamp() and i.deadline_at>clock_timestamp()
    and public.company_staff_allowed(i.partner_id,'bid')
  order by i.partner_id limit 1;
  if v_partner is null then raise insufficient_privilege using message='No eligible motorcycle invitation is open'; end if;
  insert into public.declined_bike_offers(request_id,partner_id,declined_by)
  values(p_request_id,v_partner,auth.uid()) on conflict do nothing;
end $$;
revoke all on function public.decline_bike_price(uuid) from public,anon;
grant execute on function public.decline_bike_price(uuid) to authenticated;

create function public.accept_bike_price(p_request_id uuid) returns uuid
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_partner uuid;v_route public.bike_route_prices%rowtype;v_quote uuid;
begin
  select * into v_route from public.bike_route_prices where request_id=p_request_id;
  if not found then raise object_not_in_prerequisite_state using message='Bike price is still being calculated'; end if;
  select i.partner_id into v_partner from public.company_bid_invitations i
    join public.delivery_quote_windows w on w.request_id=i.request_id and w.status='open'
    join public.logistics_partners p on p.id=i.partner_id and p.status='active'
    join public.rider_credentials rc on rc.user_id=i.rider_id and rc.partner_id=i.partner_id and rc.revoked_at is null
    join public.company_riders r on r.id=rc.roster_id and r.status='approved'
    join public.partner_application_vehicles v on v.id=r.source_vehicle_id and v.vehicle_type='motorcycle'
  where i.request_id=p_request_id and i.starts_at<=clock_timestamp() and i.deadline_at>clock_timestamp()
    and public.company_staff_allowed(i.partner_id,'bid') and public.company_can_bid_nearby(p_request_id,i.partner_id)
    and not exists(select 1 from public.declined_bike_offers d where d.request_id=i.request_id and d.partner_id=i.partner_id)
  order by i.partner_id limit 1;
  if v_partner is null then raise insufficient_privilege using message='No eligible motorcycle invitation is open for this company'; end if;
  perform pg_catalog.set_config('kwikparsel.fixed_bike_accept','on',true);
  insert into public.partner_quotes(request_id,partner_id,amount_ngn,eta_hours,availability_confirmed,
    inclusions,exclusions,surcharge_conditions,version)
  values(p_request_id,v_partner,v_route.customer_price_ngn,greatest(1,ceil(v_route.duration_seconds/3600.0)::integer),
    true,'Pickup and delivery','None','None',
    coalesce((select max(version)+1 from public.partner_quotes where request_id=p_request_id and partner_id=v_partner),1))
  returning id into v_quote;
  return v_quote;
end $$;
revoke all on function public.accept_bike_price(uuid) from public,anon;
grant execute on function public.accept_bike_price(uuid) to authenticated;

create function public.guard_bike_fixed_price() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if exists(select 1 from public.bike_route_prices p
    join public.company_bid_invitations i on i.request_id=p.request_id and i.partner_id=new.partner_id
    join public.rider_credentials rc on rc.user_id=i.rider_id and rc.partner_id=i.partner_id
    join public.company_riders r on r.id=rc.roster_id
    join public.partner_application_vehicles v on v.id=r.source_vehicle_id and v.vehicle_type='motorcycle'
    where p.request_id=new.request_id)
    and (current_setting('kwikparsel.fixed_bike_accept',true) is distinct from 'on'
      or not exists(select 1 from public.bike_route_prices p where p.request_id=new.request_id and p.customer_price_ngn=new.amount_ngn)) then
    raise check_violation using message='This motorcycle job has a fixed customer price';
  end if;
  return new;
end $$;
create trigger guard_bike_fixed_price before insert or update of amount_ngn on public.partner_quotes
  for each row execute function public.guard_bike_fixed_price();

create function public.list_company_bike_prices() returns table(request_id uuid,customer_price_ngn integer,
  company_share_ngn numeric,distance_metres integer,duration_seconds integer,estimated_fuel_litres numeric,declined boolean)
language sql stable security definer set search_path=pg_catalog,public as $$
  select p.request_id,p.customer_price_ngn,p.company_share_ngn,p.distance_metres,p.duration_seconds,p.estimated_fuel_litres,
    exists(select 1 from public.declined_bike_offers d where d.request_id=p.request_id and d.partner_id=i.partner_id)
  from public.bike_route_prices p join public.company_bid_invitations i on i.request_id=p.request_id
  join public.rider_credentials rc on rc.user_id=i.rider_id and rc.partner_id=i.partner_id
  join public.company_riders r on r.id=rc.roster_id
  join public.partner_application_vehicles v on v.id=r.source_vehicle_id and v.vehicle_type='motorcycle'
  where public.company_staff_allowed(i.partner_id,'bid') and i.starts_at<=clock_timestamp() and i.deadline_at>clock_timestamp();
$$;
revoke all on function public.list_company_bike_prices() from public,anon;
grant execute on function public.list_company_bike_prices() to authenticated;

-- A fixed motorcycle offer can be chosen as soon as a company accepts it;
-- other jobs keep their existing bid deadline.
create or replace function public.list_customer_bid_offers(p_request_id uuid)
returns table(bid_id uuid,partner_name text,partner_phone text,rider_name text,
  rider_phone text,rider_photo_path text,bid_amount_ngn numeric,eta_hours integer)
language sql stable security definer set search_path=pg_catalog,public as $$
  select q.id,p.partner_name,p.phone,cr.full_name,cr.phone,
    case when cr.photo_path ~* '[.](jpg|jpeg|png|webp)$' then cr.photo_path else null end,
    q.amount_ngn,q.eta_hours
  from public.service_requests r
  join public.delivery_quote_windows w on w.request_id=r.id
    and (now()>=w.deadline_at or exists(select 1 from public.bike_route_prices bp where bp.request_id=r.id))
    and w.status in ('open','awaiting_customer_selection','quoted')
  join public.partner_quotes q on q.request_id=r.id and q.status in ('valid','selected')
    and q.submitted_at<w.deadline_at
  join public.logistics_partners p on p.id=q.partner_id and p.status='active'
  left join public.company_bid_invitations i on i.request_id=r.id and i.partner_id=q.partner_id
  left join public.rider_credentials rc on rc.user_id=i.rider_id and rc.partner_id=q.partner_id
    and rc.revoked_at is null and rc.password_revoked_at is null
  left join public.company_riders cr on cr.id=rc.roster_id and cr.status='approved'
  where r.id=p_request_id and public.is_customer_user(r.customer_id)
    and (now()>=w.deadline_at or q.amount_ngn=(select bp.customer_price_ngn from public.bike_route_prices bp where bp.request_id=r.id))
  order by q.amount_ngn,q.submitted_at,q.id;
$$;

create or replace function public.select_customer_partner_bid(p_request_id uuid,p_bid_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_window public.delivery_quote_windows%rowtype;v_bid public.partner_quotes%rowtype;v_service_code text;
begin
  select * into v_window from public.delivery_quote_windows where request_id=p_request_id for update;
  if not found or v_window.status not in ('open','awaiting_customer_selection') then
    raise object_not_in_prerequisite_state using message='Company selection is not available yet'; end if;
  if not exists(select 1 from public.service_requests r where r.id=p_request_id and public.is_customer_user(r.customer_id)) then
    raise insufficient_privilege using message='Only this customer can choose a company'; end if;
  select q.* into v_bid from public.partner_quotes q join public.logistics_partners p on p.id=q.partner_id and p.status='active'
  where q.id=p_bid_id and q.request_id=p_request_id and q.status='valid' and q.submitted_at<v_window.deadline_at for update of q;
  if not found then raise check_violation using message='Choose an available company offer'; end if;
  if now()<v_window.deadline_at and not exists(select 1 from public.bike_route_prices bp
    join public.company_bid_invitations i on i.request_id=bp.request_id and i.partner_id=v_bid.partner_id
    join public.rider_credentials rc on rc.user_id=i.rider_id and rc.partner_id=i.partner_id
    join public.company_riders r on r.id=rc.roster_id
    join public.partner_application_vehicles v on v.id=r.source_vehicle_id and v.vehicle_type='motorcycle'
    where bp.request_id=p_request_id and bp.customer_price_ngn=v_bid.amount_ngn) then
    raise object_not_in_prerequisite_state using message='Company selection is not available yet'; end if;
  if exists(select 1 from public.customer_delivery_quotes where request_id=p_request_id) then
    raise object_not_in_prerequisite_state using message='A company has already been chosen'; end if;
  select s.code into v_service_code from public.service_requests r join public.services s on s.id=r.service_id where r.id=p_request_id;
  if v_service_code='SRV-0001' then
    if v_bid.amount_ngn<>trunc(v_bid.amount_ngn) then
      raise check_violation using message='This price must be a whole-naira amount'; end if;
    if not exists(select 1 from public.company_bid_invitations i where i.request_id=p_request_id and i.partner_id=v_bid.partner_id) then
      raise check_violation using message='This company no longer has a rider for this pickup'; end if;
  end if;
  update public.partner_quotes set status='selected' where id=v_bid.id;
  update public.delivery_quote_windows set status='quoted',closed_at=now() where request_id=p_request_id;
  if v_service_code='SRV-0001' then
    insert into public.customer_delivery_quotes(request_id,winning_bid_id,total_direct_cost_ngn,unrounded_price_ngn,
      customer_price_ngn,formula_version,status,expires_at,accepted_at)
    values(p_request_id,v_bid.id,round(v_bid.amount_ngn*0.75,2),v_bid.amount_ngn,
      v_bid.amount_ngn,'selected-bid-partner-net-75-v2','accepted',now()+interval '2 minutes',now());
    insert into public.customer_payment_holds(request_id,bid_id,reference,amount_ngn,expires_at)
    values(p_request_id,v_bid.id,'KP-'||replace(gen_random_uuid()::text,'-',''),v_bid.amount_ngn,now()+interval '2 minutes');
  else
    insert into public.customer_delivery_quotes(request_id,winning_bid_id,total_direct_cost_ngn,unrounded_price_ngn)
    values(p_request_id,v_bid.id,v_bid.amount_ngn,round(v_bid.amount_ngn/0.75,4));
  end if;
end $$;
