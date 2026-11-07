-- A withdrawal specifies the amount the beneficiary will receive. The earned
-- balance covers that transfer, the Paystack transfer charge, and stamp duty.
-- Historical withdrawals retain their original amount and zero fee snapshot.
alter table public.partner_withdrawals
  add column transfer_amount_ngn numeric(14,2),
  add column transfer_fee_ngn numeric(14,2) not null default 0,
  add column stamp_duty_ngn numeric(14,2) not null default 0,
  add column fee_schedule text not null default 'legacy';
update public.partner_withdrawals set transfer_amount_ngn=amount_ngn;
alter table public.partner_withdrawals
  alter column transfer_amount_ngn set not null,
  add constraint partner_withdrawal_fee_breakdown check (
    transfer_amount_ngn>=0 and transfer_fee_ngn>=0 and stamp_duty_ngn>=0
    and amount_ngn=transfer_amount_ngn+transfer_fee_ngn+stamp_duty_ngn);

alter table public.customer_referral_withdrawals
  add column transfer_amount_ngn numeric(14,2),
  add column transfer_fee_ngn numeric(14,2) not null default 0,
  add column stamp_duty_ngn numeric(14,2) not null default 0,
  add column fee_schedule text not null default 'legacy';
update public.customer_referral_withdrawals set transfer_amount_ngn=amount_ngn;
alter table public.customer_referral_withdrawals
  alter column transfer_amount_ngn set not null,
  add constraint referral_withdrawal_fee_breakdown check (
    transfer_amount_ngn>=0 and transfer_fee_ngn>=0 and stamp_duty_ngn>=0
    and amount_ngn=transfer_amount_ngn+transfer_fee_ngn+stamp_duty_ngn);

-- Paystack's published Nigeria bands, as of November 2026. The schedule and
-- the quoted amounts are snapshotted so later pricing changes do not rewrite
-- an already accepted withdrawal. The transfer amount drives fee thresholds.
create function public.paystack_withdrawal_charges(p_net_amount_ngn numeric)
returns jsonb language plpgsql immutable set search_path=pg_catalog,public as $$
declare v_fee numeric;v_stamp numeric;
begin
  if p_net_amount_ngn is null or p_net_amount_ngn<>trunc(p_net_amount_ngn)
    or p_net_amount_ngn<50 or p_net_amount_ngn>10000000 then
    raise check_violation using message='Bank transfer must be between NGN 50 and NGN 10,000,000 in whole naira';
  end if;
  v_fee:=case when p_net_amount_ngn<=5000 then 10
              when p_net_amount_ngn<=50000 then 25 else 50 end;
  v_stamp:=case when p_net_amount_ngn>=10000 then 50 else 0 end;
  return jsonb_build_object('net_amount_ngn',p_net_amount_ngn,
    'transfer_fee_ngn',v_fee,'stamp_duty_ngn',v_stamp,
    'gross_amount_ngn',p_net_amount_ngn+v_fee+v_stamp,
    'fee_schedule','paystack_ng_2026_02');
end $$;
revoke all on function public.paystack_withdrawal_charges(numeric) from public,anon;
grant execute on function public.paystack_withdrawal_charges(numeric) to authenticated,service_role;

-- Given the withdrawer's gross balance, find the greatest possible net bank
-- transfer. At fee thresholds there may be a small remainder left available
-- (for example, NGN 5,011 can debit NGN 5,010 for a NGN 5,000 transfer).
create function public.quote_paystack_withdrawal(p_gross_limit_ngn numeric)
returns jsonb language plpgsql immutable set search_path=pg_catalog,public as $$
declare v_net numeric:=0;v_quote jsonb;v_gross numeric;v_limit numeric;
begin
  if p_gross_limit_ngn is null or p_gross_limit_ngn<60 then
    raise check_violation using message='At least NGN 60 is needed for a NGN 50 transfer and bank charge';
  end if;
  v_limit:=floor(p_gross_limit_ngn);
  if v_limit-10>=50 then
    v_net:=least(5000,v_limit-10);
  end if;
  if v_limit-25>=5001 then
    v_net:=greatest(v_net,least(9999,v_limit-25));
  end if;
  if v_limit-75>=10000 then
    v_net:=greatest(v_net,least(50000,v_limit-75));
  end if;
  if v_limit-100>=50001 then
    v_net:=greatest(v_net,least(10000000,v_limit-100));
  end if;
  v_quote:=public.paystack_withdrawal_charges(v_net);
  v_gross:=(v_quote->>'gross_amount_ngn')::numeric;
  return v_quote||jsonb_build_object('remainder_ngn',p_gross_limit_ngn-v_gross);
end $$;
revoke all on function public.quote_paystack_withdrawal(numeric) from public,anon;
grant execute on function public.quote_paystack_withdrawal(numeric) to authenticated,service_role;

-- Fee fields are financial snapshots, not status fields.
create or replace function public.guard_partner_withdrawal_snapshot()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin
  if (new.partner_id,new.requested_by,new.amount_ngn,new.transfer_amount_ngn,
      new.transfer_fee_ngn,new.stamp_duty_ngn,new.fee_schedule,new.idempotency_key,
      new.bank_code_snapshot,new.bank_name_snapshot,new.account_number_snapshot,
      new.account_name_snapshot,new.transfer_reference)
     is distinct from
     (old.partner_id,old.requested_by,old.amount_ngn,old.transfer_amount_ngn,
      old.transfer_fee_ngn,old.stamp_duty_ngn,old.fee_schedule,old.idempotency_key,
      old.bank_code_snapshot,old.bank_name_snapshot,old.account_number_snapshot,
      old.account_name_snapshot,old.transfer_reference) then
    raise check_violation using message='Withdrawal beneficiary and financial breakdown cannot change';
  end if;
  return new;
end $$;

create function public.guard_referral_withdrawal_snapshot()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin
  if (new.user_id,new.idempotency_key,new.amount_ngn,new.transfer_amount_ngn,
      new.transfer_fee_ngn,new.stamp_duty_ngn,new.fee_schedule,new.transfer_reference,
      new.bank_code,new.bank_name,new.account_number,new.account_name)
     is distinct from
     (old.user_id,old.idempotency_key,old.amount_ngn,old.transfer_amount_ngn,
      old.transfer_fee_ngn,old.stamp_duty_ngn,old.fee_schedule,old.transfer_reference,
      old.bank_code,old.bank_name,old.account_number,old.account_name) then
    raise check_violation using message='Referral withdrawal beneficiary and financial breakdown cannot change';
  end if;
  return new;
end $$;
create trigger guard_referral_withdrawal_snapshot_update
  before update on public.customer_referral_withdrawals
  for each row execute function public.guard_referral_withdrawal_snapshot();
revoke all on function public.guard_referral_withdrawal_snapshot() from public,anon,authenticated;

create or replace function public.request_referral_withdrawal(p_amount_ngn numeric,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_user uuid:=auth.uid();v_earned numeric;v_committed numeric;
  v_account public.customer_referral_payout_accounts%rowtype;
  v_id uuid;v_existing public.customer_referral_withdrawals%rowtype;
  v_quote jsonb;v_gross numeric;
begin
  if v_user is null or p_idempotency_key is null then
    raise check_violation using message='Invalid withdrawal request'; end if;
  perform 1 from public.customer_referral_members where user_id=v_user and active for update;
  if not found then raise insufficient_privilege; end if;
  v_quote:=public.paystack_withdrawal_charges(p_amount_ngn);
  v_gross:=(v_quote->>'gross_amount_ngn')::numeric;
  select * into v_existing from public.customer_referral_withdrawals
    where user_id=v_user and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.transfer_amount_ngn<>p_amount_ngn then
      raise check_violation using message='Withdrawal key used for another bank transfer amount'; end if;
    return jsonb_build_object('withdrawal_id',v_existing.id,'status',v_existing.status,
      'amount_ngn',v_existing.amount_ngn,'transfer_amount_ngn',v_existing.transfer_amount_ngn,
      'transfer_fee_ngn',v_existing.transfer_fee_ngn,'stamp_duty_ngn',v_existing.stamp_duty_ngn);
  end if;
  select * into v_account from public.customer_referral_payout_accounts where user_id=v_user;
  if not found then raise object_not_in_prerequisite_state using message='Verify a bank account first'; end if;
  select coalesce(sum(earned_ngn),0) into v_earned from public.customer_referral_earnings where referrer_user_id=v_user;
  select coalesce(sum(amount_ngn),0) into v_committed from public.customer_referral_withdrawals
    where user_id=v_user and status<>'failed';
  if v_gross>floor(v_earned-v_committed) then
    raise check_violation using message='Bank transfer and charges exceed available commission'; end if;
  v_id:=gen_random_uuid();
  insert into public.customer_referral_withdrawals(id,user_id,idempotency_key,amount_ngn,
    transfer_amount_ngn,transfer_fee_ngn,stamp_duty_ngn,fee_schedule,transfer_reference,
    bank_code,bank_name,account_number,account_name)
    values(v_id,v_user,p_idempotency_key,v_gross,p_amount_ngn,
      (v_quote->>'transfer_fee_ngn')::numeric,(v_quote->>'stamp_duty_ngn')::numeric,
      v_quote->>'fee_schedule','kwp-referral-'||replace(v_id::text,'-',''),
      v_account.bank_code,v_account.bank_name,v_account.account_number,v_account.account_name);
  return jsonb_build_object('withdrawal_id',v_id,'status','reserved',
    'amount_ngn',v_gross,'transfer_amount_ngn',p_amount_ngn,
    'transfer_fee_ngn',v_quote->'transfer_fee_ngn','stamp_duty_ngn',v_quote->'stamp_duty_ngn');
end $$;

create or replace function public.my_referral_payout_state() returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_user uuid:=auth.uid();v_earned numeric;v_reserved numeric;
  v_account public.customer_referral_payout_accounts%rowtype;
begin
  if v_user is null or not exists(select 1 from public.customer_referral_members where user_id=v_user and active) then
    raise insufficient_privilege using message='Join the referral program first'; end if;
  select coalesce(sum(earned_ngn),0) into v_earned from public.customer_referral_earnings where referrer_user_id=v_user;
  select coalesce(sum(amount_ngn),0) into v_reserved from public.customer_referral_withdrawals
    where user_id=v_user and status<>'failed';
  select * into v_account from public.customer_referral_payout_accounts where user_id=v_user;
  return jsonb_build_object('available_ngn',greatest(0,v_earned-v_reserved),
    'account',case when v_account.user_id is null then null else jsonb_build_object(
      'bank_name',v_account.bank_name,'account_name',v_account.account_name,
      'account_last4',right(v_account.account_number,4)) end,
    'withdrawals',coalesce((select jsonb_agg(jsonb_build_object('id',w.id,
      'amount_ngn',w.amount_ngn,'transfer_amount_ngn',w.transfer_amount_ngn,
      'transfer_fee_ngn',w.transfer_fee_ngn,'stamp_duty_ngn',w.stamp_duty_ngn,
      'status',w.status,'created_at',w.created_at) order by w.created_at desc)
      from (select * from public.customer_referral_withdrawals where user_id=v_user
        order by created_at desc limit 20) w),'[]'::jsonb));
end $$;

create or replace function public.claim_referral_transfer(p_id uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v public.customer_referral_withdrawals%rowtype;
begin
  if auth.role()<>'service_role' then raise insufficient_privilege; end if;
  select * into v from public.customer_referral_withdrawals where id=p_id for update;
  if not found then raise no_data_found; end if;
  if v.status='reserved' then update public.customer_referral_withdrawals set status='initiating' where id=p_id; end if;
  return jsonb_build_object('id',v.id,'status',v.status,'reference',v.transfer_reference,
    'amount_ngn',v.amount_ngn,'transfer_amount_ngn',v.transfer_amount_ngn,
    'transfer_fee_ngn',v.transfer_fee_ngn,'stamp_duty_ngn',v.stamp_duty_ngn,
    'bank_code',v.bank_code,'account_number',v.account_number,'account_name',v.account_name);
end $$;

create or replace function public.finish_referral_transfer(p_id uuid,p_provider_id bigint,p_reference text,p_status text,
  p_amount_ngn numeric,p_bank_code text,p_account_number text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v public.customer_referral_withdrawals%rowtype;
begin
  if auth.role()<>'service_role' or p_status not in ('queued','unknown','successful','failed') then
    raise insufficient_privilege; end if;
  select * into v from public.customer_referral_withdrawals where id=p_id for update;
  if not found or v.transfer_reference<>p_reference or v.transfer_amount_ngn<>p_amount_ngn
    or v.bank_code<>p_bank_code or v.account_number<>p_account_number
    or (v.provider_transfer_id is not null and p_provider_id is distinct from v.provider_transfer_id) then
    raise check_violation using message='Transfer does not match reserved commission'; end if;
  if v.status in ('successful','failed') then
    if v.status=p_status and v.provider_transfer_id=p_provider_id then
      return jsonb_build_object('status',v.status); end if;
    raise check_violation using message='Conflicting transfer result'; end if;
  if v.status not in ('initiating','queued','unknown') then raise check_violation; end if;
  if p_status in ('successful','failed') and (p_provider_id is null or p_provider_id<=0) then raise check_violation; end if;
  update public.customer_referral_withdrawals set status=p_status,
    provider_transfer_id=coalesce(provider_transfer_id,p_provider_id),
    provider_reference=lower(p_reference),
    completed_at=case when p_status in ('successful','failed') then now() else null end where id=p_id;
  return jsonb_build_object('status',p_status);
end $$;

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

create or replace function public.claim_partner_withdrawal_transfer(p_withdrawal_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v public.partner_withdrawals%rowtype;
begin
  if auth.role()<>'service_role' then raise insufficient_privilege; end if;
  select * into v from public.partner_withdrawals where id=p_withdrawal_id for update;
  if not found then raise no_data_found using message='Withdrawal not found'; end if;
  if v.status='reserved' then
    update public.partner_withdrawals set status='initiating',transfer_started_at=now() where id=v.id;
  end if;
  return jsonb_build_object('status',case when v.status='reserved' then 'initiating' else v.status end,
    'withdrawal_id',v.id,
    'reference',v.transfer_reference,'amount_ngn',v.amount_ngn,
    'transfer_amount_ngn',v.transfer_amount_ngn,'transfer_fee_ngn',v.transfer_fee_ngn,
    'stamp_duty_ngn',v.stamp_duty_ngn,'provider_transfer_id',v.provider_transfer_id,
    'currency','NGN') || case when v.status='reserved' then jsonb_build_object(
      'bank_code',v.bank_code_snapshot,'bank_name',v.bank_name_snapshot,
      'account_number',v.account_number_snapshot,'account_name',v.account_name_snapshot)
    else '{}'::jsonb end;
end $$;

create or replace function public.get_partner_withdrawal_transfer_attempt(p_withdrawal_id uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v public.partner_withdrawals%rowtype;
begin
  if auth.role()<>'service_role' then raise insufficient_privilege; end if;
  select * into v from public.partner_withdrawals where id=p_withdrawal_id;
  if not found then raise no_data_found; end if;
  return jsonb_build_object('status',v.status,'withdrawal_id',v.id,
    'reference',v.transfer_reference,'provider_reference',v.provider_reference,
    'provider_transfer_id',v.provider_transfer_id,
    'amount_ngn',v.amount_ngn,'transfer_amount_ngn',v.transfer_amount_ngn,
    'transfer_fee_ngn',v.transfer_fee_ngn,'stamp_duty_ngn',v.stamp_duty_ngn,
    'currency','NGN','bank_code',v.bank_code_snapshot,
    'account_number',v.account_number_snapshot,'account_name',v.account_name_snapshot);
end $$;

-- The provider confirms the NET bank transfer. Settlements still account for
-- the entire gross debit, which includes the snapshotted charges.
create or replace function public.finish_partner_withdrawal_transfer(
  p_withdrawal_id uuid,p_provider_transfer_id bigint,p_reference text,p_provider_reference text,
  p_status text,p_amount_ngn numeric,p_currency text,p_bank_code text,p_account_number text)
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
      and v.transfer_amount_ngn=p_amount_ngn and p_currency='NGN'
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
    or p_amount_ngn is distinct from v.transfer_amount_ngn or p_currency<>'NGN'
    or p_bank_code is distinct from v.bank_code_snapshot
    or p_account_number is distinct from v.account_number_snapshot
    or (v.provider_transfer_id is not null and v.provider_transfer_id<>p_provider_transfer_id) then
    raise check_violation using message='Verified transfer does not match reserved bank transfer';
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

-- Recreate with additional auditable amounts; existing callers selecting the
-- original columns still receive them unchanged.
drop function public.list_my_partner_withdrawals(uuid);
create function public.list_my_partner_withdrawals(p_partner_id uuid)
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
  from public.partner_withdrawals w where w.partner_id=p_partner_id
  order by w.created_at desc limit 50;
end $$;
revoke all on function public.list_my_partner_withdrawals(uuid) from public,anon;
grant execute on function public.list_my_partner_withdrawals(uuid) to authenticated;
