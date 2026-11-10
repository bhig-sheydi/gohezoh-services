-- Existing unpaid/non-bike workflows retain their prior status transitions.
create or replace function public.require_rider_response_before_pickup() returns trigger
language plpgsql set search_path=pg_catalog,public as $$
begin
  if new.status in ('picked_up','in_transit') and old.status in ('partner_assigned','pickup_scheduled')
    and exists(select 1 from public.rider_assignment_responses r where r.job_id=new.id
      and r.rider_id=new.assigned_rider_id and r.accepted_at is null)
    and exists(select 1 from public.services s where s.id=new.service_id and s.code='SRV-0001')
    and exists(select 1 from public.customer_payments cp where cp.job_id=new.id
      and cp.status='received' and cp.currency='NGN') then
    raise check_violation using message='Rider must accept the ride before collecting the parcel';
  end if;
  return new;
end $$;

create or replace function public.track_rider_assignment_response() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.assigned_rider_id is not null and new.status in ('partner_assigned','pickup_scheduled')
    and (tg_op='INSERT' or new.assigned_rider_id is distinct from old.assigned_rider_id)
    and exists(select 1 from public.services s where s.id=new.service_id and s.code='SRV-0001')
    and exists(select 1 from public.customer_payments cp where cp.job_id=new.id
      and cp.status='received' and cp.currency='NGN') then
    update public.rider_assignment_responses set timed_out_at=now()
      where job_id=new.id and accepted_at is null and timed_out_at is null;
    insert into public.rider_assignment_responses(job_id,rider_id,partner_id)
      values(new.id,new.assigned_rider_id,new.partner_id);
  end if;
  return new;
end $$;
