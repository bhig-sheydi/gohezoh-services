create function public.list_my_partner_cancellation_compensation(p_partner_id uuid)
returns table(job_id uuid,job_number text,rider_name text,amount_ngn numeric,processed_at timestamptz)
language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not public.company_staff_allowed(p_partner_id,'withdraw') then raise insufficient_privilege; end if;
  return query
  select c.job_id,j.job_number,coalesce(rc.rider_name,'Assigned rider'),c.rider_compensation_ngn,c.processed_at
  from public.paid_booking_cancellations c
  join public.jobs j on j.id=c.job_id
  left join public.rider_credentials rc on rc.user_id=c.rider_user_id
  where c.partner_id=p_partner_id and c.status='processed'
  order by c.processed_at desc limit 10;
end $$;
revoke all on function public.list_my_partner_cancellation_compensation(uuid) from public,anon;
grant execute on function public.list_my_partner_cancellation_compensation(uuid) to authenticated;
