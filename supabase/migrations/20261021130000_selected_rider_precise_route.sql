-- Extend the selected rider's pending task with the saved route labels in the same query.
drop function public.list_my_selected_pickups();
create function public.list_my_selected_pickups()
returns table(request_id uuid,request_number text,pickup_city text,delivery_city text,
  parcel_summary text,company_name text,selected_at timestamptz,pickup_address text,delivery_address text)
language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not public.rider_session_active() then raise insufficient_privilege using message='Rider access required'; end if;
  return query select r.id,r.request_number,r.pickup_city,r.delivery_city,r.parcel_summary,p.partner_name,cq.created_at,
    r.pickup_address,r.delivery_address
  from public.customer_delivery_quotes cq
  join public.partner_quotes q on q.id=cq.winning_bid_id and q.request_id=cq.request_id and q.status='selected'
  join public.company_bid_invitations i on i.request_id=cq.request_id and i.partner_id=q.partner_id and i.rider_id=auth.uid()
  join public.service_requests r on r.id=cq.request_id
  join public.services s on s.id=r.service_id
  join public.logistics_partners p on p.id=q.partner_id and p.status='active'
  join public.rider_credentials rc on rc.user_id=i.rider_id and rc.partner_id=q.partner_id
    and rc.revoked_at is null and rc.password_revoked_at is null
  join public.company_riders cr on cr.id=rc.roster_id and cr.status='approved'
  left join public.customer_payment_holds h on h.request_id=r.id
  where r.status not in ('rejected','cancelled') and (
    (s.code='SRV-0001' and h.status in ('initializing','pending') and now()<h.expires_at and cq.status='accepted')
    or (s.code<>'SRV-0001' and cq.status in ('pending_price','sent','accepted'))
  ) and not exists (
    select 1 from public.jobs j join public.orders o on o.id=j.order_id
    join public.partner_assignments pa on pa.job_id=j.id and pa.status in ('accepted','completed')
    where o.service_request_id=r.id
  )
  order by cq.created_at desc limit 50;
end $$;
revoke all on function public.list_my_selected_pickups() from public,anon;
grant execute on function public.list_my_selected_pickups() to authenticated;
