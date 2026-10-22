-- Flutterwave payout details are verified server-side and never writable by a browser.
create table public.partner_payout_accounts (
  partner_id uuid primary key references public.logistics_partners(id) on delete restrict,
  bank_code text not null check (bank_code ~ '^[0-9]{2,10}$'),
  bank_name text not null check (length(btrim(bank_name)) between 2 and 120),
  account_number text not null check (account_number ~ '^[0-9]{10}$'),
  account_name text not null check (length(btrim(account_name)) between 3 and 150),
  verified_at timestamptz not null default now(),
  verified_for_user_id uuid not null references auth.users(id) on delete restrict,
  updated_at timestamptz not null default now()
);
alter table public.partner_payout_accounts enable row level security;
revoke all on public.partner_payout_accounts from public,anon,authenticated;

-- Each provider account resolution may have a cost. Serialize and cap attempts
-- by manager across all of their companies before calling the provider.
create table public.partner_bank_resolve_attempts (
  id bigint generated always as identity primary key,
  actor_id uuid not null references auth.users(id) on delete restrict,
  partner_id uuid not null references public.logistics_partners(id) on delete restrict,
  attempted_at timestamptz not null default now()
);
create index partner_bank_resolve_attempts_actor_time_idx
  on public.partner_bank_resolve_attempts(actor_id,attempted_at desc);
alter table public.partner_bank_resolve_attempts enable row level security;
revoke all on public.partner_bank_resolve_attempts from public,anon,authenticated;

create function public.authorize_partner_bank_resolve(p_partner_id uuid,p_actor_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_used integer;
begin
  if auth.role()<>'service_role' then raise insufficient_privilege; end if;
  if not exists(select 1 from public.logistics_partners p join public.partner_users pu on pu.partner_id=p.id
    where p.id=p_partner_id and p.status='active' and pu.user_id=p_actor_id and pu.membership_role='manager') then
    raise insufficient_privilege using message='An active company manager is required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('bank-resolve:'||p_actor_id::text,0));
  select count(*) into v_used from public.partner_bank_resolve_attempts
    where actor_id=p_actor_id and attempted_at>now()-interval '15 minutes';
  if v_used>=5 then
    raise check_violation using message='Too many bank account checks. Try again in 15 minutes'; end if;
  insert into public.partner_bank_resolve_attempts(actor_id,partner_id)
    values(p_actor_id,p_partner_id);
  return jsonb_build_object('allowed',true,'remaining',4-v_used);
end $$;
revoke all on function public.authorize_partner_bank_resolve(uuid,uuid) from public,anon,authenticated;
grant execute on function public.authorize_partner_bank_resolve(uuid,uuid) to service_role;

alter table public.partner_withdrawals
  add column status text not null default 'manual'
    check(status in ('manual','reserved','initiating','queued','successful','failed','unknown')),
  add column bank_code_snapshot text,
  add column bank_name_snapshot text,
  add column account_number_snapshot text,
  add column account_name_snapshot text,
  add column transfer_reference text unique,
  add column provider_reference text unique,
  add column provider_transfer_id bigint unique,
  add column transfer_started_at timestamptz,
  add column completed_at timestamptz,
  add column provider_status text,
  add constraint automatic_withdrawal_has_beneficiary check (
    status='manual' or (bank_code_snapshot is not null and bank_name_snapshot is not null
      and account_number_snapshot is not null and account_name_snapshot is not null
      and transfer_reference is not null));

create function public.guard_partner_withdrawal_snapshot()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin
  if (new.partner_id,new.requested_by,new.amount_ngn,new.idempotency_key,
      new.bank_code_snapshot,new.bank_name_snapshot,new.account_number_snapshot,
      new.account_name_snapshot,new.transfer_reference)
     is distinct from
     (old.partner_id,old.requested_by,old.amount_ngn,old.idempotency_key,
      old.bank_code_snapshot,old.bank_name_snapshot,old.account_number_snapshot,
      old.account_name_snapshot,old.transfer_reference) then
    raise check_violation using message='Withdrawal beneficiary and amount cannot change';
  end if;
  return new;
end $$;
create trigger guard_partner_withdrawal_snapshot_update
before update on public.partner_withdrawals
for each row execute function public.guard_partner_withdrawal_snapshot();
revoke all on function public.guard_partner_withdrawal_snapshot() from public,anon,authenticated;

-- Never expose unmasked bank details through the prior manager-select policy.
revoke select on public.partner_withdrawals from authenticated;
drop policy if exists partner_withdrawals_read on public.partner_withdrawals;

create function public.save_verified_partner_payout_account(
  p_partner_id uuid,p_actor_id uuid,p_bank_code text,p_bank_name text,
  p_account_number text,p_account_name text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if auth.role()<>'service_role' then raise insufficient_privilege; end if;
  if not exists(select 1 from public.logistics_partners p join public.partner_users pu on pu.partner_id=p.id
    where p.id=p_partner_id and p.status='active' and pu.user_id=p_actor_id and pu.membership_role='manager') then
    raise insufficient_privilege using message='An active company manager is required'; end if;
  if p_bank_code !~ '^[0-9]{2,10}$' or p_account_number !~ '^[0-9]{10}$'
    or length(btrim(coalesce(p_bank_name,''))) not between 2 and 120
    or length(btrim(coalesce(p_account_name,''))) not between 3 and 150 then
    raise check_violation using message='Invalid verified bank account'; end if;
  insert into public.partner_payout_accounts(partner_id,bank_code,bank_name,account_number,
    account_name,verified_for_user_id)
  values(p_partner_id,p_bank_code,btrim(p_bank_name),p_account_number,btrim(p_account_name),p_actor_id)
  on conflict(partner_id) do update set bank_code=excluded.bank_code,bank_name=excluded.bank_name,
    account_number=excluded.account_number,account_name=excluded.account_name,
    verified_for_user_id=excluded.verified_for_user_id,verified_at=now(),updated_at=now();
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('partner_payout_account',p_partner_id,'provider_verified',p_actor_id,
      array['bank_code','bank_name','account_number','account_name']);
  return jsonb_build_object('partner_id',p_partner_id,'bank_name',btrim(p_bank_name),
    'account_name',btrim(p_account_name),'account_last4',right(p_account_number,4));
end $$;

-- A single caller may claim the outbound POST. Once claimed, a timeout must
-- be reconciled by provider reference; the POST is never automatically repeated.
create function public.claim_partner_withdrawal_transfer(p_withdrawal_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v public.partner_withdrawals%rowtype;
begin
  if auth.role()<>'service_role' then raise insufficient_privilege; end if;
  select * into v from public.partner_withdrawals where id=p_withdrawal_id for update;
  if not found then raise no_data_found using message='Withdrawal not found'; end if;
  if v.status<>'reserved' then
    return jsonb_build_object('status',v.status,'withdrawal_id',v.id,
      'reference',v.transfer_reference,'provider_transfer_id',v.provider_transfer_id);
  end if;
  update public.partner_withdrawals set status='initiating',transfer_started_at=now()
    where id=v.id;
  return jsonb_build_object('status','initiating','withdrawal_id',v.id,
    'reference',v.transfer_reference,'amount_ngn',v.amount_ngn,'currency','NGN',
    'bank_code',v.bank_code_snapshot,'bank_name',v.bank_name_snapshot,
    'account_number',v.account_number_snapshot,'account_name',v.account_name_snapshot);
end $$;
revoke all on function public.claim_partner_withdrawal_transfer(uuid) from public,anon,authenticated;
grant execute on function public.claim_partner_withdrawal_transfer(uuid) to service_role;

-- Provider acceptance is not payment. The settlement remains reserved until
-- an independent provider status lookup confirms a terminal result.
create function public.record_partner_withdrawal_transfer_attempt(
  p_withdrawal_id uuid,p_provider_transfer_id bigint,p_status text,
  p_provider_reference text default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v public.partner_withdrawals%rowtype;
begin
  if auth.role()<>'service_role' then raise insufficient_privilege; end if;
  if p_status not in ('queued','unknown') then raise invalid_parameter_value; end if;
  select * into v from public.partner_withdrawals where id=p_withdrawal_id for update;
  if not found then raise no_data_found; end if;
  if v.status in ('successful','failed') then
    return jsonb_build_object('status',v.status,'withdrawal_id',v.id); end if;
  if v.status not in ('initiating','queued','unknown') then
    raise object_not_in_prerequisite_state using message='Transfer has not been claimed'; end if;
  if p_provider_transfer_id is not null and p_provider_transfer_id<=0 then raise check_violation; end if;
  if p_provider_reference is not null and length(btrim(p_provider_reference)) not between 1 and 120 then
    raise check_violation using message='Invalid provider reference'; end if;
  if v.provider_transfer_id is not null and p_provider_transfer_id is not null
    and v.provider_transfer_id<>p_provider_transfer_id then
    raise check_violation using message='Provider transfer ID changed'; end if;
  if v.provider_reference is not null and p_provider_reference is not null
    and v.provider_reference<>p_provider_reference then
    raise check_violation using message='Provider reference changed'; end if;
  update public.partner_withdrawals set status=p_status,
    provider_transfer_id=coalesce(v.provider_transfer_id,p_provider_transfer_id),
    provider_reference=coalesce(v.provider_reference,p_provider_reference)
    where id=v.id;
  return jsonb_build_object('status',p_status,'withdrawal_id',v.id,
    'reference',v.transfer_reference);
end $$;
revoke all on function public.record_partner_withdrawal_transfer_attempt(uuid,bigint,text,text)
  from public,anon,authenticated;
grant execute on function public.record_partner_withdrawal_transfer_attempt(uuid,bigint,text,text)
  to service_role;

create function public.get_partner_withdrawal_transfer_attempt(p_withdrawal_id uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v public.partner_withdrawals%rowtype;
begin
  if auth.role()<>'service_role' then raise insufficient_privilege; end if;
  select * into v from public.partner_withdrawals where id=p_withdrawal_id;
  if not found then raise no_data_found; end if;
  return jsonb_build_object('status',v.status,'withdrawal_id',v.id,
    'reference',v.transfer_reference,'provider_reference',v.provider_reference,
    'provider_transfer_id',v.provider_transfer_id,
    'amount_ngn',v.amount_ngn,'currency','NGN','bank_code',v.bank_code_snapshot,
    'account_number',v.account_number_snapshot,'account_name',v.account_name_snapshot);
end $$;
revoke all on function public.get_partner_withdrawal_transfer_attempt(uuid) from public,anon,authenticated;
grant execute on function public.get_partner_withdrawal_transfer_attempt(uuid) to service_role;

-- Call only after fetching Flutterwave's transfer by ID or unique reference
-- and verifying all supplied fields against that authenticated response.
create function public.finish_partner_withdrawal_transfer(
  p_withdrawal_id uuid,p_provider_transfer_id bigint,p_reference text,p_provider_reference text,
  p_status text,
  p_amount_ngn numeric,p_currency text,p_bank_code text,p_account_number text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v public.partner_withdrawals%rowtype;v_sum numeric;v_count integer;
begin
  if auth.role()<>'service_role' then raise insufficient_privilege; end if;
  if p_status not in ('SUCCESSFUL','FAILED') then raise invalid_parameter_value; end if;
  select * into v from public.partner_withdrawals where id=p_withdrawal_id for update;
  if not found then raise no_data_found; end if;
  if v.status in ('successful','failed') then
    if (v.status='successful')=(p_status='SUCCESSFUL')
      and v.provider_transfer_id=p_provider_transfer_id
      and v.transfer_reference=p_reference and v.provider_reference=p_provider_reference
      and v.amount_ngn=p_amount_ngn and p_currency='NGN'
      and v.bank_code_snapshot=p_bank_code and v.account_number_snapshot=p_account_number then
      return jsonb_build_object('status',v.status,'withdrawal_id',v.id);
    end if;
    raise check_violation using message='Conflicting terminal transfer result';
  end if;
  if v.status not in ('initiating','queued','unknown') or p_provider_transfer_id is null
    or p_provider_transfer_id<=0 or p_reference is distinct from v.transfer_reference
    or nullif(btrim(coalesce(p_provider_reference,'')),'') is null
    or length(p_provider_reference)>120
    or (v.provider_reference is not null and v.provider_reference<>p_provider_reference)
    or p_amount_ngn is distinct from v.amount_ngn or p_currency<>'NGN'
    or p_bank_code is distinct from v.bank_code_snapshot
    or p_account_number is distinct from v.account_number_snapshot
    or (v.provider_transfer_id is not null and v.provider_transfer_id<>p_provider_transfer_id) then
    raise check_violation using message='Verified transfer does not match reserved withdrawal';
  end if;
  select coalesce(sum(s.amount),0),count(*) into v_sum,v_count from public.partner_settlements s
    where s.withdrawal_id=v.id and s.status='pending';
  if v_count=0 or v_sum<>v.amount_ngn then
    raise object_not_in_prerequisite_state using message='Withdrawal reservation is incomplete'; end if;
  if p_status='SUCCESSFUL' then
    update public.partner_settlements set status='paid',reference=v.transfer_reference,paid_at=now()
      where withdrawal_id=v.id and status='pending';
    update public.partner_withdrawals set status='successful',provider_status=p_status,
      provider_transfer_id=p_provider_transfer_id,provider_reference=p_provider_reference,
      completed_at=now() where id=v.id;
  else
    update public.partner_settlements set status='cancelled'
      where withdrawal_id=v.id and status='pending';
    update public.partner_withdrawals set status='failed',provider_status=p_status,
      provider_transfer_id=p_provider_transfer_id,provider_reference=p_provider_reference,
      completed_at=now() where id=v.id;
  end if;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('partner_withdrawal',v.id,lower(p_status),null,
      array['status','provider_transfer_id','transfer_reference']);
  return jsonb_build_object('status',lower(p_status),'withdrawal_id',v.id);
end $$;
revoke all on function public.finish_partner_withdrawal_transfer(uuid,bigint,text,text,text,numeric,text,text,text)
  from public,anon,authenticated;
grant execute on function public.finish_partner_withdrawal_transfer(uuid,bigint,text,text,text,numeric,text,text,text)
  to service_role;
revoke all on function public.save_verified_partner_payout_account(uuid,uuid,text,text,text,text)
  from public,anon,authenticated;
grant execute on function public.save_verified_partner_payout_account(uuid,uuid,text,text,text,text)
  to service_role;

create function public.get_my_partner_payout_account(p_partner_id uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_account public.partner_payout_accounts%rowtype;
begin
  if not exists(select 1 from public.partner_users pu where pu.partner_id=p_partner_id
    and pu.user_id=auth.uid() and pu.membership_role='manager') then
    raise insufficient_privilege using message='Company manager required'; end if;
  select * into v_account from public.partner_payout_accounts where partner_id=p_partner_id;
  if not found then return jsonb_build_object('verified',false); end if;
  return jsonb_build_object('verified',true,'bank_name',v_account.bank_name,
    'account_name',v_account.account_name,'account_last4',right(v_account.account_number,4),
    'verified_at',v_account.verified_at);
end $$;
revoke all on function public.get_my_partner_payout_account(uuid) from public,anon;
grant execute on function public.get_my_partner_payout_account(uuid) to authenticated;

-- The existing Finance UI/RPC must not mutate an automatic payout or make a
-- bank transfer claim. Only the service role may mirror provider-verified state.
create function public.guard_automatic_partner_settlement()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin
  if old.withdrawal_id is not null and auth.role()<>'service_role' then
    raise insufficient_privilege using message='Automatic withdrawals are controlled by verified provider results';
  end if;
  return new;
end $$;
create trigger guard_automatic_partner_settlement_update
before update or delete on public.partner_settlements
for each row execute function public.guard_automatic_partner_settlement();
revoke all on function public.guard_automatic_partner_settlement() from public,anon,authenticated;

create function public.list_my_partner_withdrawals(p_partner_id uuid)
returns table(withdrawal_id uuid,amount_ngn numeric,status text,bank_name text,account_last4 text,
  created_at timestamptz,completed_at timestamptz)
language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not exists(select 1 from public.partner_users pu where pu.partner_id=p_partner_id
    and pu.user_id=auth.uid() and pu.membership_role='manager') then
    raise insufficient_privilege using message='Company manager required'; end if;
  return query select w.id,w.amount_ngn,w.status,w.bank_name_snapshot,
    right(w.account_number_snapshot,4),w.created_at,w.completed_at
  from public.partner_withdrawals w where w.partner_id=p_partner_id
  order by w.created_at desc limit 50;
end $$;
revoke all on function public.list_my_partner_withdrawals(uuid) from public,anon;
grant execute on function public.list_my_partner_withdrawals(uuid) to authenticated;

create or replace function public.request_partner_withdrawal(
  p_partner_id uuid,p_amount_ngn numeric,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_actor uuid := auth.uid(); v_partner public.logistics_partners%rowtype;
  v_existing public.partner_withdrawals%rowtype; v_account public.partner_payout_accounts%rowtype;
  v_withdrawal uuid; v_transfer_reference text;
  v_job record; v_committed numeric; v_remaining numeric; v_take numeric;
  v_received numeric; v_reserved numeric := 0; v_count integer := 0;
begin
  if v_actor is null or p_partner_id is null or p_idempotency_key is null
     or p_amount_ngn is null or p_amount_ngn<=0 or p_amount_ngn<>trunc(p_amount_ngn) then
    raise check_violation using message='Enter a valid withdrawal amount';
  end if;
  select * into v_partner from public.logistics_partners where id=p_partner_id for update;
  if not found or v_partner.status<>'active' or not exists (
    select 1 from public.partner_users pu where pu.partner_id=p_partner_id
      and pu.user_id=v_actor and pu.membership_role='manager') then
    raise insufficient_privilege using message='An active company manager is required';
  end if;
  select * into v_account from public.partner_payout_accounts where partner_id=p_partner_id;
  if not found then
    raise object_not_in_prerequisite_state using message='Verify a company bank account before withdrawing';
  end if;
  select * into v_existing from public.partner_withdrawals
    where partner_id=p_partner_id and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.amount_ngn<>p_amount_ngn then
      raise check_violation using message='This withdrawal key was used for a different amount';
    end if;
    return jsonb_build_object('withdrawal_id',v_existing.id,'status',v_existing.status,
      'amount_ngn',v_existing.amount_ngn);
  end if;

  -- Snapshot the resolved beneficiary and reference before an external request.
  -- No row is committed if the requested amount cannot be fully covered.
  v_withdrawal:=gen_random_uuid();
  v_transfer_reference:='KWP-PAYOUT-'||replace(v_withdrawal::text,'-','');
  insert into public.partner_withdrawals(id,partner_id,requested_by,amount_ngn,idempotency_key,
    status,bank_code_snapshot,bank_name_snapshot,account_number_snapshot,account_name_snapshot,
    transfer_reference)
    values(v_withdrawal,p_partner_id,v_actor,p_amount_ngn,p_idempotency_key,'reserved',
      v_account.bank_code,v_account.bank_name,v_account.account_number,v_account.account_name,
      v_transfer_reference);
  v_remaining := p_amount_ngn;
  for v_job in
    select j.id, f.partner_cost, f.customer_revenue
    from public.jobs j join public.job_financials f on f.job_id=j.id
    where j.partner_id=p_partner_id and j.status in ('delivered','closed')
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
      'Automatic Flutterwave payout reserved; provider status controls paid state',v_actor,v_withdrawal);
    v_reserved := v_reserved+v_take;
    v_remaining := v_remaining-v_take;
    v_count := v_count+1;
    exit when v_remaining=0;
  end loop;
  if v_remaining<>0 then
    raise check_violation using message='Withdrawal exceeds the available company earnings';
  end if;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('partner_withdrawal',v_withdrawal,'requested',v_actor,array['partner_id','amount_ngn','job_count']);
  return jsonb_build_object('withdrawal_id',v_withdrawal,'status','reserved',
    'amount_ngn',v_reserved,'settlement_count',v_count);
end $$;
