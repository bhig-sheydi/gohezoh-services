-- One short lease per delivery request prevents concurrent Edge Function instances
-- from paying for the same Google road-price lookup. The completed price remains
-- stored in bike_route_prices for this request only.
create table public.bike_route_price_leases (
  request_id uuid primary key,
  claim_token uuid not null,
  leased_until timestamptz not null,
  pickup_latitude double precision not null,
  pickup_longitude double precision not null,
  delivery_latitude double precision not null,
  delivery_longitude double precision not null,
  created_at timestamptz not null default now()
);

create index bike_route_price_leases_expiry_idx
  on public.bike_route_price_leases(leased_until);
alter table public.bike_route_price_leases enable row level security;
revoke all on public.bike_route_price_leases from public, anon, authenticated, service_role;

create function public.claim_bike_route_price_calculation(
  p_request_id uuid,p_pickup_latitude double precision,p_pickup_longitude double precision,
  p_delivery_latitude double precision,p_delivery_longitude double precision)
returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_token uuid := gen_random_uuid();
        v_claimed uuid;
begin
  if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
  if p_request_id is null or p_pickup_latitude is null or p_pickup_longitude is null
    or p_delivery_latitude is null or p_delivery_longitude is null then
    raise check_violation using message='Request and coordinates required'; end if;
  if exists(select 1 from public.bike_route_prices where request_id=p_request_id) then return null; end if;

  insert into public.bike_route_price_leases(request_id,claim_token,leased_until,
    pickup_latitude,pickup_longitude,delivery_latitude,delivery_longitude)
    values(p_request_id,v_token,clock_timestamp()+interval '25 seconds',
      p_pickup_latitude,p_pickup_longitude,p_delivery_latitude,p_delivery_longitude)
    on conflict(request_id) do update
      set claim_token=excluded.claim_token,leased_until=clock_timestamp()+interval '25 seconds',
        pickup_latitude=excluded.pickup_latitude,pickup_longitude=excluded.pickup_longitude,
        delivery_latitude=excluded.delivery_latitude,delivery_longitude=excluded.delivery_longitude
      where public.bike_route_price_leases.leased_until<=clock_timestamp()
    returning claim_token into v_claimed;
  if v_claimed is null then return null; end if;

  -- A first worker may have committed its price and released its lease while
  -- this transaction waited on the unique request_id. Recheck after claiming.
  if exists(select 1 from public.bike_route_prices where request_id=p_request_id) then
    delete from public.bike_route_price_leases
      where request_id=p_request_id and claim_token=v_claimed;
    return null;
  end if;
  return v_claimed;
end $$;
revoke all on function public.claim_bike_route_price_calculation(
  uuid,double precision,double precision,double precision,double precision)
  from public,anon,authenticated;
grant execute on function public.claim_bike_route_price_calculation(
  uuid,double precision,double precision,double precision,double precision) to service_role;

create function public.complete_bike_route_price_calculation(
  p_request_id uuid,p_claim_token uuid,p_distance_metres integer,p_duration_seconds integer)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
  perform 1 from public.bike_route_price_leases lease
    join public.service_requests request on request.id=lease.request_id
    where lease.request_id=p_request_id and lease.claim_token=p_claim_token
      and lease.leased_until>clock_timestamp()
      and request.pickup_latitude=lease.pickup_latitude
      and request.pickup_longitude=lease.pickup_longitude
      and request.delivery_latitude=lease.delivery_latitude
      and request.delivery_longitude=lease.delivery_longitude
    for update of lease,request;
  if not found then raise check_violation using message='Road-price claim expired or delivery location changed'; end if;

  perform public.record_bike_route_price(p_request_id,p_distance_metres,p_duration_seconds);
  delete from public.bike_route_price_leases
    where request_id=p_request_id and claim_token=p_claim_token;
end $$;
revoke all on function public.complete_bike_route_price_calculation(uuid,uuid,integer,integer)
  from public,anon,authenticated;
grant execute on function public.complete_bike_route_price_calculation(uuid,uuid,integer,integer)
  to service_role;

create function public.release_bike_route_price_calculation(p_request_id uuid,p_claim_token uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
  delete from public.bike_route_price_leases
    where request_id=p_request_id and claim_token=p_claim_token;
end $$;
revoke all on function public.release_bike_route_price_calculation(uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.release_bike_route_price_calculation(uuid,uuid) to service_role;

-- An Edge Function can be terminated before its finally block releases a lease.
-- Expired claims can be reclaimed immediately; prune abandoned rows hourly.
select cron.schedule('kwik-parsel-bike-price-lease-cleanup','0 * * * *',
  'delete from public.bike_route_price_leases where leased_until < now() - interval ''1 hour''');
