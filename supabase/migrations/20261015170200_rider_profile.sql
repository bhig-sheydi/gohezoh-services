create or replace function public.my_rider_profile()
returns table(rider_name text,company_name text)
language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not public.rider_session_active() then raise insufficient_privilege using message='Rider access required'; end if;
  return query select c.rider_name,p.partner_name from public.rider_credentials c
    join public.logistics_partners p on p.id=c.partner_id
    join public.partner_users pu on pu.partner_id=c.partner_id and pu.user_id=c.user_id and pu.membership_role='rider'
    where c.user_id=auth.uid() and c.revoked_at is null;
end $$;
revoke all on function public.my_rider_profile() from public,anon;
grant execute on function public.my_rider_profile() to authenticated;
