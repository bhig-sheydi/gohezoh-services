-- A matched independent rider owns the decision; company staff cannot submit
-- a competing response for that rider's invitation.
create function public.guard_independent_offer_owner() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if exists (
    select 1 from public.company_bid_invitations i
    join public.company_riders cr on cr.independent_user_id=i.rider_id and cr.partner_id=i.partner_id
    where i.request_id=new.request_id and i.partner_id=new.partner_id
      and cr.status='approved' and i.rider_id is distinct from auth.uid()
  ) and auth.role()<>'service_role' then
    raise insufficient_privilege using message='This delivery offer belongs to the matched independent rider';
  end if;
  return new;
end $$;
create trigger partner_quote_independent_owner before insert on public.partner_quotes
  for each row execute function public.guard_independent_offer_owner();
revoke all on function public.guard_independent_offer_owner() from public,anon,authenticated;
