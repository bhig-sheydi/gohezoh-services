-- A delayed duty-switch request must not leave a rider eligible for dispatch
-- after a fresh off-duty fix finally arrives.
create or replace function public.report_native_off_duty_position(p_token text,p_latitude double precision,
  p_longitude double precision,p_accuracy_metres double precision,p_captured_at timestamptz)
returns boolean language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
declare v_rider uuid;v_partner uuid;
begin
  select rider_id,partner_id into v_rider,v_partner from public.native_rider_token_identity(p_token);
  if v_rider is null then raise insufficient_privilege using message='Phone tracking access ended'; end if;
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
  return true;
end $$;

create or replace function public.revoke_rider_tracking_token(p_token text) returns void
language plpgsql security definer set search_path=pg_catalog,public,auth,extensions as $$
declare v_rider uuid;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then return; end if;
  update public.rider_tracking_grants set revoked_at=clock_timestamp()
    where token_hash=extensions.digest(p_token,'sha256') and revoked_at is null returning user_id into v_rider;
  if v_rider is not null then
    delete from public.rider_presence where user_id=v_rider;
    update public.rider_location_latest set on_duty=false,received_at=clock_timestamp()-interval '3 minutes' where user_id=v_rider;
  end if;
end $$;
