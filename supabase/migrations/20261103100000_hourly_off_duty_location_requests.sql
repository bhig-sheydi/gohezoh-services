-- Hourly phone checks need a request to remain pending through the next check
-- and a short GPS/network acquisition window.
alter table public.rider_location_requests
  alter column expires_at set default clock_timestamp()+interval '70 minutes';
update public.rider_location_requests
  set expires_at=requested_at+interval '70 minutes'
  where expires_at>clock_timestamp() and expires_at<requested_at+interval '70 minutes';

create or replace function public.queue_rider_location_request(p_rider_id uuid)
returns uuid language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
declare v_id uuid;
begin
  if p_rider_id is null then raise check_violation using message='Rider required'; end if;
  insert into public.rider_location_requests(rider_id) values(p_rider_id)
  on conflict(rider_id) do update set request_id=case
      when rider_location_requests.expires_at<clock_timestamp() then extensions.gen_random_uuid()
      else rider_location_requests.request_id end,
    requested_at=case when rider_location_requests.expires_at<clock_timestamp() then clock_timestamp()
      else rider_location_requests.requested_at end,
    expires_at=case when rider_location_requests.expires_at<clock_timestamp() then clock_timestamp()+interval '70 minutes'
      else rider_location_requests.expires_at end
  returning request_id into v_id;
  return v_id;
end $$;
