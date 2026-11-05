-- Customer-contributed coordinates and independently typed place names only.
-- Never populate this index from Google/Geoapify search or reverse-geocode output.
create extension if not exists postgis with schema extensions;
create extension if not exists pg_trgm with schema extensions;

create table public.shared_delivery_places (
  id uuid primary key default gen_random_uuid(),
  label text not null check (length(btrim(label)) between 3 and 160),
  normalized_label text not null,
  city text not null check (length(btrim(city)) between 2 and 100),
  normalized_city text not null,
  state text not null check (length(btrim(state)) between 2 and 100),
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  position extensions.geography(Point,4326) not null,
  created_at timestamptz not null default now()
);
create index shared_delivery_places_position_idx on public.shared_delivery_places using gist(position);
create index shared_delivery_places_city_idx on public.shared_delivery_places(normalized_city);
create index shared_delivery_places_label_idx on public.shared_delivery_places using gin(normalized_label extensions.gin_trgm_ops);
alter table public.shared_delivery_places enable row level security;
revoke all on public.shared_delivery_places from public, anon, authenticated;

-- Separate provenance lets a customer remove or change their saved address
-- without deleting a place that another customer independently contributed.
create table public.shared_delivery_place_sources (
  id uuid primary key default gen_random_uuid(),
  place_id uuid not null references public.shared_delivery_places(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  source_kind text not null check (source_kind in ('saved','request_pickup','request_dropoff')),
  source_key text not null check (length(source_key) between 1 and 80),
  created_at timestamptz not null default now(),
  unique(user_id,source_kind,source_key)
);
create index shared_delivery_place_sources_place_idx on public.shared_delivery_place_sources(place_id);
alter table public.shared_delivery_place_sources enable row level security;
revoke all on public.shared_delivery_place_sources from public, anon, authenticated;

-- At most 20 new distinct places per customer in a rolling 24-hour window.
-- A single row per customer avoids a growing request/event log.
create table public.shared_delivery_place_publish_limits (
  user_id uuid primary key references auth.users(id) on delete cascade,
  window_started_at timestamptz not null default now(),
  created_count smallint not null default 0 check (created_count between 0 and 20)
);
alter table public.shared_delivery_place_publish_limits enable row level security;
revoke all on public.shared_delivery_place_publish_limits from public,anon,authenticated;

create function public.cleanup_shared_delivery_place() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  delete from public.shared_delivery_places p where p.id=old.place_id
    and not exists(select 1 from public.shared_delivery_place_sources s where s.place_id=p.id);
  return old;
end;
$$;
create trigger shared_delivery_source_cleanup after delete on public.shared_delivery_place_sources
for each row execute function public.cleanup_shared_delivery_place();
revoke all on function public.cleanup_shared_delivery_place() from public,anon,authenticated;

create function public.upsert_shared_delivery_place(
  p_user_id uuid, p_source_kind text, p_source_key text,
  p_label text, p_city text, p_state text,
  p_latitude double precision, p_longitude double precision
) returns uuid language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
declare v_label text:=btrim(regexp_replace(coalesce(p_label,''),'\s+',' ','g'));
        v_city text:=btrim(regexp_replace(coalesce(p_city,''),'\s+',' ','g'));
        v_state text:=btrim(regexp_replace(coalesce(p_state,''),'\s+',' ','g'));
        v_norm_label text; v_norm_city text; v_point extensions.geography(Point,4326);
        v_place uuid; v_old uuid; v_window timestamptz; v_count smallint;
begin
  if p_user_id is null or p_source_kind is null
     or p_source_kind not in ('saved','request_pickup','request_dropoff')
     or length(coalesce(p_source_key,'')) not between 1 and 80
     or length(v_label) not between 3 and 160 or length(v_city) not between 2 and 100
     or length(v_state) not between 2 and 100
     or position('@' in v_label)>0
     or length(regexp_replace(v_label,'[^0-9]','','g'))>=10
     or p_latitude is null or p_longitude is null
     or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    raise invalid_parameter_value using message='Invalid shared delivery place';
  end if;
  v_norm_label:=lower(v_label); v_norm_city:=lower(v_city);
  v_point:=extensions.st_setsrid(extensions.st_makepoint(p_longitude,p_latitude),4326)::extensions.geography;

  perform pg_advisory_xact_lock(hashtextextended('shared-place-user|'||p_user_id::text,0));
  -- Serialize contributors to the same named place. A canonical place is
  -- reused only when both name/city match and coordinates are within 15 m.
  perform pg_advisory_xact_lock(hashtextextended(v_norm_city||'|'||v_norm_label,0));
  select id into v_place from public.shared_delivery_places
  where normalized_label=v_norm_label and normalized_city=v_norm_city
    and extensions.st_dwithin(position,v_point,15)
  order by extensions.st_distance(position,v_point),id limit 1;
  if v_place is null then
    select window_started_at,created_count into v_window,v_count
    from public.shared_delivery_place_publish_limits where user_id=p_user_id for update;
    if v_window is null then
      insert into public.shared_delivery_place_publish_limits(user_id,created_count) values(p_user_id,1);
    elsif v_window<clock_timestamp()-interval '24 hours' then
      update public.shared_delivery_place_publish_limits
      set window_started_at=clock_timestamp(),created_count=1 where user_id=p_user_id;
    elsif v_count>=20 then
      raise program_limit_exceeded using message='Daily shared-place limit reached';
    else
      update public.shared_delivery_place_publish_limits
      set created_count=created_count+1 where user_id=p_user_id;
    end if;
    insert into public.shared_delivery_places
      (label,normalized_label,city,normalized_city,state,latitude,longitude,position)
    values(v_label,v_norm_label,v_city,v_norm_city,v_state,p_latitude,p_longitude,v_point)
    returning id into v_place;
  end if;
  select place_id into v_old from public.shared_delivery_place_sources
    where user_id=p_user_id and source_kind=p_source_kind and source_key=p_source_key for update;
  insert into public.shared_delivery_place_sources(place_id,user_id,source_kind,source_key)
  values(v_place,p_user_id,p_source_kind,p_source_key)
  on conflict(user_id,source_kind,source_key) do update set place_id=excluded.place_id;
  if v_old is not null and v_old<>v_place then
    delete from public.shared_delivery_places p where p.id=v_old
      and not exists(select 1 from public.shared_delivery_place_sources s where s.place_id=p.id);
  end if;
  return v_place;
end;
$$;
revoke all on function public.upsert_shared_delivery_place(uuid,text,text,text,text,text,double precision,double precision)
  from public,anon,authenticated;

-- A saved Home/Work/Other point is shared automatically only when its name
-- was independently entered by the customer and its coordinates came from
-- device GPS or an explicitly moved pin. Existing records are not backfilled.
alter table public.customer_parcel_destinations
  add column shared_label text,
  add column pin_moved_by_user boolean not null default false;

-- The customer-entered search text is kept separately from any provider's
-- formatted address. Existing requests are deliberately not backfilled.
alter table public.service_requests
  add column shared_pickup_label text,
  add column shared_delivery_label text,
  add column pickup_pin_moved_by_user boolean not null default false,
  add column delivery_pin_moved_by_user boolean not null default false;

create function public.sync_saved_shared_delivery_place() returns trigger
language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
declare v_owner uuid; v_slot smallint;
begin
  v_owner:=case when tg_op='DELETE' then old.user_id else new.user_id end;
  v_slot:=case when tg_op='DELETE' then old.slot else new.slot end;
  if tg_op='DELETE' then
    delete from public.shared_delivery_place_sources
    where user_id=v_owner and source_kind='saved' and source_key=v_slot::text;
    return old;
  end if;
  if tg_op='UPDATE' and (old.user_id<>new.user_id or old.slot<>new.slot) then
    delete from public.shared_delivery_place_sources
    where user_id=old.user_id and source_kind='saved' and source_key=old.slot::text;
  end if;
  if not public.is_customer_parcel_pal_user(new.user_id)
      or new.shared_label is null or new.latitude is null or new.longitude is null
      or not (new.location_source in ('browser','native')
        or (new.location_source='map' and new.pin_moved_by_user)) then
    delete from public.shared_delivery_place_sources
    where user_id=v_owner and source_kind='saved' and source_key=v_slot::text;
  else
    begin
      perform public.upsert_shared_delivery_place(new.user_id,'saved',new.slot::text,
        new.shared_label,new.city,new.state,new.latitude,new.longitude);
    exception when others then
      -- Keep the private saved address usable. An outdated shared point must
      -- disappear if the replacement could not be indexed.
      delete from public.shared_delivery_place_sources
      where user_id=v_owner and source_kind='saved' and source_key=v_slot::text;
      raise warning 'Saved shared place sync skipped (SQLSTATE %)', sqlstate;
    end;
  end if;
  return new;
end;
$$;
create trigger customer_saved_place_share after insert or update or delete
on public.customer_parcel_destinations for each row execute function public.sync_saved_shared_delivery_place();
revoke all on function public.sync_saved_shared_delivery_place() from public,anon,authenticated;

create function public.share_completed_delivery_places() returns trigger
language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
declare v_request public.service_requests%rowtype;
begin
  if new.status not in ('delivered','closed') then return new; end if;
  if tg_op='UPDATE' then
    if old.status=new.status then return new; end if;
  end if;
  select r.* into v_request from public.orders o
    join public.service_requests r on r.id=o.service_request_id
    where o.id=new.order_id;
  if not found or not public.is_customer_parcel_pal_user(v_request.created_by) then return new; end if;
  if not (exists(select 1 from public.customer_payment_holds h
                 where h.request_id=v_request.id and h.status='paid')
          or exists(select 1 from public.customer_payments cp
                    where cp.job_id=new.id and cp.status='received')) then
    return new;
  end if;
  -- Cache/index maintenance must never prevent a parcel being marked delivered.
  begin
    if v_request.shared_pickup_label is not null and v_request.pickup_latitude is not null
       and v_request.pickup_longitude is not null and v_request.pickup_state is not null
       and (v_request.pickup_location_source in ('browser','native')
            or (v_request.pickup_location_source='map' and v_request.pickup_pin_moved_by_user)) then
      perform public.upsert_shared_delivery_place(v_request.created_by,'request_pickup',v_request.id::text,
        v_request.shared_pickup_label,v_request.pickup_city,v_request.pickup_state,
        v_request.pickup_latitude,v_request.pickup_longitude);
    end if;
    if v_request.shared_delivery_label is not null and v_request.delivery_latitude is not null
       and v_request.delivery_longitude is not null and v_request.delivery_state is not null
       and (v_request.delivery_location_source in ('browser','native')
            or (v_request.delivery_location_source='map' and v_request.delivery_pin_moved_by_user)) then
      perform public.upsert_shared_delivery_place(v_request.created_by,'request_dropoff',v_request.id::text,
        v_request.shared_delivery_label,v_request.delivery_city,v_request.delivery_state,
        v_request.delivery_latitude,v_request.delivery_longitude);
    end if;
  exception when others then
    raise warning 'Shared delivery place sync skipped (SQLSTATE %)', sqlstate;
  end;
  return new;
end;
$$;
create trigger share_completed_delivery_places after insert or update of status on public.jobs
for each row execute function public.share_completed_delivery_places();
revoke all on function public.share_completed_delivery_places() from public,anon,authenticated;

-- Keep one small row per customer, rather than a growing search event log.
-- Precise coordinates and search text are never written to this limiter.
create table public.shared_delivery_place_search_limits (
  user_id uuid primary key references auth.users(id) on delete cascade,
  hour_started_at timestamptz not null default now(),
  hour_count smallint not null default 0 check (hour_count between 0 and 120),
  burst_started_at timestamptz not null default now(),
  burst_count smallint not null default 0 check (burst_count between 0 and 30)
);
alter table public.shared_delivery_place_search_limits enable row level security;
revoke all on public.shared_delivery_place_search_limits from public,anon,authenticated;

create function public.search_shared_delivery_places(
  p_query text, p_city text,
  p_latitude double precision default null, p_longitude double precision default null,
  p_limit integer default 8
) returns table(id uuid,label text,city text,state text,
  latitude double precision,longitude double precision,distance_metres double precision)
language plpgsql volatile security definer set search_path=pg_catalog,public,auth,extensions as $$
declare v_query text:=lower(btrim(regexp_replace(coalesce(p_query,''),'\s+',' ','g')));
        v_city text:=lower(btrim(regexp_replace(coalesce(p_city,''),'\s+',' ','g')));
        v_point extensions.geography(Point,4326); v_user uuid:=auth.uid();
        v_now timestamptz:=clock_timestamp(); v_count integer;
begin
  if v_user is null or not public.is_customer_parcel_pal_user(v_user) then
    raise insufficient_privilege using message='Customer sign-in required';
  end if;
  if length(v_query)>160 or (v_query<>'' and length(v_query)<3)
     or position('%' in v_query)>0 or position('_' in v_query)>0
     or position(chr(92) in v_query)>0
     or length(v_city) not between 2 and 100
     or p_limit is null or p_limit not between 1 and 10
     or ((p_latitude is null)<>(p_longitude is null))
     or (v_query='' and (p_latitude is null or p_longitude is null)) then
    raise invalid_parameter_value using message='Enter a city and at least three search letters or a location';
  end if;
  if p_latitude is not null then
    if p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
      raise invalid_parameter_value using message='Invalid coordinates';
    end if;
    v_point:=extensions.st_setsrid(extensions.st_makepoint(p_longitude,p_latitude),4326)::extensions.geography;
  end if;
  -- Atomic per-user counters bound normal searches to 30 per five minutes and
  -- 120 per hour, with windows anchored at each customer's first request.
  insert into public.shared_delivery_place_search_limits as lim
    (user_id,hour_started_at,hour_count,burst_started_at,burst_count)
  values(v_user,v_now,1,v_now,1)
  on conflict(user_id) do update set
    hour_started_at=case when lim.hour_started_at<=v_now-interval '1 hour'
      then v_now else lim.hour_started_at end,
    hour_count=case when lim.hour_started_at<=v_now-interval '1 hour'
      then 1 else lim.hour_count+1 end,
    burst_started_at=case when lim.burst_started_at<=v_now-interval '5 minutes'
      then v_now else lim.burst_started_at end,
    burst_count=case when lim.burst_started_at<=v_now-interval '5 minutes'
      then 1 else lim.burst_count+1 end
  where (lim.hour_started_at<=v_now-interval '1 hour' or lim.hour_count<120)
    and (lim.burst_started_at<=v_now-interval '5 minutes' or lim.burst_count<30)
  returning hour_count into v_count;
  if v_count is null then
    raise program_limit_exceeded using message='Too many saved-place searches; try again later';
  end if;
  if v_query='' then
    return query
    select p.id,p.label,p.city,p.state,p.latitude,p.longitude,
      extensions.st_distance(p.position,v_point) as distance_metres
    from public.shared_delivery_places p
    where p.normalized_city=v_city and extensions.st_dwithin(p.position,v_point,15)
    order by extensions.st_distance(p.position,v_point),p.label,p.id
    limit p_limit;
  else
    return query
    select p.id,p.label,p.city,p.state,p.latitude,p.longitude,
      case when v_point is null then null::double precision
        else extensions.st_distance(p.position,v_point) end as distance_metres
    from public.shared_delivery_places p
    where p.normalized_city=v_city and p.normalized_label like '%'||v_query||'%'
    order by case when v_point is null then 0 else extensions.st_distance(p.position,v_point) end,
      p.label,p.id
    limit p_limit;
  end if;
end;
$$;
revoke all on function public.search_shared_delivery_places(text,text,double precision,double precision,integer)
  from public,anon;
grant execute on function public.search_shared_delivery_places(text,text,double precision,double precision,integer)
  to authenticated;
