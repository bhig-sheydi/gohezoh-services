create or replace function public.my_current_delivery_rider(p_job_id uuid) returns jsonb
language sql stable security definer set search_path=pg_catalog,public as $$
  select jsonb_build_object('name',coalesce(cr.full_name,rc.rider_name),'phone',cr.phone,
    'photo_path',case when cr.photo_path ~* '[.](jpg|jpeg|png|webp)$' then cr.photo_path else null end,
    'status',case when j.assigned_rider_id is null then 'finding_replacement'
      when rr.id is not null and rr.accepted_at is null then 'awaiting_response' else 'on_the_way' end,
    'issue',j.route_assignment_issue)
  from public.jobs j join public.orders o on o.id=j.order_id
  left join public.rider_credentials rc on rc.user_id=j.assigned_rider_id
  left join public.company_riders cr on cr.id=rc.roster_id
  left join public.rider_assignment_responses rr on rr.job_id=j.id and rr.rider_id=j.assigned_rider_id
    and rr.timed_out_at is null
  where j.id=p_job_id and public.is_customer_user(j.customer_id)
    and (exists(select 1 from public.customer_payment_holds h where h.request_id=o.service_request_id and h.status='paid')
      or exists(select 1 from public.customer_payments cp where cp.job_id=j.id and cp.status='received'));
$$;

create or replace function public.can_customer_read_rider_bid_photo(p_path text) returns boolean
language sql stable security definer set search_path=pg_catalog,public as $$
  select exists (
    select 1 from public.company_riders cr
    join public.rider_credentials rc on rc.roster_id=cr.id and rc.partner_id=cr.partner_id
    join public.company_bid_invitations i on i.rider_id=rc.user_id and i.partner_id=cr.partner_id
    join public.delivery_quote_windows w on w.request_id=i.request_id and now()>=w.deadline_at
      and w.status in ('open','awaiting_customer_selection','quoted')
    join public.service_requests r on r.id=w.request_id
    join public.partner_quotes q on q.request_id=r.id and q.partner_id=cr.partner_id
      and q.status in ('valid','selected') and q.submitted_at<w.deadline_at
    where cr.photo_path=p_path and cr.status='approved' and public.is_customer_user(r.customer_id)
  ) or exists (
    select 1 from public.company_riders cr
    join public.rider_credentials rc on rc.roster_id=cr.id and rc.partner_id=cr.partner_id
    join public.jobs j on j.assigned_rider_id=rc.user_id and j.partner_id=cr.partner_id
    where cr.photo_path=p_path and cr.status='approved' and public.is_customer_user(j.customer_id)
      and j.status not in ('cancelled','delivered','closed')
      and exists(select 1 from public.customer_payments cp where cp.job_id=j.id and cp.status='received')
  );
$$;
