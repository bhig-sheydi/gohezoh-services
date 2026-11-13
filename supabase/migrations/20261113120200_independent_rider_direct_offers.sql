-- Only the rider named in the matched invitation can see or accept its offer.
create function public.my_independent_rider_offers()
returns table(request_id uuid, request_number text, pickup_address text, delivery_address text,
  parcel_summary text, customer_price_ngn integer, company_share_ngn numeric, deadline_at timestamptz)
language sql stable security definer set search_path=pg_catalog,public as $$
  select r.id,r.request_number,r.pickup_address,r.delivery_address,r.parcel_summary,
    bp.customer_price_ngn,bp.company_share_ngn,i.deadline_at
  from public.company_bid_invitations i
  join public.company_riders cr on cr.independent_user_id=auth.uid() and cr.partner_id=i.partner_id
    and cr.status='approved'
  join public.rider_credentials rc on rc.roster_id=cr.id and rc.user_id=auth.uid()
    and rc.revoked_at is null and rc.password_revoked_at is null
  join public.delivery_quote_windows w on w.request_id=i.request_id and w.status='open'
  join public.service_requests r on r.id=i.request_id
  join public.bike_route_prices bp on bp.request_id=i.request_id
  where i.rider_id=auth.uid() and i.starts_at<=clock_timestamp() and i.deadline_at>clock_timestamp()
    and public.rider_session_active() and public.company_can_bid_nearby(i.request_id,i.partner_id)
    and not exists(select 1 from public.partner_quotes q where q.request_id=i.request_id and q.partner_id=i.partner_id
      and q.status in ('valid','selected'))
    and not exists(select 1 from public.declined_bike_offers d where d.request_id=i.request_id and d.partner_id=i.partner_id)
  order by i.deadline_at limit 10;
$$;
revoke all on function public.my_independent_rider_offers() from public,anon;
grant execute on function public.my_independent_rider_offers() to authenticated;

create function public.respond_independent_rider_offer(p_request_id uuid,p_accept boolean)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_partner uuid; v_price public.bike_route_prices%rowtype;
begin
  if not public.rider_session_active() then raise insufficient_privilege using message='Active rider required'; end if;
  select i.partner_id into v_partner from public.company_bid_invitations i
    join public.company_riders cr on cr.independent_user_id=auth.uid() and cr.partner_id=i.partner_id
      and cr.status='approved'
    join public.delivery_quote_windows w on w.request_id=i.request_id and w.status='open'
    join public.logistics_partners lp on lp.id=i.partner_id and lp.status='active'
  where i.request_id=p_request_id and i.rider_id=auth.uid()
    and i.starts_at<=clock_timestamp() and i.deadline_at>clock_timestamp()
    and public.company_can_bid_nearby(i.request_id,i.partner_id)
  for update of i;
  if v_partner is null then raise object_not_in_prerequisite_state using message='This offer is no longer available'; end if;
  if p_accept is null then raise check_violation using message='Choose accept or decline'; end if;
  if not p_accept then
    insert into public.declined_bike_offers(request_id,partner_id,declined_by)
      values(p_request_id,v_partner,auth.uid()) on conflict do nothing;
    return true;
  end if;
  select * into v_price from public.bike_route_prices where request_id=p_request_id;
  if not found then raise object_not_in_prerequisite_state using message='Delivery price is not ready'; end if;
  if exists(select 1 from public.partner_quotes q where q.request_id=p_request_id and q.partner_id=v_partner
    and q.status in ('valid','selected')) then return true; end if;
  perform pg_catalog.set_config('kwikparsel.fixed_bike_accept','on',true);
  insert into public.partner_quotes(request_id,partner_id,amount_ngn,eta_hours,availability_confirmed,
    inclusions,exclusions,surcharge_conditions,version)
  values(p_request_id,v_partner,v_price.customer_price_ngn,
    greatest(1,ceil(v_price.duration_seconds/3600.0)::integer),true,'Pickup and delivery','None','None',
    coalesce((select max(version)+1 from public.partner_quotes where request_id=p_request_id and partner_id=v_partner),1));
  return true;
end $$;
revoke all on function public.respond_independent_rider_offer(uuid,boolean) from public,anon;
grant execute on function public.respond_independent_rider_offer(uuid,boolean) to authenticated;
