create or replace function public.can_customer_read_rider_bid_photo(p_path text) returns boolean
language sql stable security definer set search_path=pg_catalog,public as $$
  select exists (
    select 1 from public.company_riders cr
    join public.rider_credentials rc on rc.roster_id=cr.id and rc.partner_id=cr.partner_id
      and rc.revoked_at is null and rc.password_revoked_at is null
    join public.company_bid_invitations i on i.rider_id=rc.user_id and i.partner_id=cr.partner_id
    join public.delivery_quote_windows w on w.request_id=i.request_id
      and w.status in ('open','awaiting_customer_selection','quoted')
    join public.service_requests r on r.id=w.request_id
    join public.partner_quotes q on q.request_id=r.id and q.partner_id=cr.partner_id
      and q.status in ('valid','selected') and q.submitted_at<w.deadline_at
    left join public.bike_route_prices bp on bp.request_id=r.id
    where cr.photo_path=p_path and cr.status='approved' and public.is_customer_user(r.customer_id)
      and (now()>=w.deadline_at or
        (bp.request_id is not null and q.amount_ngn=bp.customer_price_ngn))
  ) or exists (
    select 1 from public.company_riders cr
    join public.rider_credentials rc on rc.roster_id=cr.id and rc.partner_id=cr.partner_id
    join public.jobs j on j.assigned_rider_id=rc.user_id and j.partner_id=cr.partner_id
    where cr.photo_path=p_path and cr.status='approved' and public.is_customer_user(j.customer_id)
      and j.status not in ('cancelled','delivered','closed')
      and exists(select 1 from public.customer_payments cp where cp.job_id=j.id and cp.status='received')
  );
$$;
