-- Old Android releases posted off-duty positions continuously. Reject that
-- endpoint so the cost reduction applies server-side as well as in v1.0.5.
create or replace function public.report_native_off_duty_position(p_token text,p_latitude double precision,
  p_longitude double precision,p_accuracy_metres double precision,p_captured_at timestamptz)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  raise insufficient_privilege using message='Update the Kwik-Parsel Android app to request-based location';
end $$;

create or replace function public.report_native_requested_position(p_token text,p_request_id uuid,
  p_latitude double precision,p_longitude double precision,p_accuracy_metres double precision,p_captured_at timestamptz)
returns boolean language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
declare v_rider uuid;v_partner uuid;
begin
  select rider_id,partner_id into v_rider,v_partner from public.native_rider_token_identity(p_token);
  if v_rider is null then raise insufficient_privilege using message='Phone tracking access ended'; end if;
  perform 1 from public.rider_location_requests where rider_id=v_rider and request_id=p_request_id
    and expires_at>clock_timestamp() for update;
  if not found then raise check_violation using message='Location request expired'; end if;
  if p_latitude is null or p_latitude not between -90 and 90 or p_longitude is null or p_longitude not between -180 and 180
    or p_accuracy_metres is null or p_accuracy_metres not between 0 and 100
    or p_captured_at is null or p_captured_at<clock_timestamp()-interval '60 seconds'
    or p_captured_at>clock_timestamp()+interval '5 seconds' then
    raise check_violation using message='A fresh GPS reading accurate to 100 metres or better is required'; end if;
  perform 1 from public.rider_credentials where user_id=v_rider for update;
  delete from public.rider_presence where user_id=v_rider;
  perform public.save_rider_location_latest(v_rider,v_partner,
    extensions.st_setsrid(extensions.st_makepoint(p_longitude,p_latitude),4326)::extensions.geography,
    p_accuracy_metres,p_captured_at,false);
  delete from public.rider_location_requests where rider_id=v_rider and request_id=p_request_id;
  return true;
end $$;
