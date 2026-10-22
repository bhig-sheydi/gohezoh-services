-- A sender may confirm delivery when the recipient cannot provide the OTP.
-- Only the assigned rider can ask, and only the authenticated customer owner
-- can answer. The confirmation is not a rider-completed delivery.
create table public.sender_delivery_confirmations (
  job_id uuid primary key references public.jobs(id) on delete restrict,
  requested_by uuid not null references auth.users(id),
  requested_at timestamptz not null default now(),
  status text not null check (status in ('pending', 'approved', 'rejected')),
  responded_by uuid references auth.users(id),
  responded_at timestamptz
);
alter table public.sender_delivery_confirmations enable row level security;
revoke all on public.sender_delivery_confirmations from public, anon, authenticated;

create function public.request_sender_delivery_confirmation(p_job_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_job public.jobs%rowtype; v_request public.sender_delivery_confirmations%rowtype;
begin
  select * into v_job from public.jobs where id=p_job_id for update;
  if not found then raise no_data_found using message='Delivery job was not found'; end if;
  if not public.rider_session_active() or v_job.assigned_rider_id is distinct from auth.uid()
    or not exists(select 1 from public.partner_assignments pa join public.partner_users pu
      on pu.partner_id=pa.partner_id and pu.user_id=auth.uid() and pu.membership_role='rider'
      where pa.job_id=v_job.id and pa.partner_id=v_job.partner_id and pa.status='accepted') then
    raise insufficient_privilege using message='Only the assigned active rider can request sender confirmation';
  end if;
  if v_job.status not in ('picked_up','in_transit','out_for_delivery') or not exists(
    select 1 from public.orders o join public.customer_payment_holds h on h.request_id=o.service_request_id
    where o.id=v_job.order_id and h.status='paid') then
    raise object_not_in_prerequisite_state using message='Only a paid parcel in transit can request sender confirmation';
  end if;
  select * into v_request from public.sender_delivery_confirmations where job_id=p_job_id for update;
  if found and v_request.status='approved' then
    raise object_not_in_prerequisite_state using message='Delivery was already confirmed'; end if;
  if found and v_request.status='pending' then
    return jsonb_build_object('status','pending','requested_at',v_request.requested_at); end if;
  if found and now()-v_request.requested_at < interval '5 minutes' then
    raise object_not_in_prerequisite_state using message='Wait before asking the sender again'; end if;
  insert into public.sender_delivery_confirmations(job_id,requested_by,status)
    values(p_job_id,auth.uid(),'pending')
    on conflict(job_id) do update set requested_by=excluded.requested_by,requested_at=now(),
      status='pending',responded_by=null,responded_at=null;
  perform public.notify_customer_users(v_job.customer_id,v_job.id,'sender_delivery_confirmation_requested',
    'Confirm parcel arrival',format('Rider requests your confirmation that %s reached its destination.',v_job.job_number),
    jsonb_build_object('job_id',v_job.id,'job_number',v_job.job_number));
  return jsonb_build_object('status','pending','requested_at',now());
end $$;
revoke all on function public.request_sender_delivery_confirmation(uuid) from public,anon;
grant execute on function public.request_sender_delivery_confirmation(uuid) to authenticated;

create function public.list_my_sender_delivery_confirmations()
returns table(job_id uuid,status text,requested_at timestamptz)
language sql stable security definer set search_path=pg_catalog,public as $$
  select c.job_id,c.status,c.requested_at
  from public.sender_delivery_confirmations c join public.jobs j on j.id=c.job_id
  where public.is_customer_user(j.customer_id)
  order by c.requested_at desc limit 100;
$$;
revoke all on function public.list_my_sender_delivery_confirmations() from public,anon;
grant execute on function public.list_my_sender_delivery_confirmations() to authenticated;

create function public.respond_sender_delivery_confirmation(p_job_id uuid,p_approve boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_job public.jobs%rowtype;v_request public.sender_delivery_confirmations%rowtype;
begin
  if p_approve is null then raise invalid_parameter_value using message='Choose yes or no'; end if;
  select * into v_job from public.jobs where id=p_job_id for update;
  if not found then raise no_data_found using message='Delivery job was not found'; end if;
  if not public.is_customer_user(v_job.customer_id) then
    raise insufficient_privilege using message='Only the sender account can confirm this delivery'; end if;
  select * into v_request from public.sender_delivery_confirmations where job_id=p_job_id for update;
  if not found or v_request.status<>'pending' then
    raise object_not_in_prerequisite_state using message='No sender confirmation is awaiting your answer'; end if;
  if v_job.status not in ('picked_up','in_transit','out_for_delivery') or not exists(
    select 1 from public.orders o join public.customer_payment_holds h on h.request_id=o.service_request_id
    where o.id=v_job.order_id and h.status='paid') then
    raise object_not_in_prerequisite_state using message='This delivery cannot be confirmed now'; end if;
  update public.sender_delivery_confirmations set status=case when p_approve then 'approved' else 'rejected' end,
    responded_by=auth.uid(),responded_at=now() where job_id=p_job_id;
  if p_approve then
    update public.jobs set status='delivered' where id=p_job_id;
    update public.partner_assignments set status='completed',completed_at=now()
      where job_id=p_job_id and status='accepted';
  end if;
  return jsonb_build_object('status',case when p_approve then 'approved' else 'rejected' end);
end $$;
revoke all on function public.respond_sender_delivery_confirmation(uuid,boolean) from public,anon;
grant execute on function public.respond_sender_delivery_confirmation(uuid,boolean) to authenticated;

-- Preserve all existing transition rules; add only a tightly scoped customer
-- approval branch. No table DML is available to authenticated clients.
create or replace function public.guard_job_status_transition()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_staff boolean;v_accepted_partner boolean;v_rejected_partner boolean;v_rider boolean;v_sender_approved boolean;
begin
  if new.status is not distinct from old.status then return new; end if;
  v_sender_approved:=new.status='delivered' and public.is_customer_user(old.customer_id) and exists(
    select 1 from public.sender_delivery_confirmations c where c.job_id=old.id
      and c.status='approved' and c.responded_by=auth.uid());
  if new.status='delivered' and not v_sender_approved and not exists(
    select 1 from public.otp_verifications ov where ov.job_id=old.id and ov.verified_at is not null) then
    raise object_not_in_prerequisite_state using message='Recipient code or sender approval is required before marking delivered';
  end if;
  v_staff:=public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management');
  v_accepted_partner:=exists(select 1 from public.partner_assignments pa where pa.job_id=old.id and pa.partner_id=old.partner_id and pa.status='accepted' and public.is_partner_user(pa.partner_id));
  v_rejected_partner:=exists(select 1 from public.partner_assignments pa where pa.job_id=old.id and pa.partner_id=old.partner_id and pa.status='rejected' and public.is_partner_user(pa.partner_id));
  v_rider:=public.rider_session_active() and old.assigned_rider_id=auth.uid() and exists(
    select 1 from public.partner_assignments pa join public.partner_users pu on pu.partner_id=pa.partner_id
    where pa.job_id=old.id and pa.partner_id=old.partner_id and pa.status='accepted'
      and pu.user_id=auth.uid() and pu.membership_role='rider');
  if not (v_staff or v_accepted_partner or v_rider or v_sender_approved or (v_rejected_partner and old.status='partner_assigned' and new.status='order_confirmed' and new.partner_id is null)) then
    raise insufficient_privilege using message='Only authorized delivery participants can update progress';
  end if;
  if (v_accepted_partner or v_rider) and not v_staff and not v_sender_approved and new.status not in ('pickup_scheduled','picked_up','in_transit','out_for_delivery','delivered','exception','hub_received') then
    raise insufficient_privilege using message='Riders can update pickup, transit, hub handoff, delivery, or exception statuses only';
  end if;
  if not (
    (old.status='order_confirmed' and new.status in ('partner_assigned','pickup_scheduled','picked_up','exception','cancelled'))
    or (old.status='partner_assigned' and new.status in ('order_confirmed','pickup_scheduled','picked_up','in_transit','exception','cancelled'))
    or (old.status='pickup_scheduled' and new.status in ('picked_up','in_transit','exception','cancelled'))
    or (old.status='picked_up' and new.status in ('in_transit','delivered','exception'))
    or (old.status='in_transit' and new.status in ('out_for_delivery','hub_received','delivered','exception'))
    or (old.status='out_for_delivery' and new.status in ('delivered','hub_received','exception'))
    or (old.status='hub_received' and new.status='partner_assigned')
    or (old.status='delivered' and new.status='closed')
    or (old.status='exception' and new.status in ('pickup_scheduled','picked_up','in_transit','out_for_delivery','cancelled'))
  ) then raise object_not_in_prerequisite_state using message='That delivery status transition is not allowed'; end if;
  return new;
end $$;
