-- Extend an active, authorized phone-tracking grant only when it is close to
-- expiry. Revoked credentials and stopped sharing remain revoked.
create function public.renew_active_rider_tracking_grant()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  update public.rider_tracking_grants g
     set expires_at=clock_timestamp()+interval '7 days'
   where g.user_id=new.user_id and g.revoked_at is null
     and g.expires_at>clock_timestamp()
     and g.expires_at<clock_timestamp()+interval '3 days'
     and exists(select 1 from public.rider_credentials c
       where c.user_id=g.user_id and c.revoked_at is null and c.password_revoked_at is null);
  return new;
end $$;
revoke all on function public.renew_active_rider_tracking_grant() from public,anon,authenticated;
create trigger renew_active_rider_tracking_grant
after insert or update of captured_at on public.rider_location_latest
for each row execute function public.renew_active_rider_tracking_grant();
