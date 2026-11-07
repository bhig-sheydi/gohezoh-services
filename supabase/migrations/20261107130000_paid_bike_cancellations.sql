-- Customer-initiated cancellations before parcel handoff. The refund is
-- provider-driven; only a processed refund releases rider compensation.
create table public.paid_booking_cancellations (
  job_id uuid primary key references public.jobs(id) on delete restrict,
  customer_id uuid not null references public.customers(id) on delete restrict,
  partner_id uuid not null references public.logistics_partners(id) on delete restrict,
  rider_user_id uuid not null references auth.users(id) on delete restrict,
  payment_reference text not null unique,
  provider_transaction_id bigint not null unique,
  refund_reference text not null unique,
  paid_amount_ngn numeric(14,2) not null check (paid_amount_ngn > 1000),
  retained_ngn numeric(14,2) not null default 1000 check (retained_ngn = 1000),
  rider_compensation_ngn numeric(14,2) not null default 300 check (rider_compensation_ngn = 300),
  refund_amount_ngn numeric(14,2) generated always as (paid_amount_ngn-retained_ngn) stored,
  status text not null default 'requested' check (status in ('requested','pending','processing','needs_attention','processed','failed')),
  provider_refund_id bigint,
  requested_at timestamptz not null default now(),
  processed_at timestamptz,
  updated_at timestamptz not null default now()
);
create index paid_booking_cancellations_partner_status on public.paid_booking_cancellations(partner_id,status);
alter table public.paid_booking_cancellations enable row level security;
revoke all on public.paid_booking_cancellations from public,anon,authenticated;

create function public.request_paid_bike_cancellation(p_job_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_job public.jobs%rowtype;v_hold public.customer_payment_holds%rowtype;v_existing public.paid_booking_cancellations%rowtype;
begin
  if auth.uid() is null then raise insufficient_privilege; end if;
  select * into v_job from public.jobs where id=p_job_id for update;
  if not found or not public.is_customer_user(v_job.customer_id) then raise insufficient_privilege; end if;
  select * into v_existing from public.paid_booking_cancellations where job_id=p_job_id;
  if found then
    return jsonb_build_object('status',v_existing.status,'refund_reference',v_existing.refund_reference,
      'payment_reference',v_existing.payment_reference,'refund_amount_ngn',v_existing.refund_amount_ngn);
  end if;
  if v_job.status not in ('order_confirmed','partner_assigned','pickup_scheduled')
    or v_job.partner_id is null or v_job.assigned_rider_id is null
    or exists(select 1 from public.pickup_handoff_codes c where c.job_id=p_job_id and c.verified_at is not null) then
    raise object_not_in_prerequisite_state using message='This booking can only be cancelled before parcel pickup';
  end if;
  select h.* into v_hold from public.customer_payment_holds h
    join public.orders o on o.service_request_id=h.request_id where o.id=v_job.order_id for update of h;
  if not found or v_hold.provider<>'paystack' or v_hold.status<>'paid'
    or v_hold.provider_transaction_id is null or v_hold.amount_ngn<=1000 then
    raise object_not_in_prerequisite_state using message='Only a verified paid Paystack booking can be cancelled here';
  end if;
  insert into public.paid_booking_cancellations(job_id,customer_id,partner_id,rider_user_id,
    payment_reference,provider_transaction_id,refund_reference,paid_amount_ngn)
  values(p_job_id,v_job.customer_id,v_job.partner_id,v_job.assigned_rider_id,v_hold.reference,v_hold.provider_transaction_id,
    'KWP-REFUND-'||replace(p_job_id::text,'-',''),v_hold.amount_ngn);
  update public.jobs set status='cancelled' where id=p_job_id;
  update public.orders set status='cancelled' where id=v_job.order_id;
  update public.partner_assignments set status='cancelled' where job_id=p_job_id and status in ('assigned','accepted');
  return jsonb_build_object('status','requested','refund_reference','KWP-REFUND-'||replace(p_job_id::text,'-',''),
    'payment_reference',v_hold.reference,'refund_amount_ngn',v_hold.amount_ngn-1000);
end $$;
revoke all on function public.request_paid_bike_cancellation(uuid) from public,anon;
grant execute on function public.request_paid_bike_cancellation(uuid) to authenticated;

create function public.finish_paid_bike_refund(p_reference text,p_status text,p_provider_refund_id bigint default null)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v public.paid_booking_cancellations%rowtype;
begin
  if auth.role()<>'service_role' then raise insufficient_privilege; end if;
  if p_status not in ('pending','processing','needs_attention','processed','failed') then raise check_violation; end if;
  select * into v from public.paid_booking_cancellations where refund_reference=p_reference for update;
  if not found then raise no_data_found; end if;
  if v.status='processed' then return; end if;
  if v.status='failed' and p_status<>'processed' then return; end if;
  update public.paid_booking_cancellations set status=p_status,
    provider_refund_id=coalesce(p_provider_refund_id,provider_refund_id),
    processed_at=case when p_status='processed' then now() else processed_at end,updated_at=now()
    where job_id=v.job_id;
  if p_status='processed' then
    update public.job_financials set customer_revenue=1000,partner_cost=300,other_direct_cost=0,updated_at=now()
      where job_id=v.job_id;
  end if;
end $$;
revoke all on function public.finish_paid_bike_refund(text,text,bigint) from public,anon,authenticated;
grant execute on function public.finish_paid_bike_refund(text,text,bigint) to service_role;

create function public.list_my_paid_bike_cancellations(p_job_ids uuid[])
returns table(job_id uuid,status text,retained_ngn numeric,refund_amount_ngn numeric)
language sql stable security definer set search_path=pg_catalog,public as $$
  select c.job_id,c.status,c.retained_ngn,c.refund_amount_ngn
  from public.paid_booking_cancellations c where c.job_id=any(p_job_ids) and public.is_customer_user(c.customer_id);
$$;
revoke all on function public.list_my_paid_bike_cancellations(uuid[]) from public,anon;
grant execute on function public.list_my_paid_bike_cancellations(uuid[]) to authenticated;

-- Existing status guard remains intact, with a protected cancellation exception.
create or replace function public.guard_job_status_transition()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_staff boolean;v_accepted_partner boolean;v_rejected_partner boolean;v_rider boolean;v_sender_approved boolean;
begin
  if new.status is not distinct from old.status then return new; end if;
  if new.status='cancelled' and old.status in ('order_confirmed','partner_assigned','pickup_scheduled')
    and exists(select 1 from public.paid_booking_cancellations c where c.job_id=old.id
      and c.status='requested' and c.customer_id=old.customer_id) then return new; end if;
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

-- A refunded cancellation contributes only the NGN 300 company payout.
create or replace function public.get_my_partner_payables()
returns table(partner_id uuid,currency text,available_ngn numeric,pending_delivery_ngn numeric,
  withdrawal_pending_ngn numeric,total_paid_ngn numeric)
language sql stable security definer set search_path=pg_catalog,public as $$
  with mine as (
    select p.id from public.logistics_partners p
    join public.partner_users pu on pu.partner_id=p.id
    where pu.user_id=auth.uid() and public.company_staff_allowed(p.id,'withdraw') and p.status='active'
  ), fees as (
    select j.id job_id,j.partner_id,j.status, f.partner_cost,
      coalesce((select sum(cp.amount) from public.customer_payments cp
        where cp.job_id=j.id and cp.status='received' and cp.currency='NGN'),0) received,
      f.customer_revenue
    from public.jobs j join mine m on m.id=j.partner_id
    join public.job_financials f on f.job_id=j.id and f.currency='NGN'
    where (j.status<>'cancelled' or exists(select 1 from public.paid_booking_cancellations pc
      where pc.job_id=j.id and pc.status='processed'))
  ), commitments as (
    select s.job_id,
      coalesce(sum(s.amount) filter (where s.status<>'cancelled'),0) committed,
      coalesce(sum(s.amount) filter (where s.status in ('pending','approved') and s.withdrawal_id is not null),0) withdrawal_pending,
      coalesce(sum(s.amount) filter (where s.status='paid'),0) paid
    from public.partner_settlements s join fees f on f.job_id=s.job_id
    group by s.job_id
  )
  select m.id,'NGN'::text,
    coalesce(sum(greatest(f.partner_cost-coalesce(c.committed,0),0)) filter
      (where f.status in ('delivered','closed','cancelled') and f.received>=f.customer_revenue),0)::numeric,
    coalesce(sum(f.partner_cost) filter
      (where f.status not in ('delivered','closed','cancelled') and f.received>=f.customer_revenue),0)::numeric,
    coalesce(sum(c.withdrawal_pending),0)::numeric,
    coalesce(sum(c.paid),0)::numeric
  from mine m left join fees f on f.partner_id=m.id
  left join commitments c on c.job_id=f.job_id
  group by m.id;
$$;

-- Cancelled jobs enter withdrawals only after provider-confirmed refunds.
create or replace function public.request_partner_withdrawal(
  p_partner_id uuid,p_amount_ngn numeric,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_actor uuid := auth.uid(); v_partner public.logistics_partners%rowtype;
  v_existing public.partner_withdrawals%rowtype; v_account public.partner_payout_accounts%rowtype;
  v_withdrawal uuid; v_transfer_reference text;
  v_job record; v_committed numeric; v_remaining numeric; v_take numeric;
  v_received numeric; v_reserved numeric := 0; v_count integer := 0;
  v_quote jsonb;v_gross numeric;
begin
  if v_actor is null or p_partner_id is null or p_idempotency_key is null then
    raise check_violation using message='Enter a valid withdrawal amount';
  end if;
  select * into v_partner from public.logistics_partners where id=p_partner_id for update;
  if not found or v_partner.status<>'active' or not exists (
    select 1 from public.partner_users pu where pu.partner_id=p_partner_id
      and pu.user_id=v_actor and public.company_staff_allowed(p_partner_id,'withdraw')) then
    raise insufficient_privilege using message='An active company manager is required';
  end if;
  v_quote:=public.paystack_withdrawal_charges(p_amount_ngn);
  v_gross:=(v_quote->>'gross_amount_ngn')::numeric;
  select * into v_account from public.partner_payout_accounts where partner_id=p_partner_id;
  if not found then
    raise object_not_in_prerequisite_state using message='Verify a company bank account before withdrawing';
  end if;
  select * into v_existing from public.partner_withdrawals
    where partner_id=p_partner_id and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.transfer_amount_ngn<>p_amount_ngn then
      raise check_violation using message='This withdrawal key was used for a different bank transfer amount';
    end if;
    return jsonb_build_object('withdrawal_id',v_existing.id,'status',v_existing.status,
      'amount_ngn',v_existing.amount_ngn,'transfer_amount_ngn',v_existing.transfer_amount_ngn,
      'transfer_fee_ngn',v_existing.transfer_fee_ngn,'stamp_duty_ngn',v_existing.stamp_duty_ngn);
  end if;

  -- Reserve the entire debit including bank charges from completed, paid jobs.
  v_withdrawal:=gen_random_uuid();
  v_transfer_reference:='KWP-PAYOUT-'||replace(v_withdrawal::text,'-','');
  insert into public.partner_withdrawals(id,partner_id,requested_by,amount_ngn,
    transfer_amount_ngn,transfer_fee_ngn,stamp_duty_ngn,fee_schedule,idempotency_key,
    status,bank_code_snapshot,bank_name_snapshot,account_number_snapshot,account_name_snapshot,
    transfer_reference,provider)
    values(v_withdrawal,p_partner_id,v_actor,v_gross,p_amount_ngn,
      (v_quote->>'transfer_fee_ngn')::numeric,(v_quote->>'stamp_duty_ngn')::numeric,
      v_quote->>'fee_schedule',p_idempotency_key,'reserved',
      v_account.bank_code,v_account.bank_name,v_account.account_number,v_account.account_name,
      v_transfer_reference,'paystack');
  v_remaining := v_gross;
  for v_job in
    select j.id, f.partner_cost, f.customer_revenue
    from public.jobs j join public.job_financials f on f.job_id=j.id
    where j.partner_id=p_partner_id and (j.status in ('delivered','closed')
      or (j.status='cancelled' and exists(select 1 from public.paid_booking_cancellations pc
        where pc.job_id=j.id and pc.status='processed')))
      and f.currency='NGN' and f.partner_cost>0
    order by j.created_at,j.id for update of j
  loop
    select coalesce(sum(cp.amount),0) into v_received from public.customer_payments cp
      where cp.job_id=v_job.id and cp.status='received' and cp.currency='NGN';
    if v_received < v_job.customer_revenue then continue; end if;
    select coalesce(sum(s.amount),0) into v_committed from public.partner_settlements s
      where s.job_id=v_job.id and s.status<>'cancelled';
    v_take := least(v_remaining,greatest(v_job.partner_cost-v_committed,0));
    if v_take<=0 then continue; end if;
    insert into public.partner_settlements(job_id,partner_id,amount,currency,
      request_reference,notes,created_by,withdrawal_id)
    values(v_job.id,p_partner_id,v_take,'NGN',
      'partner-withdrawal:'||v_withdrawal::text||':'||v_job.id::text,
      'Automatic Paystack payout and bank charges reserved; provider status controls paid state',v_actor,v_withdrawal);
    v_reserved := v_reserved+v_take;
    v_remaining := v_remaining-v_take;
    v_count := v_count+1;
    exit when v_remaining=0;
  end loop;
  if v_remaining<>0 then
    raise check_violation using message='Bank transfer and charges exceed available company earnings';
  end if;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('partner_withdrawal',v_withdrawal,'requested',v_actor,
      array['partner_id','amount_ngn','transfer_amount_ngn','transfer_fee_ngn','stamp_duty_ngn','job_count']);
  return jsonb_build_object('withdrawal_id',v_withdrawal,'status','reserved',
    'amount_ngn',v_reserved,'transfer_amount_ngn',p_amount_ngn,
    'transfer_fee_ngn',v_quote->'transfer_fee_ngn','stamp_duty_ngn',v_quote->'stamp_duty_ngn',
    'settlement_count',v_count);
end $$;
