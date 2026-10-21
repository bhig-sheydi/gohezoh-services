-- Return the saved street/community labels only to companies with an active bid invitation.
create function public.list_partner_bid_route_addresses()
returns table(request_id uuid,pickup_address text,delivery_address text)
language sql stable security definer set search_path=pg_catalog,public as $$
  select distinct r.id,r.pickup_address,r.delivery_address
  from public.delivery_quote_windows w
  join public.service_requests r on r.id=w.request_id
  join lateral (
    select i.partner_id from public.company_bid_invitations i
      where i.request_id=r.id and r.pickup_location_source is not null
    union
    select pc.partner_id from public.partner_corridor_coverage pc
      where pc.corridor_id=w.corridor_id and pc.is_enabled and pc.capacity_available
        and r.pickup_location_source is null
  ) pc on true
  join public.logistics_partners p on p.id=pc.partner_id and p.status='active'
  where public.is_partner_user(pc.partner_id) and public.company_can_bid_nearby(r.id,pc.partner_id)
    and w.status='open' and now()<w.deadline_at;
$$;
revoke all on function public.list_partner_bid_route_addresses() from public,anon;
grant execute on function public.list_partner_bid_route_addresses() to authenticated;
