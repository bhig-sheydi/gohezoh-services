-- Company operations staff have one phone and one desktop credential, scoped to one partner.
create table public.company_operations_staff (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid not null references public.logistics_partners(id),
  user_id uuid unique references auth.users(id) on delete set null,
  full_name text not null check(length(btrim(full_name)) between 3 and 120),
  password_salt text,
  password_hash text,
  password_fingerprint text unique,
  auth_secret_seed text,
  can_bid boolean not null default false,
  can_manage_riders boolean not null default false,
  can_withdraw boolean not null default false,
  failed_attempts integer not null default 0,
  device_mismatch_attempts integer not null default 0,
  password_revoked_at timestamptz,
  revoked_at timestamptz,
  session_not_before timestamptz not null default 'epoch',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index company_operations_staff_partner_idx on public.company_operations_staff(partner_id) where revoked_at is null;
alter table public.company_operations_staff enable row level security;
revoke all on public.company_operations_staff from public,anon,authenticated;

create table public.company_operations_staff_devices (
  staff_id uuid not null references public.company_operations_staff(id) on delete cascade,
  kind text not null check(kind in ('phone','desktop')),
  public_key jsonb not null,
  label text,
  bound_at timestamptz not null default now(),
  challenge text,
  challenge_expires_at timestamptz,
  primary key(staff_id,kind)
);
alter table public.company_operations_staff_devices enable row level security;
revoke all on public.company_operations_staff_devices from public,anon,authenticated;

-- Synthetic password-only users must never become customer accounts.
create or replace function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_role text;
begin
  insert into public.profiles(user_id,full_name,email,phone)
  values(new.id,nullif(new.raw_user_meta_data->>'full_name',''),new.email,new.phone)
  on conflict(user_id) do nothing;
  if new.raw_user_meta_data->>'account_kind'='company_operator' then return new; end if;
  if new.raw_user_meta_data->>'account_kind'='staff' then
    v_role:=new.raw_user_meta_data->>'requested_role';
    if v_role not in ('operations','finance','bdo','warehouse','partner','management') then
      raise check_violation using message='Choose a valid staff category'; end if;
    insert into public.staff_applications(user_id,requested_role,organization_name)
    values(new.id,v_role::public.app_role,nullif(btrim(new.raw_user_meta_data->>'organization_name'),''));
  else
    insert into public.user_roles(user_id,role) values(new.id,'customer') on conflict do nothing;
  end if;
  return new;
end $$;

create function public.company_staff_allowed(p_partner_id uuid,p_permission text)
returns boolean language sql stable security definer set search_path=pg_catalog,public,auth as $$
  select exists(select 1 from public.partner_users pu join public.logistics_partners p on p.id=pu.partner_id
    where pu.partner_id=p_partner_id and pu.user_id=auth.uid() and pu.membership_role='manager' and p.status='active')
  or exists(select 1 from public.company_operations_staff s join public.logistics_partners p on p.id=s.partner_id
    join auth.sessions sess on sess.user_id=s.user_id and sess.id=(auth.jwt()->>'session_id')::uuid
      and sess.created_at>=s.session_not_before
    where s.partner_id=p_partner_id and s.user_id=auth.uid() and p.status='active'
      and s.revoked_at is null and s.password_revoked_at is null
      and case p_permission when 'bid' then s.can_bid when 'riders' then s.can_manage_riders
        when 'withdraw' then s.can_withdraw when 'overview' then (s.can_bid or s.can_manage_riders or s.can_withdraw) else false end);
$$;
revoke all on function public.company_staff_allowed(uuid,text) from public,anon;
grant execute on function public.company_staff_allowed(uuid,text) to authenticated;

-- Service-only checks still use the user's current auth session, passed from a verified token.
create function public.company_staff_actor_allowed(p_partner_id uuid,p_actor_id uuid,p_session_id uuid,p_permission text)
returns boolean language sql stable security definer set search_path=pg_catalog,public,auth as $$
  select exists(select 1 from public.partner_users pu join public.logistics_partners p on p.id=pu.partner_id
    where pu.partner_id=p_partner_id and pu.user_id=p_actor_id and pu.membership_role='manager' and p.status='active')
  or exists(select 1 from public.company_operations_staff s join public.logistics_partners p on p.id=s.partner_id
    join auth.sessions sess on sess.user_id=s.user_id and sess.id=p_session_id
      and sess.created_at>=s.session_not_before
    where s.partner_id=p_partner_id and s.user_id=p_actor_id and p.status='active'
      and s.revoked_at is null and s.password_revoked_at is null
      and case p_permission when 'bid' then s.can_bid when 'riders' then s.can_manage_riders
        when 'withdraw' then s.can_withdraw when 'overview' then (s.can_bid or s.can_manage_riders or s.can_withdraw) else false end);
$$;
revoke all on function public.company_staff_actor_allowed(uuid,uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.company_staff_actor_allowed(uuid,uuid,uuid,text) to service_role;

create function public.my_company_operations_staff()
returns table(staff_id uuid,partner_id uuid,full_name text,can_bid boolean,can_manage_riders boolean,can_withdraw boolean)
language sql stable security definer set search_path=pg_catalog,public,auth as $$
  select s.id,s.partner_id,s.full_name,s.can_bid,s.can_manage_riders,s.can_withdraw
  from public.company_operations_staff s join public.logistics_partners p on p.id=s.partner_id and p.status='active'
    join auth.sessions sess on sess.user_id=s.user_id
    and sess.id=(auth.jwt()->>'session_id')::uuid and sess.created_at>=s.session_not_before
  where s.user_id=auth.uid() and s.revoked_at is null and s.password_revoked_at is null;
$$;
revoke all on function public.my_company_operations_staff() from public,anon;
grant execute on function public.my_company_operations_staff() to authenticated;

-- Only bidding-enabled staff inherit the broad partner-read policies used by the bid screen.
create or replace function public.is_partner_user(_partner_id uuid)
returns boolean language sql stable security definer set search_path=pg_catalog,public,auth as $$
  select public.has_role(auth.uid(),'partner') and exists(
    select 1 from public.partner_users pu where pu.partner_id=_partner_id and pu.user_id=auth.uid()
      and pu.membership_role='manager');
$$;

-- Company staff cannot modify their own privileges, roster or user role.
create function public.company_operations_staff_guard() returns trigger
language plpgsql set search_path=pg_catalog,public as $$
begin
  if auth.role()<>'service_role' then raise insufficient_privilege using message='Company staff access is managed by the company owner'; end if;
  return new;
end $$;
create trigger company_operations_staff_guard_write before insert or update or delete on public.company_operations_staff
for each row execute function public.company_operations_staff_guard();
create trigger company_operations_staff_devices_guard_write before insert or update or delete on public.company_operations_staff_devices
for each row execute function public.company_operations_staff_guard();
revoke all on function public.company_operations_staff_guard() from public,anon,authenticated;

-- Scoped company-staff access to my_partner_company_welcome.
create or replace function public.my_partner_company_welcome(p_day_start timestamptz,p_day_end timestamptz)
returns table(partner_id uuid,partner_name text,ceo_name text,logo_path text,earnings_ngn numeric)
language plpgsql stable security definer set search_path=pg_catalog,public,auth as $$
begin
  if auth.uid() is null or p_day_start is null or p_day_end is null or p_day_end<=p_day_start
     or p_day_end-p_day_start>interval '26 hours' then
    raise invalid_parameter_value using message='Invalid local day';
  end if;
  return query
  select p.id,p.partner_name,p.contact_person,p.logo_path,
    coalesce((select sum(f.partner_cost) from public.jobs j
      join public.job_financials f on f.job_id=j.id and f.currency='NGN'
      where j.partner_id=p.id and j.status in ('delivered','closed')
        and exists(select 1 from public.job_status_history h where h.job_id=j.id
          and h.new_status='delivered' and h.changed_at>=p_day_start and h.changed_at<p_day_end)
        and (select coalesce(sum(cp.amount),0) from public.customer_payments cp
          where cp.job_id=j.id and cp.status='received' and cp.currency='NGN')>=f.customer_revenue),0)::numeric
  from public.partner_users pu join public.logistics_partners p on p.id=pu.partner_id
  where pu.user_id=auth.uid() and public.company_staff_allowed(p.id,'overview')
  order by p.partner_name;
end $$;

-- Scoped company-staff access to get_my_partner_payables.
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
    where j.status<>'cancelled'
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
      (where f.status in ('delivered','closed') and f.received>=f.customer_revenue),0)::numeric,
    coalesce(sum(f.partner_cost) filter
      (where f.status not in ('delivered','closed') and f.received>=f.customer_revenue),0)::numeric,
    coalesce(sum(c.withdrawal_pending),0)::numeric,
    coalesce(sum(c.paid),0)::numeric
  from mine m left join fees f on f.partner_id=m.id
  left join commitments c on c.job_id=f.job_id
  group by m.id;
$$;

-- Scoped company-staff access to list_my_partner_withdrawals.
create or replace function public.list_my_partner_withdrawals(p_partner_id uuid)
returns table(withdrawal_id uuid,amount_ngn numeric,status text,bank_name text,account_last4 text,
  created_at timestamptz,completed_at timestamptz)
language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not exists(select 1 from public.partner_users pu where pu.partner_id=p_partner_id
    and pu.user_id=auth.uid() and public.company_staff_allowed(p_partner_id,'withdraw')) then
    raise insufficient_privilege using message='Company manager required'; end if;
  return query select w.id,w.amount_ngn,w.status,w.bank_name_snapshot,
    right(w.account_number_snapshot,4),w.created_at,w.completed_at
  from public.partner_withdrawals w where w.partner_id=p_partner_id
  order by w.created_at desc limit 50;
end $$;

-- Scoped company-staff access to get_my_partner_payout_account.
create or replace function public.get_my_partner_payout_account(p_partner_id uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_account public.partner_payout_accounts%rowtype;
begin
  if not exists(select 1 from public.partner_users pu where pu.partner_id=p_partner_id
    and pu.user_id=auth.uid() and public.company_staff_allowed(p_partner_id,'withdraw')) then
    raise insufficient_privilege using message='Company manager required'; end if;
  select * into v_account from public.partner_payout_accounts where partner_id=p_partner_id;
  if not found then return jsonb_build_object('verified',false); end if;
  return jsonb_build_object('verified',true,'bank_name',v_account.bank_name,
    'account_name',v_account.account_name,'account_last4',right(v_account.account_number,4),
    'verified_at',v_account.verified_at);
end $$;

-- Scoped company-staff access to request_partner_withdrawal.
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

create table public.company_operations_staff_alerts (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid not null references public.logistics_partners(id),
  staff_id uuid not null references public.company_operations_staff(id),
  message text not null,
  created_at timestamptz not null default now()
);
create index company_operations_staff_alerts_partner_idx on public.company_operations_staff_alerts(partner_id,created_at desc);
alter table public.company_operations_staff_alerts enable row level security;
revoke all on public.company_operations_staff_alerts from public,anon,authenticated;

create or replace function public.company_staff_actor_permission(p_partner_id uuid,p_actor_id uuid,p_permission text)
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
  select exists(select 1 from public.partner_users pu join public.logistics_partners p on p.id=pu.partner_id
    where pu.partner_id=p_partner_id and pu.user_id=p_actor_id and pu.membership_role='manager' and p.status='active')
  or exists(select 1 from public.company_operations_staff s join public.logistics_partners p on p.id=s.partner_id
    where s.partner_id=p_partner_id and s.user_id=p_actor_id and p.status='active'
      and s.revoked_at is null and s.password_revoked_at is null
      and case p_permission when 'bid' then s.can_bid when 'riders' then s.can_manage_riders
        when 'withdraw' then s.can_withdraw when 'overview' then (s.can_bid or s.can_manage_riders or s.can_withdraw) else false end);
$$;
revoke all on function public.company_staff_actor_permission(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.company_staff_actor_permission(uuid,uuid,text) to service_role;

-- Owner-only roster avoids exposing password hashes through PostgREST.
create function public.list_my_company_operations_staff(p_partner_id uuid)
returns table(staff_id uuid,full_name text,can_bid boolean,can_manage_riders boolean,
  can_withdraw boolean,password_revoked_at timestamptz,revoked_at timestamptz,
  phone_label text,desktop_label text)
language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not exists(select 1 from public.partner_users pu where pu.partner_id=p_partner_id
    and pu.user_id=auth.uid() and pu.membership_role='manager') then raise insufficient_privilege; end if;
  return query select s.id,s.full_name,s.can_bid,s.can_manage_riders,s.can_withdraw,
    s.password_revoked_at,s.revoked_at,
    (select d.label from public.company_operations_staff_devices d where d.staff_id=s.id and d.kind='phone'),
    (select d.label from public.company_operations_staff_devices d where d.staff_id=s.id and d.kind='desktop')
    from public.company_operations_staff s where s.partner_id=p_partner_id order by s.created_at desc;
end $$;
revoke all on function public.list_my_company_operations_staff(uuid) from public,anon;
grant execute on function public.list_my_company_operations_staff(uuid) to authenticated;

create function public.list_my_company_operations_staff_alerts(p_partner_id uuid)
returns table(staff_id uuid,message text,created_at timestamptz)
language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not exists(select 1 from public.partner_users pu where pu.partner_id=p_partner_id
    and pu.user_id=auth.uid() and pu.membership_role='manager') then raise insufficient_privilege; end if;
  return query select a.staff_id,a.message,a.created_at from public.company_operations_staff_alerts a
    where a.partner_id=p_partner_id order by a.created_at desc limit 20;
end $$;
revoke all on function public.list_my_company_operations_staff_alerts(uuid) from public,anon;
grant execute on function public.list_my_company_operations_staff_alerts(uuid) to authenticated;

create or replace function public.authorize_partner_bank_resolve(p_partner_id uuid,p_actor_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_used integer;
begin
  if auth.role()<>'service_role' then raise insufficient_privilege; end if;
  if not exists(select 1 from public.logistics_partners p join public.partner_users pu on pu.partner_id=p.id
    where p.id=p_partner_id and p.status='active' and pu.user_id=p_actor_id and public.company_staff_actor_permission(p_partner_id,p_actor_id,'withdraw')) then
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

create or replace function public.save_verified_partner_payout_account(
  p_partner_id uuid,p_actor_id uuid,p_bank_code text,p_bank_name text,
  p_account_number text,p_account_name text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if auth.role()<>'service_role' then raise insufficient_privilege; end if;
  if not exists(select 1 from public.logistics_partners p join public.partner_users pu on pu.partner_id=p.id
    where p.id=p_partner_id and p.status='active' and pu.user_id=p_actor_id and public.company_staff_actor_permission(p_partner_id,p_actor_id,'withdraw')) then
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

create or replace function public.company_rider_upload_allowed(p_path text) returns boolean
language sql stable security definer set search_path=pg_catalog,public,auth as $$
  select exists(select 1 from public.partner_users pu join public.logistics_partners p on p.id=pu.partner_id
    where pu.user_id=auth.uid() and public.company_staff_allowed(pu.partner_id,'riders') and p.status='active'
    and split_part(p_path,'/',1)=pu.partner_id::text
    and split_part(p_path,'/',2)=auth.uid()::text
    and split_part(p_path,'/',3)<>'' and split_part(p_path,'/',4)='');
$$;

create or replace function public.register_company_rider(p_partner_id uuid,p_full_name text,p_nin text,
  p_nin_document_path text,p_licence_document_path text,p_photo_path text default null)
returns uuid language plpgsql security definer set search_path=pg_catalog,public,auth,storage as $$
declare v_path text; v_id uuid;
begin
  if not exists(select 1 from public.partner_users pu join public.logistics_partners p on p.id=pu.partner_id
    where pu.partner_id=p_partner_id and pu.user_id=auth.uid() and public.company_staff_allowed(pu.partner_id,'riders') and p.status='active') then
    raise insufficient_privilege using message='Company manager access required'; end if;
  if length(btrim(p_full_name)) not between 3 and 120 or p_nin !~ '^[0-9]{11}$' then
    raise check_violation using message='Enter a full name and an 11-digit NIN'; end if;
  foreach v_path in array array[p_nin_document_path,p_licence_document_path,p_photo_path] loop
    if v_path is not null and (not public.company_rider_upload_allowed(v_path) or not exists(
      select 1 from storage.objects o where o.bucket_id='rider-evidence' and o.name=v_path
        and o.owner_id=auth.uid()::text
        and o.metadata->>'mimetype' in ('application/pdf','image/jpeg','image/png','image/webp')
        and case when o.metadata->>'size' ~ '^[0-9]+$' then (o.metadata->>'size')::bigint between 1 and 5242880 else false end)) then
      raise check_violation using message='Upload valid rider documents under 5 MB'; end if;
  end loop;
  if p_nin_document_path is null or p_licence_document_path is null or p_nin_document_path=p_licence_document_path then
    raise check_violation using message='NIN and licence documents are required'; end if;
  insert into public.company_riders(partner_id,full_name,nin,nin_document_path,licence_document_path,photo_path)
  values(p_partner_id,btrim(p_full_name),p_nin,p_nin_document_path,p_licence_document_path,p_photo_path)
  returning id into v_id;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
  values('company_rider',v_id,'submitted',auth.uid(),array['nin_document_path','licence_document_path']);
  return v_id;
end $$;

create or replace function public.archive_company_rider(p_rider_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public,auth as $$
declare v_partner uuid;
begin
  select partner_id into v_partner from public.company_riders where id=p_rider_id for update;
  if v_partner is null or not exists(select 1 from public.partner_users
    where partner_id=v_partner and user_id=auth.uid() and public.company_staff_allowed(v_partner,'riders')) then
    raise insufficient_privilege using message='Company manager access required'; end if;
  update public.company_riders set status='archived',archived_at=now() where id=p_rider_id and status<>'archived';
  update public.rider_credentials set revoked_at=now(),challenge=null,challenge_expires_at=null
    where roster_id=p_rider_id and revoked_at is null;
  delete from public.partner_users where partner_id=v_partner and user_id in
    (select user_id from public.rider_credentials where roster_id=p_rider_id);
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
  values('company_rider',p_rider_id,'archived',auth.uid(),array['status','revoked_at']);
end $$;

create or replace function public.set_company_rider_photo(p_rider_id uuid,p_photo_path text)
returns void language plpgsql security definer set search_path=pg_catalog,public,auth,storage as $$
declare v_partner uuid;
begin
  select partner_id into v_partner from public.company_riders where id=p_rider_id;
  if v_partner is null or not exists(select 1 from public.partner_users where partner_id=v_partner
    and user_id=auth.uid() and public.company_staff_allowed(v_partner,'riders')) then
    raise insufficient_privilege using message='Company manager access required'; end if;
  if not public.company_rider_upload_allowed(p_photo_path) or not exists(select 1 from storage.objects o
    where o.bucket_id='rider-evidence' and o.name=p_photo_path and o.owner_id=auth.uid()::text
    and o.metadata->>'mimetype' in ('image/jpeg','image/png','image/webp')) then
    raise check_violation using message='Upload a valid rider photo first'; end if;
  update public.company_riders set photo_path=p_photo_path where id=p_rider_id and status<>'archived';
end $$;

drop policy company_rider_read on public.company_riders;
create policy company_rider_read on public.company_riders for select to authenticated using (
  public.has_role(auth.uid(),'admin') or public.company_staff_allowed(partner_id,'riders'));
drop policy rider_evidence_read on storage.objects;
create policy rider_evidence_read on storage.objects for select to authenticated using (
  bucket_id='rider-evidence' and exists(select 1 from public.company_riders r
    where name in (r.nin_document_path,r.licence_document_path,r.photo_path)
      and (public.has_role(auth.uid(),'admin') or public.company_staff_allowed(r.partner_id,'riders'))));

create or replace function public.set_company_rider_phone(p_rider_id uuid,p_phone text) returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if p_phone !~ '^\+?[0-9]{10,15}$' then
    raise check_violation using message='Enter a valid rider phone number'; end if;
  update public.company_riders r set phone=p_phone
  where r.id=p_rider_id and r.status<>'archived' and public.company_staff_allowed(r.partner_id,'riders');
  if not found then raise insufficient_privilege using message='Rider-management permission required'; end if;
end $$;

-- Serialize failed attempts so concurrent guesses cannot bypass the four-attempt rule.
create function public.record_company_staff_auth_failure(p_staff_id uuid,p_device_mismatch boolean)
returns integer language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_staff public.company_operations_staff%rowtype;v_count integer;
begin
  if auth.role()<>'service_role' then raise insufficient_privilege; end if;
  select * into v_staff from public.company_operations_staff where id=p_staff_id for update;
  if not found or v_staff.revoked_at is not null or v_staff.password_revoked_at is not null then return 4; end if;
  v_count:=case when p_device_mismatch then v_staff.device_mismatch_attempts else v_staff.failed_attempts end+1;
  update public.company_operations_staff set
    device_mismatch_attempts=case when p_device_mismatch then v_count else device_mismatch_attempts end,
    failed_attempts=case when p_device_mismatch then failed_attempts else v_count end,
    password_revoked_at=case when v_count>3 then now() else password_revoked_at end,
    updated_at=now() where id=p_staff_id;
  if v_count>3 then
    insert into public.company_operations_staff_alerts(partner_id,staff_id,message)
    values(v_staff.partner_id,p_staff_id,
      'Possible unauthorized access to '||v_staff.full_name||'. Password revoked after four failed attempts.');
  end if;
  return v_count;
end $$;
revoke all on function public.record_company_staff_auth_failure(uuid,boolean) from public,anon,authenticated;
grant execute on function public.record_company_staff_auth_failure(uuid,boolean) to service_role;

-- Bid-only operation: list_company_bid_pickups.
create or replace function public.list_company_bid_pickups()
returns table(request_id uuid,pickup_address text,sender_name text,sender_phone text,
  latitude double precision,longitude double precision,location_source text,nearby_rider_name text,distance_metres double precision)
language sql stable security definer set search_path=pg_catalog,public as $$
  select r.id,r.pickup_address,r.sender_name,r.sender_phone,r.pickup_latitude,r.pickup_longitude,r.pickup_location_source,
    rc.rider_name,i.distance_metres
  from public.company_bid_invitations i join public.service_requests r on r.id=i.request_id
  join public.delivery_quote_windows w on w.request_id=r.id and w.status='open' and w.deadline_at>now()
  join public.rider_credentials rc on rc.user_id=i.rider_id
  where public.company_staff_allowed(i.partner_id,'bid') and public.company_can_bid_nearby(r.id,i.partner_id);
$$;

-- Bid-only operation: list_company_bid_delivery_locations.
create or replace function public.list_company_bid_delivery_locations()
returns table(request_id uuid,latitude double precision,longitude double precision)
language sql stable security definer set search_path=pg_catalog,public as $$
  select r.id,r.delivery_latitude,r.delivery_longitude
  from public.company_bid_invitations i join public.service_requests r on r.id=i.request_id
  join public.delivery_quote_windows w on w.request_id=r.id and w.status='open' and w.deadline_at>now()
  where r.delivery_latitude is not null and public.company_staff_allowed(i.partner_id,'bid')
    and public.company_can_bid_nearby(r.id,i.partner_id);
$$;

-- Bid-only operation: list_partner_bid_screen.
create or replace function public.list_partner_bid_screen()
returns table(request_id uuid,request_number text,pickup_city text,delivery_city text,
  parcel_summary text,parcel_items jsonb,photo_path text,deadline_at timestamptz,
  own_bid_amount_ngn numeric,own_bid_status text)
language sql stable security definer set search_path=pg_catalog,public as $$
  select r.id,r.request_number,r.pickup_city,r.delivery_city,r.parcel_summary,r.parcel_items,
    coalesce(r.parcel_photo_path,(select sp.photo_path from public.customer_saved_parcels sp
      where sp.id::text=r.parcel_items->0->>'saved_parcel_id' and sp.user_id=r.created_by)),
    w.deadline_at,
    (select q.amount_ngn from public.partner_quotes q where q.request_id=r.id and q.partner_id=pc.partner_id order by q.version desc limit 1),
    (select q.status from public.partner_quotes q where q.request_id=r.id and q.partner_id=pc.partner_id order by q.version desc limit 1)
  from public.delivery_quote_windows w
  join public.service_requests r on r.id=w.request_id
  join lateral (
    select i.partner_id from public.company_bid_invitations i
      where i.request_id=r.id and r.pickup_location_source is not null
    union
    select pc.partner_id from public.partner_corridor_coverage pc
      where pc.corridor_id=w.corridor_id and pc.is_enabled and pc.capacity_available
        and r.pickup_location_source is null
  ) pc on true
  join public.logistics_partners p on p.id=pc.partner_id and p.status='active'
  where public.company_staff_allowed(pc.partner_id,'bid') and public.company_can_bid_nearby(r.id,pc.partner_id) and w.status='open' and now()<w.deadline_at;
$$;

-- Bid-only operation: can_read_bid_parcel_photo.
create or replace function public.can_read_bid_parcel_photo(p_path text)
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
  select exists (
    select 1 from public.service_requests r
    join public.delivery_quote_windows w on w.request_id=r.id and w.status='open' and w.deadline_at>now()
    join lateral (
    select i.partner_id from public.company_bid_invitations i
      where i.request_id=r.id and r.pickup_location_source is not null
    union
    select pc.partner_id from public.partner_corridor_coverage pc
      where pc.corridor_id=w.corridor_id and pc.is_enabled and pc.capacity_available
        and r.pickup_location_source is null
  ) pc on true
    join public.logistics_partners p on p.id=pc.partner_id and p.status='active'
    where (r.parcel_photo_path=p_path or exists (select 1 from public.customer_saved_parcels sp
      where sp.id::text=r.parcel_items->0->>'saved_parcel_id' and sp.user_id=r.created_by and sp.photo_path=p_path))
      and public.company_staff_allowed(pc.partner_id,'bid') and public.company_can_bid_nearby(r.id,pc.partner_id)
  );
$$;

-- Bid-only operation: submit_partner_quote.
create or replace function public.submit_partner_quote(p_request_id uuid,p_amount_ngn numeric,p_eta_hours integer,
  p_inclusions text,p_exclusions text,p_availability_confirmed boolean,p_surcharge_conditions text)
returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_window public.delivery_quote_windows%rowtype;v_partner uuid;v_id uuid;
begin
  select * into v_window from public.delivery_quote_windows where request_id=p_request_id for update;
  if not found or v_window.status<>'open' or now()>=v_window.deadline_at then
    raise object_not_in_prerequisite_state using message='Quote window is closed'; end if;
  select candidate.partner_id into v_partner from (
    select i.partner_id from public.company_bid_invitations i join public.service_requests r on r.id=i.request_id
      where i.request_id=p_request_id and r.pickup_location_source is not null
    union
    select pc.partner_id from public.partner_corridor_coverage pc join public.service_requests r on r.id=p_request_id
      where pc.corridor_id=v_window.corridor_id and pc.is_enabled and pc.capacity_available
        and r.pickup_location_source is null
  ) candidate join public.logistics_partners p on p.id=candidate.partner_id
  where p.status='active' and public.company_staff_allowed(p.id,'bid') and public.company_can_bid_nearby(p_request_id,p.id)
  order by candidate.partner_id limit 1;
  if v_partner is null then raise insufficient_privilege using message='Partner is not eligible for this corridor'; end if;
  if p_amount_ngn is null or p_amount_ngn<=0 or p_eta_hours is null or p_eta_hours<=0
    or p_availability_confirmed is distinct from true
    or nullif(btrim(p_inclusions),'') is null or nullif(btrim(p_exclusions),'') is null
    or nullif(btrim(p_surcharge_conditions),'') is null then
    raise check_violation using message='Complete quote details are required'; end if;
  update public.partner_quotes set status='invalid',invalidation_reason='Superseded by a newer quote'
  where request_id=p_request_id and partner_id=v_partner and status='valid';
  insert into public.partner_quotes(request_id,partner_id,amount_ngn,eta_hours,availability_confirmed,
    inclusions,exclusions,surcharge_conditions,version)
  values(p_request_id,v_partner,p_amount_ngn,p_eta_hours,true,btrim(p_inclusions),btrim(p_exclusions),
    btrim(p_surcharge_conditions),
    coalesce((select max(version)+1 from public.partner_quotes where request_id=p_request_id and partner_id=v_partner),1))
  returning id into v_id;
  return v_id;
end $$;

-- Bid-only operation: list_partner_bid_route_addresses.
create or replace function public.list_partner_bid_route_addresses()
returns table(request_id uuid,pickup_address text,delivery_address text)
language sql stable security definer set search_path=pg_catalog,public as $$
  select distinct r.id,r.pickup_address,r.delivery_address
  from public.delivery_quote_windows w
  join public.service_requests r on r.id=w.request_id
  join lateral (
    select i.partner_id from public.company_bid_invitations i
      where i.request_id=r.id and r.pickup_location_source is not null
    union
    select pc.partner_id from public.partner_corridor_coverage pc
      where pc.corridor_id=w.corridor_id and pc.is_enabled and pc.capacity_available
        and r.pickup_location_source is null
  ) pc on true
  join public.logistics_partners p on p.id=pc.partner_id and p.status='active'
  where public.company_staff_allowed(pc.partner_id,'bid') and public.company_can_bid_nearby(r.id,pc.partner_id)
    and w.status='open' and now()<w.deadline_at;
$$;


drop policy company_invitations_read on public.company_bid_invitations;
create policy company_invitations_read on public.company_bid_invitations for select to authenticated
using(public.company_staff_allowed(partner_id,'bid'));

-- Manual rider assignment is obsolete; dispatch is automatic.
revoke execute on function public.assign_job_to_rider(uuid,uuid) from authenticated;
revoke execute on function public.list_partner_rider_jobs() from authenticated;
