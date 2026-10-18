-- Keep rider photo checks inside a security-definer function. A direct RLS
-- expression referencing rider_credentials makes unrelated storage reads fail
-- because authenticated users cannot select that private credential table.
create function public.can_customer_read_rider_bid_photo(p_path text) returns boolean
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
  );
$$;
revoke all on function public.can_customer_read_rider_bid_photo(text) from public,anon;
grant execute on function public.can_customer_read_rider_bid_photo(text) to authenticated;

drop policy rider_photo_customer_bid_read on storage.objects;
create policy rider_photo_customer_bid_read on storage.objects for select to authenticated
using (bucket_id='rider-evidence' and public.can_customer_read_rider_bid_photo(name));
