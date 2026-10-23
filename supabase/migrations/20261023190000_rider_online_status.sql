-- The rider screen must use the same freshness rule as dispatch matching.
create function public.my_rider_online() returns boolean
language sql stable security definer set search_path=pg_catalog,public as $$
  select exists (
    select 1 from public.rider_presence rp
    join public.rider_credentials rc on rc.user_id=rp.user_id and rc.partner_id=rp.partner_id
    join public.company_riders cr on cr.id=rc.roster_id and cr.status='approved'
    join public.partner_users pu on pu.user_id=rp.user_id and pu.partner_id=rp.partner_id and pu.membership_role='rider'
    join public.logistics_partners lp on lp.id=rp.partner_id and lp.status='active'
    where rp.user_id=auth.uid() and rc.revoked_at is null and rc.password_revoked_at is null
      and rp.received_at>now()-interval '2 minutes'
      and rp.captured_at>now()-interval '2 minutes'
      and rp.accuracy_metres<=100
  );
$$;
revoke all on function public.my_rider_online() from public,anon;
grant execute on function public.my_rider_online() to authenticated;
