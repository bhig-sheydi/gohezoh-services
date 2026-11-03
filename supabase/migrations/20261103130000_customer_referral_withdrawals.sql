-- Customer marketers withdraw earned referral commission, never uncompleted job value.
create table public.customer_referral_payout_accounts (
  user_id uuid primary key references public.customer_referral_members(user_id),
  bank_code text not null, bank_name text not null, account_number text not null,
  account_name text not null, verified_at timestamptz not null default now(),
  check (bank_code ~ '^[0-9]{3,8}$' and account_number ~ '^[0-9]{10}$')
);
create table public.customer_referral_withdrawals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.customer_referral_members(user_id),
  idempotency_key uuid not null, amount_ngn numeric(14,2) not null check (amount_ngn>0 and amount_ngn=trunc(amount_ngn)),
  transfer_reference text not null unique, bank_code text not null, bank_name text not null,
  account_number text not null, account_name text not null,
  status text not null default 'reserved' check (status in ('reserved','initiating','queued','unknown','successful','failed')),
  provider_transfer_id bigint unique, provider_reference text,
  created_at timestamptz not null default now(), completed_at timestamptz,
  unique(user_id,idempotency_key)
);
create index customer_referral_withdrawals_user_created on public.customer_referral_withdrawals(user_id,created_at desc);
alter table public.customer_referral_payout_accounts enable row level security;
alter table public.customer_referral_withdrawals enable row level security;
revoke all on public.customer_referral_payout_accounts,public.customer_referral_withdrawals from public,anon,authenticated;

create table public.customer_referral_bank_checks (
  id bigint generated always as identity primary key,user_id uuid not null,created_at timestamptz not null default now()
);
create index customer_referral_bank_checks_recent on public.customer_referral_bank_checks(user_id,created_at desc);
alter table public.customer_referral_bank_checks enable row level security;
revoke all on public.customer_referral_bank_checks from public,anon,authenticated;

create function public.my_referral_payout_state() returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_user uuid:=auth.uid();v_earned numeric;v_reserved numeric;v_account public.customer_referral_payout_accounts%rowtype;
begin
  if v_user is null or not exists(select 1 from public.customer_referral_members where user_id=v_user and active) then
    raise insufficient_privilege using message='Join the referral program first'; end if;
  select coalesce(sum(earned_ngn),0) into v_earned from public.customer_referral_earnings where referrer_user_id=v_user;
  select coalesce(sum(amount_ngn),0) into v_reserved from public.customer_referral_withdrawals
    where user_id=v_user and status<>'failed';
  select * into v_account from public.customer_referral_payout_accounts where user_id=v_user;
  return jsonb_build_object('available_ngn',greatest(0,v_earned-v_reserved),
    'account',case when v_account.user_id is null then null else jsonb_build_object('bank_name',v_account.bank_name,
      'account_name',v_account.account_name,'account_last4',right(v_account.account_number,4)) end,
    'withdrawals',coalesce((select jsonb_agg(jsonb_build_object('id',w.id,'amount_ngn',w.amount_ngn,'status',w.status,
      'created_at',w.created_at) order by w.created_at desc) from
      (select * from public.customer_referral_withdrawals where user_id=v_user order by created_at desc limit 20) w),'[]'::jsonb));
end $$;
revoke all on function public.my_referral_payout_state() from public,anon;
grant execute on function public.my_referral_payout_state() to authenticated;

create function public.authorize_referral_bank_check(p_user uuid) returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if auth.role()<>'service_role' then raise insufficient_privilege; end if;
  if (select count(*) from public.customer_referral_bank_checks where user_id=p_user and created_at>now()-interval '1 hour')>=5 then
    raise check_violation using message='Too many bank checks. Try again later'; end if;
  insert into public.customer_referral_bank_checks(user_id) values(p_user);
end $$;
revoke all on function public.authorize_referral_bank_check(uuid) from public,anon,authenticated;
grant execute on function public.authorize_referral_bank_check(uuid) to service_role;

create function public.save_referral_payout_account(p_user uuid,p_bank_code text,p_bank_name text,p_account_number text,p_account_name text)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if auth.role()<>'service_role' or not exists(select 1 from public.customer_referral_members where user_id=p_user and active)
    or p_bank_code !~ '^[0-9]{3,8}$' or p_account_number !~ '^[0-9]{10}$'
    or nullif(btrim(p_bank_name),'') is null or nullif(btrim(p_account_name),'') is null then raise check_violation; end if;
  if exists(select 1 from public.customer_referral_withdrawals where user_id=p_user and status in ('reserved','initiating','queued','unknown')) then
    raise object_not_in_prerequisite_state using message='Finish the pending withdrawal before changing account'; end if;
  insert into public.customer_referral_payout_accounts(user_id,bank_code,bank_name,account_number,account_name)
    values(p_user,p_bank_code,btrim(p_bank_name),p_account_number,btrim(p_account_name))
    on conflict(user_id) do update set bank_code=excluded.bank_code,bank_name=excluded.bank_name,
      account_number=excluded.account_number,account_name=excluded.account_name,verified_at=now();
end $$;
revoke all on function public.save_referral_payout_account(uuid,text,text,text,text) from public,anon,authenticated;
grant execute on function public.save_referral_payout_account(uuid,text,text,text,text) to service_role;

create function public.request_referral_withdrawal(p_amount_ngn numeric,p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_user uuid:=auth.uid();v_earned numeric;v_committed numeric;v_account public.customer_referral_payout_accounts%rowtype;
  v_id uuid;v_existing public.customer_referral_withdrawals%rowtype;
begin
  if v_user is null or p_idempotency_key is null or p_amount_ngn is null or p_amount_ngn<=0
    or p_amount_ngn<>trunc(p_amount_ngn) then raise check_violation using message='Invalid withdrawal request'; end if;
  perform 1 from public.customer_referral_members where user_id=v_user and active for update;
  if not found then raise insufficient_privilege; end if;
  select * into v_existing from public.customer_referral_withdrawals where user_id=v_user and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.amount_ngn<>p_amount_ngn then raise check_violation using message='Withdrawal key used for another amount'; end if;
    return jsonb_build_object('withdrawal_id',v_existing.id,'status',v_existing.status);
  end if;
  select * into v_account from public.customer_referral_payout_accounts where user_id=v_user;
  if not found then raise object_not_in_prerequisite_state using message='Verify a bank account first'; end if;
  select coalesce(sum(earned_ngn),0) into v_earned from public.customer_referral_earnings where referrer_user_id=v_user;
  select coalesce(sum(amount_ngn),0) into v_committed from public.customer_referral_withdrawals where user_id=v_user and status<>'failed';
  if p_amount_ngn>floor(v_earned-v_committed) then raise check_violation using message='Withdrawal exceeds available commission'; end if;
  v_id:=gen_random_uuid();
  insert into public.customer_referral_withdrawals(id,user_id,idempotency_key,amount_ngn,transfer_reference,
    bank_code,bank_name,account_number,account_name)
    values(v_id,v_user,p_idempotency_key,p_amount_ngn,'kwp-referral-'||replace(v_id::text,'-',''),
      v_account.bank_code,v_account.bank_name,v_account.account_number,v_account.account_name);
  return jsonb_build_object('withdrawal_id',v_id,'status','reserved');
end $$;
revoke all on function public.request_referral_withdrawal(numeric,uuid) from public,anon;
grant execute on function public.request_referral_withdrawal(numeric,uuid) to authenticated;

create function public.claim_referral_transfer(p_id uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v public.customer_referral_withdrawals%rowtype;
begin
  if auth.role()<>'service_role' then raise insufficient_privilege; end if;
  select * into v from public.customer_referral_withdrawals where id=p_id for update;
  if not found then raise no_data_found; end if;
  if v.status='reserved' then update public.customer_referral_withdrawals set status='initiating' where id=p_id; end if;
  return jsonb_build_object('id',v.id,'status',v.status,'reference',v.transfer_reference,
    'amount_ngn',v.amount_ngn,'bank_code',v.bank_code,'account_number',v.account_number,'account_name',v.account_name);
end $$;
revoke all on function public.claim_referral_transfer(uuid) from public,anon,authenticated;
grant execute on function public.claim_referral_transfer(uuid) to service_role;

create function public.finish_referral_transfer(p_id uuid,p_provider_id bigint,p_reference text,p_status text,
  p_amount_ngn numeric,p_bank_code text,p_account_number text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v public.customer_referral_withdrawals%rowtype;
begin
  if auth.role()<>'service_role' or p_status not in ('queued','unknown','successful','failed') then raise insufficient_privilege; end if;
  select * into v from public.customer_referral_withdrawals where id=p_id for update;
  if not found or v.transfer_reference<>p_reference or v.amount_ngn<>p_amount_ngn
    or v.bank_code<>p_bank_code or v.account_number<>p_account_number
    or (v.provider_transfer_id is not null and p_provider_id is distinct from v.provider_transfer_id) then
    raise check_violation using message='Transfer does not match reserved commission'; end if;
  if v.status in ('successful','failed') then
    if v.status=p_status and v.provider_transfer_id=p_provider_id then return jsonb_build_object('status',v.status); end if;
    raise check_violation using message='Conflicting transfer result'; end if;
  if v.status not in ('initiating','queued','unknown') then raise check_violation; end if;
  if p_status in ('successful','failed') and (p_provider_id is null or p_provider_id<=0) then raise check_violation; end if;
  update public.customer_referral_withdrawals set status=p_status,provider_transfer_id=coalesce(provider_transfer_id,p_provider_id),
    provider_reference=lower(p_reference),completed_at=case when p_status in ('successful','failed') then now() else null end where id=p_id;
  return jsonb_build_object('status',p_status);
end $$;
revoke all on function public.finish_referral_transfer(uuid,bigint,text,text,numeric,text,text) from public,anon,authenticated;
grant execute on function public.finish_referral_transfer(uuid,bigint,text,text,numeric,text,text) to service_role;

-- Preserve the provider of historical transfers while new withdrawals use Paystack.
alter table public.partner_withdrawals add column provider text not null default 'flutterwave'
  check(provider in ('flutterwave','paystack'));

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
      and pu.user_id=v_actor and public.company_staff_allowed(p_partner_id,'withdraw')) then
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
    transfer_reference,provider)
    values(v_withdrawal,p_partner_id,v_actor,p_amount_ngn,p_idempotency_key,'reserved',
      v_account.bank_code,v_account.bank_name,v_account.account_number,v_account.account_name,
      v_transfer_reference,'paystack');
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
      'Automatic Paystack payout reserved; provider status controls paid state',v_actor,v_withdrawal);
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
