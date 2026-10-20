-- Keep at most two timestamps per customer; never store a rider location trail.
create table public.customer_rider_location_checks (
  user_id uuid primary key references auth.users(id) on delete cascade,
  checked_at timestamptz[] not null default '{}'
);
alter table public.customer_rider_location_checks enable row level security;
revoke all on public.customer_rider_location_checks from public,anon,authenticated;

-- Ordinary tracking remains available, but it no longer discloses coordinates.
create or replace function public.get_my_delivery_tracking(p_job_id uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,extensions as $$
declare v_job public.jobs%rowtype; v_presence public.rider_presence%rowtype;
  v_distance double precision; v_movement double precision; v_seconds double precision;
  v_speed double precision; v_eta integer; v_remaining integer;
begin
  select j.* into v_job from public.jobs j
    join public.orders o on o.id=j.order_id
    where j.id=p_job_id and public.is_customer_user(j.customer_id)
      and (exists (select 1 from public.customer_payment_holds h where h.request_id=o.service_request_id and h.status='paid')
        or exists (select 1 from public.customer_payments cp where cp.job_id=j.id and cp.status='received'));
  if not found then raise insufficient_privilege using message='Paid delivery access required'; end if;
  if v_job.status in ('delivered','closed','cancelled') then return jsonb_build_object('state','completed'); end if;
  if v_job.assigned_rider_id is null then return jsonb_build_object('state','awaiting_rider'); end if;
  select * into v_presence from public.rider_presence rp
    where rp.user_id=v_job.assigned_rider_id and rp.partner_id=v_job.partner_id
      and rp.captured_at>clock_timestamp()-interval '2 minutes'
      and rp.received_at>clock_timestamp()-interval '2 minutes';
  if not found then return jsonb_build_object('state','offline'); end if;
  if v_job.delivery_latitude is not null and v_job.delivery_longitude is not null then
    v_distance := extensions.st_distance(v_presence.position,
      extensions.st_setsrid(extensions.st_makepoint(v_job.delivery_longitude,v_job.delivery_latitude),4326)::extensions.geography);
  end if;
  if v_presence.previous_position is not null then
    v_seconds := extract(epoch from (v_presence.captured_at-v_presence.previous_captured_at));
    v_movement := extensions.st_distance(v_presence.position,v_presence.previous_position);
    if v_seconds between 15 and 180 and v_movement>greatest(20,v_presence.accuracy_metres+v_presence.previous_accuracy_metres) then
      v_speed := v_movement/v_seconds*3.6;
      if v_speed>120 then v_speed := null; end if;
    end if;
  end if;
  if v_distance is not null and v_speed>=5 then v_eta := ceil(v_distance/(v_speed*1000)*60)::integer; end if;
  select greatest(0,2-count(*)::integer) into v_remaining
    from public.customer_rider_location_checks c,
      unnest(c.checked_at) t(checked_at)
    where c.user_id=auth.uid() and t.checked_at>clock_timestamp()-interval '1 hour';
  return jsonb_build_object('state','live',
    'captured_at',v_presence.captured_at,
    'distance_metres',round(v_distance::numeric),
    'speed_kmh',case when v_speed is null then null else round(v_speed::numeric,1) end,
    'eta_minutes',v_eta,'checks_remaining',v_remaining);
end $$;

-- One reveal per click, atomically limited to two in any rolling 60 minutes.
-- A stale/offline rider does not consume an allowance.
create function public.claim_my_rider_location_check(p_job_id uuid)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,public,extensions as $$
declare v_job public.jobs%rowtype; v_presence public.rider_presence%rowtype;
  v_checks public.customer_rider_location_checks%rowtype; v_recent timestamptz[];
  v_now timestamptz:=clock_timestamp();
begin
  if auth.uid() is null then raise insufficient_privilege using message='Sign in required'; end if;
  select j.* into v_job from public.jobs j
    join public.orders o on o.id=j.order_id
    where j.id=p_job_id and public.is_customer_user(j.customer_id)
      and (exists (select 1 from public.customer_payment_holds h where h.request_id=o.service_request_id and h.status='paid')
        or exists (select 1 from public.customer_payments cp where cp.job_id=j.id and cp.status='received'));
  if not found then raise insufficient_privilege using message='Paid delivery access required'; end if;
  if v_job.status in ('delivered','closed','cancelled') then return jsonb_build_object('state','completed'); end if;
  if v_job.assigned_rider_id is null then return jsonb_build_object('state','awaiting_rider'); end if;
  select * into v_presence from public.rider_presence rp
    where rp.user_id=v_job.assigned_rider_id and rp.partner_id=v_job.partner_id
      and rp.captured_at>v_now-interval '2 minutes' and rp.received_at>v_now-interval '2 minutes';
  if not found then return jsonb_build_object('state','offline'); end if;
  insert into public.customer_rider_location_checks(user_id) values(auth.uid()) on conflict do nothing;
  select * into v_checks from public.customer_rider_location_checks where user_id=auth.uid() for update;
  select coalesce(array_agg(t.checked_at order by t.checked_at),'{}'::timestamptz[]) into v_recent
    from unnest(v_checks.checked_at) t(checked_at) where t.checked_at>v_now-interval '1 hour';
  if cardinality(v_recent)>=2 then
    return jsonb_build_object('state','limited','checks_remaining',0,'retry_at',v_recent[1]+interval '1 hour');
  end if;
  update public.customer_rider_location_checks set checked_at=array_append(v_recent,v_now) where user_id=auth.uid();
  return jsonb_build_object('state','live','checks_remaining',1-cardinality(v_recent),
    'latitude',extensions.st_y(v_presence.position::extensions.geometry),
    'longitude',extensions.st_x(v_presence.position::extensions.geometry),
    'accuracy_metres',v_presence.accuracy_metres,'captured_at',v_presence.captured_at);
end $$;
revoke all on function public.claim_my_rider_location_check(uuid) from public,anon;
grant execute on function public.claim_my_rider_location_check(uuid) to authenticated;
