-- Keep only the current and immediately preceding GPS fix for speed estimation.
alter table public.rider_presence
  add column previous_position extensions.geography(Point,4326),
  add column previous_accuracy_metres double precision,
  add column previous_captured_at timestamptz;

create or replace function public.report_rider_position(p_latitude double precision,p_longitude double precision,
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
  perform 1 from public.rider_credentials where user_id=auth.uid() for update;
  select * into v_previous from public.rider_presence where user_id=auth.uid();
  if found and (v_previous.received_at>clock_timestamp()-interval '15 seconds' or v_previous.captured_at>=p_captured_at) then return false; end if;
  insert into public.rider_presence(user_id,partner_id,position,accuracy_metres,captured_at,
    previous_position,previous_accuracy_metres,previous_captured_at)
  values(auth.uid(),v_partner,extensions.st_setsrid(extensions.st_makepoint(p_longitude,p_latitude),4326)::extensions.geography,
    p_accuracy_metres,p_captured_at,
    case when v_previous.captured_at>clock_timestamp()-interval '3 minutes' and v_previous.partner_id=v_partner then v_previous.position end,
    case when v_previous.captured_at>clock_timestamp()-interval '3 minutes' and v_previous.partner_id=v_partner then v_previous.accuracy_metres end,
    case when v_previous.captured_at>clock_timestamp()-interval '3 minutes' and v_previous.partner_id=v_partner then v_previous.captured_at end)
  on conflict(user_id) do update set partner_id=excluded.partner_id,position=excluded.position,
    accuracy_metres=excluded.accuracy_metres,captured_at=excluded.captured_at,received_at=clock_timestamp(),
    previous_position=excluded.previous_position,previous_accuracy_metres=excluded.previous_accuracy_metres,
    previous_captured_at=excluded.previous_captured_at;
  return true;
end $$;

-- Coordinates are disclosed only for a paid, active job to its own customer.
-- No location trail is retained or exposed. A stale fix produces no coordinates.
create function public.get_my_delivery_tracking(p_job_id uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,extensions as $$
declare v_job public.jobs%rowtype; v_presence public.rider_presence%rowtype;
  v_distance double precision; v_movement double precision; v_seconds double precision;
  v_speed double precision; v_eta integer;
begin
  select j.* into v_job from public.jobs j
    join public.orders o on o.id=j.order_id
    where j.id=p_job_id and public.is_customer_user(j.customer_id)
      and (exists (select 1 from public.customer_payment_holds h where h.request_id=o.service_request_id and h.status='paid')
        or exists (select 1 from public.customer_payments cp where cp.job_id=j.id and cp.status='received'));
  if not found then raise insufficient_privilege using message='Paid delivery access required'; end if;
  if v_job.status in ('delivered','closed','cancelled') then
    return jsonb_build_object('state','completed');
  end if;
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
  -- Straight-line ETA at observed pace is only meaningful while moving.
  if v_distance is not null and v_speed>=5 then
    v_eta := ceil(v_distance/(v_speed*1000)*60)::integer;
  end if;
  return jsonb_build_object('state','live',
    'latitude',extensions.st_y(v_presence.position::extensions.geometry),
    'longitude',extensions.st_x(v_presence.position::extensions.geometry),
    'accuracy_metres',v_presence.accuracy_metres,'captured_at',v_presence.captured_at,
    'distance_metres',round(v_distance::numeric),
    'speed_kmh',case when v_speed is null then null else round(v_speed::numeric,1) end,
    'eta_minutes',v_eta);
end $$;
revoke all on function public.get_my_delivery_tracking(uuid) from public,anon;
grant execute on function public.get_my_delivery_tracking(uuid) to authenticated;
