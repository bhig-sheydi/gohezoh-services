-- Independent deliveries belong to the rider, while the existing settlement
-- ledger remains the single source of truth for each job's 75% payout.
alter table public.partner_withdrawals add column rider_user_id uuid references auth.users(id) on delete restrict;
alter table public.partner_withdrawals add constraint independent_rider_withdrawal_owner
  check (rider_user_id is null or rider_user_id=requested_by);
create index partner_withdrawals_rider_idx on public.partner_withdrawals(rider_user_id,created_at desc)
  where rider_user_id is not null;

-- Finance and company payout paths must not create a second claim on a rider job.
create function public.require_independent_rider_settlement_owner()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_rider uuid;
begin
  select r.independent_user_id into v_rider from public.jobs j
    join public.company_riders r on r.partner_id=j.partner_id and r.independent_user_id=j.assigned_rider_id
    where j.id=new.job_id;
  if v_rider is not null and not exists (
    select 1 from public.partner_withdrawals w where w.id=new.withdrawal_id
      and w.rider_user_id=v_rider and w.partner_id=new.partner_id
  ) then raise check_violation using message='Independent rider delivery earnings belong to the assigned rider'; end if;
  return new;
end $$;
create trigger require_independent_rider_settlement_owner_insert
before insert or update of job_id,partner_id,withdrawal_id on public.partner_settlements
for each row execute function public.require_independent_rider_settlement_owner();
revoke all on function public.require_independent_rider_settlement_owner() from public,anon,authenticated;

create or replace function public.guard_partner_withdrawal_snapshot()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin
  if (new.partner_id,new.requested_by,new.rider_user_id,new.amount_ngn,new.transfer_amount_ngn,
      new.transfer_fee_ngn,new.stamp_duty_ngn,new.fee_schedule,new.idempotency_key,
      new.bank_code_snapshot,new.bank_name_snapshot,new.account_number_snapshot,
      new.account_name_snapshot,new.transfer_reference)
     is distinct from
     (old.partner_id,old.requested_by,old.rider_user_id,old.amount_ngn,old.transfer_amount_ngn,
      old.transfer_fee_ngn,old.stamp_duty_ngn,old.fee_schedule,old.idempotency_key,
      old.bank_code_snapshot,old.bank_name_snapshot,old.account_number_snapshot,
      old.account_name_snapshot,old.transfer_reference) then
    raise check_violation using message='Withdrawal beneficiary and financial breakdown cannot change';
  end if;
  return new;
end $$;

create table public.independent_rider_payout_accounts (
  rider_user_id uuid primary key references auth.users(id) on delete restrict,
  bank_code text not null check (bank_code ~ '^[0-9]{2,10}$'),
  bank_name text not null check (length(btrim(bank_name)) between 2 and 120),
  account_number text not null check (account_number ~ '^[0-9]{10}$'),
  account_name text not null check (length(btrim(account_name)) between 3 and 150),
  verified_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.independent_rider_payout_accounts enable row level security;
revoke all on public.independent_rider_payout_accounts from public,anon,authenticated;

create table public.independent_rider_bank_resolve_attempts (
  id bigint generated always as identity primary key,
  rider_user_id uuid not null references auth.users(id) on delete restrict,
  attempted_at timestamptz not null default now()
);
create index independent_rider_bank_resolve_attempts_idx
  on public.independent_rider_bank_resolve_attempts(rider_user_id,attempted_at desc);
alter table public.independent_rider_bank_resolve_attempts enable row level security;
revoke all on public.independent_rider_bank_resolve_attempts from public,anon,authenticated;

create function public.independent_rider_payout_partner(p_user_id uuid)
returns uuid language sql stable security definer set search_path=pg_catalog,public,auth as $$
  select r.partner_id from public.company_riders r join public.logistics_partners p on p.id=r.partner_id
  where r.independent_user_id=p_user_id and r.status='approved' and p.status='active'
    and exists(select 1 from auth.users u where u.id=p_user_id
      and u.raw_user_meta_data->>'account_kind'='independent_rider')
    and exists(select 1 from public.rider_credentials c where c.user_id=p_user_id
      and c.roster_id=r.id and c.revoked_at is null and c.password_revoked_at is null)
  limit 1;
$$;
revoke all on function public.independent_rider_payout_partner(uuid) from public,anon,authenticated;
grant execute on function public.independent_rider_payout_partner(uuid) to service_role;

create function public.authorize_independent_rider_bank_resolve(p_actor_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_used integer;
begin
  if auth.role()<>'service_role' or public.independent_rider_payout_partner(p_actor_id) is null then
    raise insufficient_privilege using message='An active independent rider account is required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('rider-bank-resolve:'||p_actor_id::text,0));
  select count(*) into v_used from public.independent_rider_bank_resolve_attempts
    where rider_user_id=p_actor_id and attempted_at>now()-interval '15 minutes';
  if v_used>=5 then raise check_violation using message='Too many bank account checks. Try again in 15 minutes'; end if;
  insert into public.independent_rider_bank_resolve_attempts(rider_user_id) values(p_actor_id);
  return jsonb_build_object('allowed',true,'remaining',4-v_used);
end $$;
revoke all on function public.authorize_independent_rider_bank_resolve(uuid) from public,anon,authenticated;
grant execute on function public.authorize_independent_rider_bank_resolve(uuid) to service_role;

create function public.save_verified_independent_rider_payout_account(
  p_actor_id uuid,p_bank_code text,p_bank_name text,p_account_number text,p_account_name text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if auth.role()<>'service_role' or public.independent_rider_payout_partner(p_actor_id) is null then
    raise insufficient_privilege using message='An active independent rider account is required'; end if;
  if p_bank_code !~ '^[0-9]{2,10}$' or p_account_number !~ '^[0-9]{10}$'
    or length(btrim(coalesce(p_bank_name,''))) not between 2 and 120
    or length(btrim(coalesce(p_account_name,''))) not between 3 and 150 then
    raise check_violation using message='Invalid verified bank account'; end if;
  insert into public.independent_rider_payout_accounts(rider_user_id,bank_code,bank_name,account_number,account_name)
  values(p_actor_id,p_bank_code,btrim(p_bank_name),p_account_number,btrim(p_account_name))
  on conflict(rider_user_id) do update set bank_code=excluded.bank_code,bank_name=excluded.bank_name,
    account_number=excluded.account_number,account_name=excluded.account_name,verified_at=now(),updated_at=now();
  return jsonb_build_object('bank_name',btrim(p_bank_name),'account_name',btrim(p_account_name),
    'account_last4',right(p_account_number,4));
end $$;
revoke all on function public.save_verified_independent_rider_payout_account(uuid,text,text,text,text) from public,anon,authenticated;
grant execute on function public.save_verified_independent_rider_payout_account(uuid,text,text,text,text) to service_role;

create function public.get_my_independent_rider_payout_account()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_account public.independent_rider_payout_accounts%rowtype;
begin
  if auth.role()<>'authenticated' or public.independent_rider_payout_partner(auth.uid()) is null then
    raise insufficient_privilege using message='An active independent rider account is required'; end if;
  select * into v_account from public.independent_rider_payout_accounts where rider_user_id=auth.uid();
  if not found then return jsonb_build_object('verified',false); end if;
  return jsonb_build_object('verified',true,'bank_name',v_account.bank_name,
    'account_name',v_account.account_name,'account_last4',right(v_account.account_number,4),
    'verified_at',v_account.verified_at);
end $$;
revoke all on function public.get_my_independent_rider_payout_account() from public,anon;
grant execute on function public.get_my_independent_rider_payout_account() to authenticated;

create function public.get_my_independent_rider_payables()
returns table(available_ngn numeric,pending_delivery_ngn numeric,withdrawal_pending_ngn numeric,total_paid_ngn numeric)
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_partner uuid;
begin
  if auth.role()<>'authenticated' then raise insufficient_privilege; end if;
  v_partner:=public.independent_rider_payout_partner(auth.uid());
  if v_partner is null then raise insufficient_privilege using message='An active independent rider account is required'; end if;
  return query with fees as (
    select j.id,j.status,f.partner_cost,f.customer_revenue,
      coalesce((select sum(cp.amount) from public.customer_payments cp where cp.job_id=j.id
        and cp.status='received' and cp.currency='NGN'),0) received
    from public.jobs j join public.job_financials f on f.job_id=j.id and f.currency='NGN'
    where j.partner_id=v_partner and j.assigned_rider_id=auth.uid()
      and j.status<>'cancelled'
  ), commitments as (
    select s.job_id,coalesce(sum(s.amount) filter(where s.status<>'cancelled'),0) committed,
      coalesce(sum(s.amount) filter(where s.status in ('pending','approved') and w.rider_user_id=auth.uid()),0) pending,
      coalesce(sum(s.amount) filter(where s.status='paid' and w.rider_user_id=auth.uid()),0) paid
    from public.partner_settlements s join fees f on f.id=s.job_id
    left join public.partner_withdrawals w on w.id=s.withdrawal_id group by s.job_id
  ) select
    coalesce(sum(greatest(f.partner_cost-coalesce(c.committed,0),0)) filter
      (where f.status in ('delivered','closed') and f.received>=f.customer_revenue),0)::numeric,
    coalesce(sum(f.partner_cost) filter(where f.status not in ('delivered','closed')
      and f.received>=f.customer_revenue),0)::numeric,
    coalesce(sum(c.pending),0)::numeric,coalesce(sum(c.paid),0)::numeric
  from fees f left join commitments c on c.job_id=f.id;
end $$;
revoke all on function public.get_my_independent_rider_payables() from public,anon;
grant execute on function public.get_my_independent_rider_payables() to authenticated;

create function public.list_my_independent_rider_withdrawals()
returns table(withdrawal_id uuid,amount_ngn numeric,transfer_amount_ngn numeric,status text,
  bank_name text,account_last4 text,created_at timestamptz,completed_at timestamptz)
language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if auth.role()<>'authenticated' or public.independent_rider_payout_partner(auth.uid()) is null then
    raise insufficient_privilege using message='An active independent rider account is required'; end if;
  return query select w.id,w.amount_ngn,w.transfer_amount_ngn,w.status,w.bank_name_snapshot,
    right(w.account_number_snapshot,4),w.created_at,w.completed_at
  from public.partner_withdrawals w where w.rider_user_id=auth.uid()
  order by w.created_at desc limit 50;
end $$;
revoke all on function public.list_my_independent_rider_withdrawals() from public,anon;
grant execute on function public.list_my_independent_rider_withdrawals() to authenticated;

create or replace function public.list_my_partner_withdrawals(p_partner_id uuid)
returns table(withdrawal_id uuid,amount_ngn numeric,status text,bank_name text,account_last4 text,
  created_at timestamptz,completed_at timestamptz,transfer_amount_ngn numeric,
  transfer_fee_ngn numeric,stamp_duty_ngn numeric)
language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not exists(select 1 from public.partner_users pu where pu.partner_id=p_partner_id
    and pu.user_id=auth.uid() and public.company_staff_allowed(p_partner_id,'withdraw')) then
    raise insufficient_privilege using message='Company manager required'; end if;
  return query select w.id,w.amount_ngn,w.status,w.bank_name_snapshot,
    right(w.account_number_snapshot,4),w.created_at,w.completed_at,
    w.transfer_amount_ngn,w.transfer_fee_ngn,w.stamp_duty_ngn
  from public.partner_withdrawals w where w.partner_id=p_partner_id and w.rider_user_id is null
  order by w.created_at desc limit 50;
end $$;

create function public.request_independent_rider_withdrawal(p_amount_ngn numeric,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_actor uuid:=auth.uid();v_partner uuid;v_account public.independent_rider_payout_accounts%rowtype;
  v_existing public.partner_withdrawals%rowtype;v_quote jsonb;v_gross numeric;v_withdrawal uuid;
  v_job record;v_received numeric;v_committed numeric;v_take numeric;v_remaining numeric;
begin
  if auth.role()<>'authenticated' or p_idempotency_key is null then raise insufficient_privilege; end if;
  -- Serialize all payout reservations for this company, including company managers.
  select r.partner_id into v_partner from public.company_riders r
    where r.independent_user_id=v_actor for update;
  if v_partner is null or public.independent_rider_payout_partner(v_actor) is distinct from v_partner then
    raise insufficient_privilege using message='An active independent rider account is required'; end if;
  v_quote:=public.paystack_withdrawal_charges(p_amount_ngn);
  v_gross:=(v_quote->>'gross_amount_ngn')::numeric;
  select * into v_account from public.independent_rider_payout_accounts where rider_user_id=v_actor;
  if not found then raise object_not_in_prerequisite_state using message='Verify a bank account before withdrawing'; end if;
  select * into v_existing from public.partner_withdrawals
    where partner_id=v_partner and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.rider_user_id is distinct from v_actor or v_existing.transfer_amount_ngn<>p_amount_ngn then
      raise check_violation using message='This withdrawal key was used for a different request'; end if;
    return jsonb_build_object('withdrawal_id',v_existing.id,'status',v_existing.status,
      'amount_ngn',v_existing.amount_ngn,'transfer_amount_ngn',v_existing.transfer_amount_ngn,
      'transfer_fee_ngn',v_existing.transfer_fee_ngn,'stamp_duty_ngn',v_existing.stamp_duty_ngn);
  end if;
  v_withdrawal:=gen_random_uuid();
  insert into public.partner_withdrawals(id,partner_id,requested_by,rider_user_id,amount_ngn,
    transfer_amount_ngn,transfer_fee_ngn,stamp_duty_ngn,fee_schedule,idempotency_key,status,
    bank_code_snapshot,bank_name_snapshot,account_number_snapshot,account_name_snapshot,transfer_reference,provider)
  values(v_withdrawal,v_partner,v_actor,v_actor,v_gross,p_amount_ngn,
    (v_quote->>'transfer_fee_ngn')::numeric,(v_quote->>'stamp_duty_ngn')::numeric,
    v_quote->>'fee_schedule',p_idempotency_key,'reserved',v_account.bank_code,v_account.bank_name,
    v_account.account_number,v_account.account_name,'KWP-PAYOUT-'||replace(v_withdrawal::text,'-',''),'paystack');
  v_remaining:=v_gross;
  for v_job in select j.id,f.partner_cost,f.customer_revenue from public.jobs j
    join public.job_financials f on f.job_id=j.id and f.currency='NGN'
    where j.partner_id=v_partner and j.assigned_rider_id=v_actor
      and j.status in ('delivered','closed') and f.partner_cost>0
    order by j.created_at,j.id for update of j
  loop
    select coalesce(sum(cp.amount),0) into v_received from public.customer_payments cp
      where cp.job_id=v_job.id and cp.status='received' and cp.currency='NGN';
    if v_received<v_job.customer_revenue then continue; end if;
    select coalesce(sum(s.amount),0) into v_committed from public.partner_settlements s
      where s.job_id=v_job.id and s.status<>'cancelled';
    v_take:=least(v_remaining,greatest(v_job.partner_cost-v_committed,0));
    if v_take<=0 then continue; end if;
    insert into public.partner_settlements(job_id,partner_id,amount,currency,request_reference,
      notes,created_by,withdrawal_id)
    values(v_job.id,v_partner,v_take,'NGN','rider-withdrawal:'||v_withdrawal::text||':'||v_job.id::text,
      'Independent rider Paystack transfer and bank charges reserved',v_actor,v_withdrawal);
    v_remaining:=v_remaining-v_take;
    exit when v_remaining=0;
  end loop;
  if v_remaining<>0 then raise check_violation using message='Bank transfer and charges exceed available rider earnings'; end if;
  return jsonb_build_object('withdrawal_id',v_withdrawal,'status','reserved',
    'amount_ngn',v_gross,'transfer_amount_ngn',p_amount_ngn,
    'transfer_fee_ngn',v_quote->'transfer_fee_ngn','stamp_duty_ngn',v_quote->'stamp_duty_ngn');
end $$;
revoke all on function public.request_independent_rider_withdrawal(numeric,uuid) from public,anon;
grant execute on function public.request_independent_rider_withdrawal(numeric,uuid) to authenticated;

-- Exclude independent rider deliveries from company payouts.
create or replace function public.get_my_partner_payables()
returns table(partner_id uuid,currency text,available_ngn numeric,pending_delivery_ngn numeric,
  withdrawal_pending_ngn numeric,total_paid_ngn numeric)
language sql stable security definer set search_path=pg_catalog,public as $$
  with mine as (
    select p.id from public.logistics_partners p join public.partner_users pu on pu.partner_id=p.id
    where pu.user_id=auth.uid() and public.company_staff_allowed(p.id,'withdraw') and p.status='active'
  ), fees as (
    select j.id job_id,j.partner_id,j.status,j.assigned_rider_id,j.route_assignment_issue,f.partner_cost,
      coalesce((select sum(cp.amount) from public.customer_payments cp
        where cp.job_id=j.id and cp.status='received' and cp.currency='NGN'),0) received,
      f.customer_revenue
    from public.jobs j join mine m on m.id=j.partner_id
    join public.job_financials f on f.job_id=j.id and f.currency='NGN'
    where not exists (select 1 from public.company_riders ir where ir.partner_id=j.partner_id and ir.independent_user_id=j.assigned_rider_id)
      and (j.status<>'cancelled' or exists(select 1 from public.paid_booking_cancellations pc
      where pc.job_id=j.id and pc.status='processed'))
  ), commitments as (
    select s.job_id,
      coalesce(sum(s.amount) filter (where s.status<>'cancelled'),0) committed,
      coalesce(sum(s.amount) filter (where s.status in ('pending','approved') and s.withdrawal_id is not null),0) withdrawal_pending,
      coalesce(sum(s.amount) filter (where s.status='paid'),0) paid
    from public.partner_settlements s join fees f on f.job_id=s.job_id group by s.job_id
  )
  select m.id,'NGN'::text,
    coalesce(sum(greatest(f.partner_cost-coalesce(c.committed,0),0)) filter
      (where f.status in ('delivered','closed','cancelled') and f.received>=f.customer_revenue),0)::numeric,
    coalesce(sum(f.partner_cost) filter
      (where f.status not in ('delivered','closed','cancelled') and f.received>=f.customer_revenue
        and (f.assigned_rider_id is not null or f.route_assignment_issue is null)),0)::numeric,
    coalesce(sum(c.withdrawal_pending),0)::numeric,
    coalesce(sum(c.paid),0)::numeric
  from mine m left join fees f on f.partner_id=m.id
  left join commitments c on c.job_id=f.job_id group by m.id;
$$;

-- Exclude independent rider deliveries from company payouts.
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
    if v_existing.rider_user_id is not null or v_existing.transfer_amount_ngn<>p_amount_ngn then
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
      and not exists (select 1 from public.company_riders ir where ir.partner_id=j.partner_id and ir.independent_user_id=j.assigned_rider_id)
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
